# frozen_string_literal: true
#
# Launch a packaged app by its GUI shell on Windows, and check what a person
# would see.
#
# The same checks, in the same order, as app_check.sh, which macOS and Linux
# run: the window's own request for /, then the checks named on the command
# line, then that force-quitting the shell takes the server with it. Everything
# is asserted from outside the app, through the Rails log and the files the app
# writes into DESKTOP_DATA_DIR.
#
# Windows gets its own harness for what the final kill has to be there. Git
# Bash's `kill -9` acts on the MSYS process that started the exe rather than
# the exe, and the server is not the shell's child: the shell runs the .cmd
# launcher, so the tree is shell -> cmd.exe -> ruby.exe, and ruby.exe goes only
# if something reaches it. So the tree is captured before the kill, the kill is
# Stop-Process -Force on the shell's own pid (TerminateProcess, which is what
# End task and a crash look like: no Rust code runs afterwards), and a survivor
# is named rather than inferred from a port that still answers.
#
# Usage:
#   set DESKTOP_DATA_DIR to an empty directory
#   ruby app_check.rb <shell exe> [checks...]
#
# Checks, as in app_check.sh:
#   text=STRING      GET / contains STRING
#   path=PATH        GET PATH answers 200
#   marker=NAME      DESKTOP_DATA_DIR/native-reports/NAME.json appears and
#                    reports "ok": true
#   request=PATH     GET PATH answers 200, for a check triggered from outside
#   unchanged=DIR    nothing under DIR was written while the app ran
#
# APP_CHECK_SCREENSHOT names a PNG to save of the desktop just before the kill.
# APP_CHECK_TIMEOUT is how long to wait for the server's address (default 240s).

require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "uri"

$stdout.sync = true

