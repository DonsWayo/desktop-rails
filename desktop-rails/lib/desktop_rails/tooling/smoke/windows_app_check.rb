# frozen_string_literal: true

require "json"
require "tmpdir"
require "desktop_rails/tooling/smoke"

module DesktopRails
  module Tooling
    module Smoke
      # `smoke app` on Windows: launch a packaged app by its GUI shell and check
      # what a person would see.
      #
      # The same checks, in the same order, as Smoke::AppCheck, which macOS and
      # Linux run: the window's own request for /, then the checks named on the
      # command line, then that force-quitting the shell takes the server with
      # it. Everything is asserted from outside the app, through the Rails log
      # and the files the app writes into DESKTOP_DATA_DIR.
      #
      # Windows needs its own for what the final kill has to be there. Ruby's
      # `Process.kill(:KILL)` under Git Bash acts on the MSYS process that
      # started the exe rather than the exe, and the server is not the shell's
      # child: the shell runs the .cmd launcher, so the tree is
      # shell -> cmd.exe -> ruby.exe, and ruby.exe goes only if something
      # reaches it. So the tree is captured before the kill, the kill is
      # Stop-Process -Force on the shell's own pid (TerminateProcess, which is
      # what End task and a crash look like: no Rust code runs afterwards), and
      # a survivor is named rather than inferred from a port that still answers.
      #
      # It also watches for what only Windows does: a console window opening
      # over the app's own, and a write inside the tree that is undone before
      # anyone can look.
      module WindowsAppCheck
        WEBVIEW = "msedgewebview2.exe"

        module_function

        # Every process started, directly or not, by one of the roots. A parent
        # id outlives its process on Windows and ids are reused, so a candidate
        # counts only when it started no earlier than its parent.
        def descendants(roots, processes)
          found = []
          queue = roots.dup
          until queue.empty?
            parent = queue.shift
            processes.each do |child|
              next unless child["ParentProcessId"] == parent["ProcessId"]
              next if child["ProcessId"] == parent["ProcessId"]
              next if child["Created"].to_i < parent["Created"].to_i
              next if found.include?(child)

              found << child
              queue << child
            end
          end
          found
        end

        # The processes that make up the app server, as opposed to the WebView2
        # processes the Edge runtime starts and reaps for itself.
        def server_processes(tree)
          tree.reject { |process| process["Name"].to_s.casecmp?(WEBVIEW) }
        end

        # Every entry under dir with its modification time and size.
        #
        # Compared as a before and after rather than against a timestamp,
        # because a timestamp can only say that a directory changed. Something
        # that creates a file and deletes it again leaves nothing newer behind
        # but the directory, and the name of what came and went is the only clue
        # to who wrote it.
        def snapshot(dir)
          Dir.glob("**/*", File::FNM_DOTMATCH, base: dir)
             .reject { |entry| File.basename(entry) == "." }
             .to_h do |entry|
               stat = File.lstat(File.join(dir, entry))
               [ entry, [ stat.mtime, stat.directory? ? nil : stat.size ] ]
             end
        end

        # What differs between two snapshots, as lines a person can read.
        def changes(before, after)
          added = (after.keys - before.keys).map { |entry| "added #{entry}" }
          removed = (before.keys - after.keys).map { |entry| "removed #{entry}" }
          changed = (before.keys & after.keys).reject { |entry| before[entry] == after[entry] }
                                              .map { |entry| "modified #{entry}" }
          added + removed + changed
        end

        # -EncodedCommand, so the script reaches PowerShell as written. Passed
        # as -Command it would go through Windows command-line quoting first,
        # and every double quote in it would be a question of who unescapes it.
        def powershell_argv(script)
          [ "pwsh", "-NoProfile", "-NonInteractive", "-EncodedCommand",
            [ script.encode(Encoding::UTF_16LE).b ].pack("m0") ]
        end

        def powershell(script)
          output = IO.popen(powershell_argv(script), err: [ :child, :out ], &:read)
          [ output, $?.success? ]
        end

        def process_table
          output, ok = powershell(<<~PS)
            Get-CimInstance Win32_Process | ForEach-Object {
              [pscustomobject]@{
                ProcessId = $_.ProcessId; ParentProcessId = $_.ParentProcessId; Name = $_.Name
                CommandLine = $_.CommandLine
                Created = if ($_.CreationDate) { $_.CreationDate.ToFileTimeUtc() } else { 0 }
              }
            } | ConvertTo-Json -Compress
          PS
          raise Error, "could not list processes: #{output}" unless ok

          JSON.parse(output)
        end

        # Record every change under dir as it happens, into log, until killed.
        #
        # The snapshots above cannot name a file that was created and deleted
        # again while the app ran; they only see its directory's time move. A
        # watcher sees both events. Returns the watcher's pid once it is
        # listening.
        def watch(dir, log)
          script = <<~PS
            $watcher = New-Object System.IO.FileSystemWatcher '#{dir.gsub("'", "''")}'
            $watcher.IncludeSubdirectories = $true
            $watcher.NotifyFilter = 'FileName, DirectoryName, LastWrite, Size'
            $record = { Add-Content -LiteralPath '#{log.gsub("'", "''")}' -Value ("{0} {1} {2}" -f $Event.SourceEventArgs.ChangeType, $Event.SourceEventArgs.FullPath, $Event.SourceEventArgs.OldFullPath) }
            foreach ($name in 'Created', 'Deleted', 'Changed', 'Renamed') {
              Register-ObjectEvent -InputObject $watcher -EventName $name -Action $record | Out-Null
            }
            $watcher.EnableRaisingEvents = $true
            Add-Content -LiteralPath '#{log.gsub("'", "''")}' -Value 'watching'
            while ($true) { Start-Sleep -Seconds 1 }
          PS
          pid = Process.spawn(*powershell_argv(script), out: File::NULL, err: File::NULL)
          60.times do
            break if File.exist?(log) && File.read(log).include?("watching")

            sleep 0.5
          end
          pid
        end

        # Every process that has a top-level window, with when it started.
        def windows
          output, ok = powershell(<<~PS)
            @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object {
              $started = try { $_.StartTime.ToFileTimeUtc() } catch { 0 }
              [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; Title = $_.MainWindowTitle; Started = $started }
            }) | ConvertTo-Json -Compress -AsArray
          PS
          raise Error, "could not list windows: #{output}" unless ok

          JSON.parse(output)
        end

        # Windows that appeared with the app but are not its own: a console
        # window for the launcher, most likely, which Windows opens when a
        # program with no console starts one that needs it. Recognised by
        # starting after the shell, or by a console's title when an existing
        # terminal took it as a tab.
        def stray_windows(windows, shell_pid:, shell_started:)
          windows.reject { |window| window["Id"] == shell_pid }
                 .select { |window| window["Started"].to_i >= shell_started.to_i || window["Title"].to_s.match?(/cmd\.exe|\.cmd\b/i) }
        end

        def screenshot(path)
          output, ok = powershell(<<~PS)
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
            $bitmap.Save('#{path.gsub("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
            "$($bounds.Width)x$($bounds.Height)"
          PS
          [ output.strip, ok ]
        end

        def stop(pid)
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        def alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::EPERM
          # There, but not ours to signal: still alive for this purpose.
          true
        rescue Errno::ESRCH
          false
        end

        # One run, with the same arguments Smoke::AppCheck takes so the CLI can
        # hand either of them the same command line.
        class Check
          def initialize(binary, checks, data_dir:, deadline: 240, out: $stdout, env: ENV)
            @binary = File.expand_path(binary.to_s)
            @checks = checks
            @data_dir = data_dir.to_s
            @deadline = deadline
            @out = out
            @screenshot = Paths.presence(env["APP_CHECK_SCREENSHOT"])
            @log = File.join(Dir.mktmpdir("app_check"), "shell.log")
            @problems = 0
          end

          def rails_log
            File.join(@data_dir, "log", "desktop.log")
          end

          def reports
            File.join(@data_dir, "native-reports")
          end

          def run
            if @data_dir.empty?
              @out.puts "FAIL  set DESKTOP_DATA_DIR to an empty directory"
              return 1
            end

            @snapshots = @checks.filter_map { |check| check.delete_prefix("unchanged=") if check.start_with?("unchanged=") }
                                .to_h { |dir| [ dir, WindowsAppCheck.snapshot(File.expand_path(dir)) ] }
            @watchers = @snapshots.keys.each_with_index.to_h do |dir, index|
              log = File.join(File.dirname(@log), "watch-#{index}.log")
              [ dir, [ WindowsAppCheck.watch(File.expand_path(dir), log), log ] ]
            end

            # [path, path] so the exe is started directly, never through
            # cmd.exe, whatever the path contains.
            @pid = Process.spawn({ "RUST_LOG" => "info", "DESKTOP_DATA_DIR" => @data_dir },
                                 [ @binary, @binary ], out: [ @log, "w" ], err: [ :child, :out ])

            url = wait_for_address
            @out.puts "OK    shell announced #{url}"
            wait_for_window_root
            @checks.each { |check| run_check(check, url) }
            # Run even after a check failed, unlike the Unix check. A Windows
            # run is long, and whether the server outlives the shell is the
            # question a failed check above would otherwise hide for another
            # round.
            force_quit_and_confirm(url)
            fail!("#{@problems} check(s) failed") if @problems.positive?
            @out.puts "OK    all checks passed"
            0
          rescue Failed
            1
          ensure
            stop_quietly
          end

          private

          def ok(message)
            @out.puts "OK    #{message}"
          end

          def problem(message)
            @out.puts "FAIL  #{message}"
            @problems += 1
          end

          def fail!(message)
            @out.puts "FAIL  #{message}"
            @out.puts "      shell log:"
            Smoke.tail(@log, 30).each { |line| @out.puts "        #{line.chomp}" }
            if File.file?(rails_log)
              @out.puts "      rails log:"
              Smoke.tail(rails_log, 40).each { |line| @out.puts "        #{line.chomp}" }
            end
            raise Failed, message
          end

          # Logs are whatever bytes their writers produced, and a line that is
          # not valid UTF-8 must not turn a report into an encoding error.
          def read(path)
            File.read(path, mode: "rb").force_encoding(Encoding::UTF_8).scrub
          end

          def shell_exited?
            @exited ||= !Process.waitpid(@pid, Process::WNOHANG).nil?
          end

          def wait_for_address
            @deadline.times do
              found = File.exist?(@log) && Smoke.announced_url(read(@log))
              return found if found
              break if shell_exited?

              sleep 1
            end
            fail!("the shell never announced a server address within #{@deadline}s")
          end

          # The window's own request for the root page, before this harness has
          # sent any. Everything below makes requests of its own, so the log is
          # read first.
          def wait_for_window_root
            done = nil
            90.times do
              done = File.exist?(rails_log) && Smoke.root_request_completion(read(rails_log))
              break if done
              fail!("the shell exited before the window asked for /") if shell_exited?

              sleep 1
            end
            fail!("the window never requested / from the app") unless done
            fail!("the window's request for / did not succeed: #{done}") unless done.include?("Completed 200")
            ok "the window loaded / — #{done.lstrip[0, 60]}"
          end

          def run_check(check, url)
            kind, value = check.split("=", 2)
            case kind
            when "text"
              _, body = Smoke.http_get("#{url}/", timeout: 20)
              body.include?(value) ? ok("GET / contains '#{value}'") : problem("GET / does not contain '#{value}'")
            when "path", "request"
              code, body = Smoke.http_get("#{url}#{value}", timeout: 30)
              if code == "200"
                ok "GET #{value} 200"
              else
                @out.puts body.byteslice(0, 2000).to_s.scrub
                problem "GET #{value} returned #{code}"
              end
            when "marker"
              file = File.join(reports, "#{value}.json")
              90.times do
                break if File.size?(file) || shell_exited?

                sleep 1
              end
              if !File.size?(file)
                problem "no #{value} report in #{reports}"
              elsif Smoke.report_ok?(File.read(file))
                ok "#{value} report: #{Smoke.one_line(File.read(file))}"
              else
                @out.puts File.read(file)
                problem "the #{value} report says it failed"
              end
            when "unchanged"
              written = WindowsAppCheck.changes(@snapshots.fetch(value), WindowsAppCheck.snapshot(File.expand_path(value)))
              watcher, events = @watchers.fetch(value)
              WindowsAppCheck.stop(watcher)
              if written.empty?
                ok "nothing written under #{value}"
              else
                written.first(20).each { |line| @out.puts "      #{line}" }
                seen = File.exist?(events) ? read(events).lines.map(&:strip).reject { |line| line == "watching" } : []
                @out.puts "      as it happened:" if seen.any?
                seen.first(40).each { |line| @out.puts "        #{line}" }
                problem "the app wrote inside its own read-only tree (#{written.size} change(s))"
              end
            else
              problem "unknown check '#{check}'"
            end
          end

          def force_quit_and_confirm(url)
            processes = WindowsAppCheck.process_table
            shell = processes.find { |process| process["ProcessId"] == @pid } ||
                    fail!("pid #{@pid} is not in the process table; the shell is not running")
            tree = WindowsAppCheck.descendants([ shell ], processes)
            server = WindowsAppCheck.server_processes(tree)

            windows = WindowsAppCheck.windows
            if (own = windows.find { |window| window["Id"] == @pid })
              ok "the shell has a window: '#{own["Title"]}'"
            else
              problem "the shell (pid #{@pid}) has no top-level window"
            end
            stray = WindowsAppCheck.stray_windows(windows, shell_pid: @pid, shell_started: shell["Created"])
            if stray.empty?
              ok "no other window opened with it"
            else
              stray.each { |window| @out.puts "      #{window["Name"]} (pid #{window["Id"]}): '#{window["Title"]}'" }
              problem "#{stray.size} other window(s) opened with the app, such as a console for its launcher"
            end
            @out.puts "      what it started:"
            tree.each do |process|
              @out.puts format("        pid %-6d parent %-6d %s", process["ProcessId"], process["ParentProcessId"],
                               (process["CommandLine"] || process["Name"]).to_s[0, 140])
            end
            if @screenshot
              size, taken = WindowsAppCheck.screenshot(File.expand_path(@screenshot))
              @out.puts(taken ? "      screenshot: #{@screenshot} (#{size})" : "      no screenshot: #{size}")
            end
            return problem("the shell started no server process to watch") if server.empty?

            _, killed = WindowsAppCheck.powershell("Stop-Process -Id #{@pid} -Force")
            fail!("Stop-Process -Force on pid #{@pid} failed") unless killed

            survivors = server
            60.times do
              survivors = survivors.select { |process| WindowsAppCheck.alive?(process["ProcessId"]) }
              break if survivors.empty?

              sleep 0.25
            end
            answering = Smoke.answers?("#{url}/up")

            if survivors.any? || answering
              survivors.each do |process|
                @out.puts "FAIL  pid #{process["ProcessId"]} (#{process["Name"]}) outlived Stop-Process -Force on the shell by 15s"
              end
              @out.puts "FAIL  the server still answers #{url}/up" if answering
              problem "force-quitting the shell orphaned its server"
              survivors.each { |process| WindowsAppCheck.powershell("Stop-Process -Id #{process["ProcessId"]} -Force") }
              return
            end
            ok "server gone after Stop-Process -Force of the shell (#{server.map { |process| process["Name"] }.join(", ")})"
          end

          def stop_quietly
            @watchers&.each_value { |watcher, _| WindowsAppCheck.stop(watcher) }
            WindowsAppCheck.stop(@pid) if @pid && !shell_exited?
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