module AppCheck
  WEBVIEW = "msedgewebview2.exe"

  module_function

  # The completion line of the first request for / in a Rails log, or nil while
  # there is none yet. Only the first: anything this harness requests later
  # would otherwise satisfy it.
  def window_root_request(log)
    started = log.index(%r{Started GET "/" for})
    return nil unless started

    log[started..].each_line.drop(1).find { |line| line.match?(/Completed \d+/) }&.strip
  end

  # Every process started, directly or not, by one of the roots. A parent id
  # outlives its process on Windows and ids are reused, so a candidate counts
  # only when it started no earlier than its parent.
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
  # Compared as a before and after rather than against a timestamp, because a
  # timestamp can only say that a directory changed. Something that creates a
  # file and deletes it again leaves nothing newer behind but the directory, and
  # the name of what came and went is the only clue to who wrote it.
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

  def report_ok?(json)
    JSON.parse(json)["ok"] == true
  rescue JSON::ParserError
    false
  end

  # ─── Talking to Windows ────────────────────────────────────────────────────

  # -EncodedCommand, so the script reaches PowerShell as written. Passed as
  # -Command it would go through Windows command-line quoting first, and every
  # double quote in it would be a question of who unescapes it.
  def powershell_argv(script)
    [ "pwsh", "-NoProfile", "-NonInteractive", "-EncodedCommand", [ script.encode(Encoding::UTF_16LE).b ].pack("m0") ]
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
    raise "could not list processes: #{output}" unless ok

    JSON.parse(output)
  end

  # Record every change under dir as it happens, into log, until killed.
  #
  # The snapshots above cannot name a file that was created and deleted again
  # while the app ran; they only see its directory's time move. A watcher sees
  # both events. Returns the watcher's pid once it is listening.
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

  def window_of(pid)
    output, = powershell("$p = Get-Process -Id #{Integer(pid)}; \"$($p.MainWindowHandle)`t$($p.MainWindowTitle)\"")
    output.strip.split("\t", 2)
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

  # ─── The run ───────────────────────────────────────────────────────────────

  class Run
    def initialize(shell, checks, env: ENV)
      @shell = File.expand_path(shell)
      @checks = checks
      @deadline = Integer(env.fetch("APP_CHECK_TIMEOUT", "240"))
      @data_dir = env["DESKTOP_DATA_DIR"].to_s
      abort "set DESKTOP_DATA_DIR to an empty directory" if @data_dir.empty?
      @screenshot = env["APP_CHECK_SCREENSHOT"]
      @log = File.join(Dir.mktmpdir("app_check"), "shell.log")
      @rails_log = File.join(@data_dir, "log", "desktop.log")
      @reports = File.join(@data_dir, "native-reports")
      @problems = 0
    end

    def call
      @snapshots = @checks.filter_map { |check| check.delete_prefix("unchanged=") if check.start_with?("unchanged=") }
                          .to_h { |dir| [ dir, AppCheck.snapshot(File.expand_path(dir)) ] }
      @watchers = @snapshots.keys.each_with_index.to_h do |dir, index|
        log = File.join(File.dirname(@log), "watch-#{index}.log")
        [ dir, [ AppCheck.watch(File.expand_path(dir), log), log ] ]
      end

      # [path, path] so the exe is started directly, never through cmd.exe,
      # whatever the path contains.
      @pid = Process.spawn({ "RUST_LOG" => "info" }, [ @shell, @shell ], out: [ @log, "w" ], err: [ :child, :out ])
      at_exit { stop_quietly }

      url = wait_for_address
      puts "OK    shell announced #{url}"
      wait_for_window_root
      @checks.each { |check| run_check(check, url) }
      fail!("#{@problems} check(s) failed") if @problems.positive?

      force_quit_and_confirm(url)
    end

    private

    def ok(message) = puts("OK    #{message}")

    def problem(message)
      puts "FAIL  #{message}"
      @problems += 1
    end

    def fail!(message)
      puts "FAIL  #{message}"
      puts "      shell log:"
      tail(@log, 30).each { |line| puts "        #{line}" }
      if File.exist?(@rails_log)
        puts "      rails log:"
        tail(@rails_log, 40).each { |line| puts "        #{line}" }
      end
      exit 1
    end

    def tail(path, count)
      File.exist?(path) ? read(path).lines.last(count).map(&:rstrip) : []
    end

    # Logs are whatever bytes their writers produced, and a line that is not
    # valid UTF-8 must not turn a report into an encoding error.
    def read(path)
      File.read(path, mode: "rb").force_encoding(Encoding::UTF_8).scrub
    end

    def shell_exited?
      @exited ||= !Process.waitpid(@pid, Process::WNOHANG).nil?
    end

    def wait_for_address
      @deadline.times do
        found = File.exist?(@log) && read(@log)[%r{listening at (http://\S+)}, 1]
        return found if found
        break if shell_exited?

        sleep 1
      end
      fail!("the shell never announced a server address within #{@deadline}s")
    end

    # The window's own request for the root page, before this harness has sent
    # any. Everything below makes requests of its own, so the log is read first.
    def wait_for_window_root
      done = nil
      90.times do
        done = File.exist?(@rails_log) && AppCheck.window_root_request(read(@rails_log))
        break if done
        fail!("the shell exited before the window asked for /") if shell_exited?

        sleep 1
      end
      fail!("the window never requested / from the app") unless done
      fail!("the window's request for / did not succeed: #{done}") unless done.include?("Completed 200")
      ok "the window loaded / — #{done[0, 60]}"
    end

    def get(url, path, timeout)
      uri = URI.join(url, path)
      Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri)
      end
    end

    def run_check(check, url)
      kind, value = check.split("=", 2)
      case kind
      when "text"
        body = begin
          get(url, "/", 20).body.to_s
        rescue StandardError
          ""
        end
        body.include?(value) ? ok("GET / contains '#{value}'") : problem("GET / does not contain '#{value}'")
      when "path", "request"
        response = begin
          get(url, value, 30)
        rescue StandardError => e
          e
        end
        if response.is_a?(Net::HTTPResponse) && response.code == "200"
          ok "GET #{value} 200"
        else
          puts(response.is_a?(Net::HTTPResponse) ? response.body.to_s[0, 2000] : response.inspect)
          problem "GET #{value} returned #{response.is_a?(Net::HTTPResponse) ? response.code : "no response"}"
        end
      when "marker"
        file = File.join(@reports, "#{value}.json")
        90.times do
          break if File.size?(file) || shell_exited?

          sleep 1
        end
        if !File.size?(file)
          problem "no #{value} report in #{@reports}"
        elsif AppCheck.report_ok?(File.read(file))
          ok "#{value} report: #{File.read(file).split.join(" ")[0, 400]}"
        else
          puts File.read(file)
          problem "the #{value} report says it failed"
        end
      when "unchanged"
        written = AppCheck.changes(@snapshots.fetch(value), AppCheck.snapshot(File.expand_path(value)))
        watcher, events = @watchers.fetch(value)
        AppCheck.stop(watcher)
        if written.empty?
          ok "nothing written under #{value}"
        else
          written.first(20).each { |line| puts "      #{line}" }
          seen = File.exist?(events) ? read(events).lines.map(&:strip).reject { |l| l == "watching" } : []
          puts "      as it happened:" if seen.any?
          seen.first(40).each { |line| puts "        #{line}" }
          problem "the app wrote inside its own read-only tree (#{written.size} change(s))"
        end
      else
        problem "unknown check '#{check}'"
      end
    end

    def force_quit_and_confirm(url)
      processes = AppCheck.process_table
      shell = processes.find { |p| p["ProcessId"] == @pid } ||
              fail!("pid #{@pid} is not in the process table; the shell is not running")
      tree = AppCheck.descendants([ shell ], processes)
      server = AppCheck.server_processes(tree)

      handle, title = AppCheck.window_of(@pid)
      puts "      shell pid #{@pid}, main window handle #{handle}, title '#{title}'"
      puts "      what it started:"
      tree.each do |p|
        puts format("        pid %-6d parent %-6d %s", p["ProcessId"], p["ParentProcessId"], (p["CommandLine"] || p["Name"]).to_s[0, 140])
      end
      if @screenshot
        size, taken = AppCheck.screenshot(File.expand_path(@screenshot))
        puts(taken ? "      screenshot: #{@screenshot} (#{size})" : "      no screenshot: #{size}")
      end
      fail!("the shell started no server process") if server.empty?

      _, killed = AppCheck.powershell("Stop-Process -Id #{@pid} -Force")
      fail!("Stop-Process -Force on pid #{@pid} failed") unless killed

      survivors = server
      60.times do
        survivors = survivors.select { |p| AppCheck.alive?(p["ProcessId"]) }
        break if survivors.empty?

        sleep 0.25
      end

      answering = begin
        get(url, "/up", 3)
        true
      rescue StandardError
        false
      end

      if survivors.any? || answering
        survivors.each do |p|
          puts "FAIL  pid #{p["ProcessId"]} (#{p["Name"]}) outlived Stop-Process -Force on the shell by 15s"
        end
        puts "FAIL  the server still answers #{url}/up" if answering
        puts "FAIL  force-quitting the shell orphaned its server"
        survivors.each { |p| AppCheck.powershell("Stop-Process -Id #{p["ProcessId"]} -Force") }
        exit 1
      end
      ok "server gone after Stop-Process -Force of the shell (#{server.map { |p| p["Name"] }.join(", ")})"
    end

    def stop_quietly
      @watchers&.each_value { |watcher, _| AppCheck.stop(watcher) }
      AppCheck.stop(@pid) unless shell_exited?
    rescue StandardError
      nil
    end
  end
end

AppCheck::Run.new(ARGV.shift || abort("usage: app_check.rb <shell exe> [checks...]"), ARGV).call if $PROGRAM_NAME == __FILE__
