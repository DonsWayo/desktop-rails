# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "tempfile"
require "tmpdir"
require "uri"
require "desktop_rails/tooling/command"

module DesktopRails
  module Tooling
    # The checks CI runs against a packaged app, from outside it: launch what a
    # person would launch, and hold it to its contract over HTTP and through the
    # files it writes.
    #
    # Each check prints "OK    ..." or "FAIL  ..." lines and returns an exit
    # status, because what reads them is a CI log and a job that must fail.
    module Smoke
      # Checks that end the run. Everything a check has to say has been printed
      # by the time this is raised.
      class Failed < Error; end

      module_function

      # "listening at http://127.0.0.1:52345" as the shell logs it, up to the
      # first space.
      def announced_url(log_text)
        log_text.to_s[%r{listening at (http://[^ \n]+)}, 1]
      end

      # The line Rails logged when it finished the first request for "/", or nil
      # while there is none yet. The first "Completed" after the first
      # 'Started GET "/"' — the window's own request, since nothing else has
      # asked yet.
      def root_request_completion(rails_log)
        seen = false
        rails_log.to_s.each_line do |line|
          if !seen && line.include?('Started GET "/" for')
            seen = true
            next
          end
          return line.chomp if seen && line.match?(/Completed [0-9]+/)
        end
        nil
      end

      def report_ok?(json_text)
        json_text.to_s.match?(/"ok": *true/)
      end

      # A report squeezed onto one line, as much of it as a log line should hold.
      def one_line(text, limit: 400)
        text.to_s.tr("\n", " ").squeeze(" ").byteslice(0, limit).scrub("")
      end

      def tail(path, lines)
        return [] unless File.file?(path)

        File.read(path, mode: "rb").force_encoding(Encoding::UTF_8).scrub.lines.last(lines)
      end

      # The status and body of a GET, or "000" and the error when nothing
      # answered, as curl reports it.
      def http_get(url, timeout:)
        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
          response = http.request(Net::HTTP::Get.new(uri))
          [ response.code, response.body.to_s, nil ]
        end
      rescue StandardError => e
        [ "000", "", e ]
      end

      # Whether anything answers at all, whatever the status.
      def answers?(url, timeout: 3)
        http_get(url, timeout: timeout).first != "000"
      end

      # A log file outside anything being tested. Writing inside a signed .app
      # breaks its seal — "a sealed resource is missing or invalid" — and macOS
      # then refuses to launch it. A log written next to the binary made the
      # first run pass and every run after it fail silently, which is a test
      # destroying its own subject.
      def scratch_file(prefix)
        file = Tempfile.create([ prefix, ".log" ], Dir.tmpdir)
        file.close
        file.path
      end

      # Drives a GUI shell binary: started, watched through its log, and killed.
      #
      # Started with Process.spawn, stdin from the null device and both output
      # streams into a file — the way a shell starts a background job, and the
      # way that works. Launched from Python's subprocess with pipes, the app
      # aborted inside tao's did_finish_launching before it started; a GUI
      # process is fussy about how it is started.
      class ShellProcess
        attr_reader :log_path, :pid

        def initialize(binary, log_prefix:, env: {})
          @binary = binary
          @env = env
          @log_path = Smoke.scratch_file(log_prefix)
        end

        def start
          @pid = Process.spawn({ "RUST_LOG" => "info" }.merge(@env), @binary,
                               in: File::NULL, out: log_path, err: [ :child, :out ])
          @waiter = Process.detach(@pid)
          self
        end

        def alive?
          @waiter&.alive?
        end

        def log
          File.exist?(log_path) ? File.read(log_path, mode: "rb").force_encoding(Encoding::UTF_8).scrub : ""
        end

        # Waits up to `deadline` seconds for the shell to announce its server,
        # and returns the URL, or nil if it exited or never did.
        def wait_for_url(deadline)
          deadline.times do
            url = Smoke.announced_url(log)
            return url if url
            break unless alive?

            sleep 1
          end
          Smoke.announced_url(log)
        end

        # SIGKILL, so nothing in the shell gets to tidy up.
        def kill
          return unless alive?

          Process.kill(:KILL, @pid)
          @waiter.join(5)
        rescue SystemCallError
          nil
        end
      end

      # The server half, driven directly: the launcher the shell would spawn.
      #
      # The claim is not that the app was built. It is that the artifact starts,
      # announces where it is listening, answers a request, and then exits when
      # its parent closes stdin rather than leaving a server behind.
      class LaunchCheck
        def initialize(launcher, handshake_timeout: 300, out: $stdout)
          @launcher = launcher
          @handshake_timeout = handshake_timeout
          @out = out
        end

        def run
          Open3.popen3(@launcher) do |stdin, stdout, stderr, wait|
            # Drained as it arrives: Puma and Rails write to stderr, and a full
            # pipe nobody reads would stall the app before it could answer.
            errors = +""
            drain = Thread.new do
              stderr.each_line { |line| errors << line }
            rescue IOError
              nil
            end

            line = first_line(stdout, wait)
            if line.to_s.strip.empty?
              @out.puts "FAIL  no handshake on stdout"
              stop(wait)
              drain.join(5)
              @out.puts errors[0, 2000]
              return 1
            end

            handshake = begin
              JSON.parse(line)
            rescue JSON::ParserError
              @out.puts "FAIL  first stdout line was not a handshake: #{line.strip[0, 120].inspect}"
              @out.puts "      stdout must carry only the handshake; Puma's own output goes to stderr"
              stop(wait)
              return 1
            end

            @out.puts "OK    handshake #{handshake["url"]} pid=#{handshake["pid"]}"

            code, _, error = Smoke.http_get("#{handshake["url"]}/up", timeout: 20)
            if code != "200"
              @out.puts(error ? "FAIL  GET /up raised #{error.class}: #{error.message}" : "FAIL  GET /up returned #{code}")
              stop(wait)
              return 1
            end
            @out.puts "OK    GET /up 200"

            # Closing stdin is the only exit signal that survives the parent
            # being force-quit, since no shell code runs then.
            stdin.close
            60.times do |tick|
              unless wait.alive?
                @out.puts "OK    exited #{(tick * 0.2).round(1)}s after stdin closed, code #{wait.value.exitstatus}"
                return 0
              end
              sleep 0.2
            end

            @out.puts "FAIL  still running after stdin closed; this would orphan a server"
            stop(wait)
            1
          end
        end

        private

        # The first line that is not blank, or nil once the process has exited
        # or the deadline passed without one. Read on a thread so the deadline
        # holds on Windows too, where waiting on a pipe with a timeout is not
        # something to rely on.
        def first_line(stdout, wait)
          reader = Thread.new do
            loop do
              line = stdout.gets
              break nil if line.nil?
              break line unless line.strip.empty?
              break nil unless wait.alive?
            end
          rescue IOError
            nil
          end
          reader.join(@handshake_timeout) ? reader.value : nil
        end

        def stop(wait)
          Process.kill(:KILL, wait.pid) if wait.alive?
        rescue SystemCallError
          nil
        end
      end

      # Launches a packaged bundle by its GUI shell and holds the whole chain to
      # account.
      #
      # LaunchCheck drives the Ruby launcher directly, which covers the server
      # half. This drives the *shell* — what a person double-clicks — and so
      # covers what that misses: the shell spawning the bundled interpreter,
      # learning the address from its handshake, and reaping it on the way out.
      class ShellCheck
        def initialize(binary, deadline: 240, out: $stdout)
          @binary = binary
          @deadline = deadline
          @out = out
        end

        def run
          shell = ShellProcess.new(@binary, log_prefix: "shell_check").start
          url = shell.wait_for_url(@deadline)
          unless url
            @out.puts "FAIL  the shell never announced a server address within #{@deadline}s"
            @out.puts "      last lines:"
            Smoke.tail(shell.log_path, 15).each { |line| @out.puts "        #{line.chomp}" }
            return 1
          end
          @out.puts "OK    shell announced #{url}"

          code = "000"
          5.times do
            code, = Smoke.http_get("#{url}/up", timeout: 10)
            break if code == "200"

            sleep 2
          end
          if code != "200"
            @out.puts "FAIL  the announced address returned #{code} for GET /up"
            Smoke.tail(shell.log_path, 10).each { |line| @out.puts "        #{line.chomp}" }
            return 1
          end
          @out.puts "OK    GET /up 200 — the bundled interpreter is serving"

          # SIGKILL, so nothing in the shell gets to tidy up. The child must
          # still go, because it watches its own stdin rather than trusting a
          # parent.
          shell.kill
          if Smoke.server_outlives?(url)
            @out.puts "FAIL  the server survived kill -9 of the shell — it would orphan"
            return 1
          end
          @out.puts "OK    server gone after kill -9 of the shell — no orphan"
          0
        ensure
          shell&.kill
        end
      end

      # Gives a killed shell's server ten seconds to notice and go.
      def server_outlives?(url)
        10.times do
          break unless answers?("#{url}/up")

          sleep 1
        end
        answers?("#{url}/up")
      end

      # Launches a packaged app by its GUI shell and checks what a person would
      # see.
      #
      # ShellCheck proves the chain starts and stops. This asks the next
      # question — did the window actually load the app — and, for an app that
      # exercises it, did the native bridge work from inside that window in both
      # directions.
      #
      # Everything is asserted from outside the app: the Rails log and the files
      # the app writes into DESKTOP_DATA_DIR, which the caller points at a fresh
      # directory so nothing from an earlier run can satisfy a check.
      #
      # Checks, run in order after the root page is confirmed:
      #   text=STRING        GET / contains STRING
      #   path=PATH          GET PATH answers 200 (a model-backed page, say)
      #   marker=NAME        DESKTOP_DATA_DIR/native-reports/NAME.json appears,
      #                      and reports "ok": true
      #   request=PATH       GET PATH answers 200, for a check that is triggered
      #                      from outside (the Ruby-to-shell call)
      #   unchanged=DIR      nothing was written under DIR while the app ran;
      #                      used on the app tree inside the bundle, which is
      #                      read-only
      class AppCheck
        KINDS = %w[text path request marker unchanged].freeze

        Check = Struct.new(:kind, :value)

        def self.parse(check)
          kind, value = check.split("=", 2)
          Check.new(kind, value || kind)
        end

        # Paths under dir modified after the stamp, dir itself included, as
        # `find DIR -newer STAMP` lists them, without following links.
        def self.written_since(dir, stamp_time)
          return [] unless File.exist?(dir)

          Find.find(dir).select do |path|
            File.lstat(path).mtime > stamp_time
          rescue SystemCallError
            false
          end
        end

        def initialize(binary, checks, data_dir:, deadline: 240, out: $stdout)
          @binary = binary
          @checks = checks.map { |check| self.class.parse(check) }
          @data_dir = data_dir
          @deadline = deadline
          @out = out
        end

        def rails_log
          File.join(@data_dir, "log", "desktop.log")
        end

        def reports
          File.join(@data_dir, "native-reports")
        end

        def run
          if @data_dir.to_s.empty?
            @out.puts "FAIL  set DESKTOP_DATA_DIR to an empty directory"
            return 1
          end

          # A file rather than Time.now, so the comparison is between two times
          # the filesystem recorded with the same clock and granularity.
          stamp = File.mtime(Smoke.scratch_file("app_check_stamp"))
          @shell = ShellProcess.new(@binary, log_prefix: "app_check", env: { "DESKTOP_DATA_DIR" => @data_dir }).start

          url = @shell.wait_for_url(@deadline)
          fail!("the shell never announced a server address within #{@deadline}s") unless url
          @out.puts "OK    shell announced #{url}"

          # The window's own request for the root page, before this has sent
          # any. Anything sent afterwards would satisfy a check on the log, so
          # the log is read first and HTTP is only used once the webview has
          # been seen.
          root_done = nil
          90.times do
            if File.file?(rails_log)
              root_done = Smoke.root_request_completion(File.read(rails_log, mode: "rb").force_encoding(Encoding::UTF_8).scrub)
              break if root_done
            end
            fail!("the shell exited before the window asked for /") unless @shell.alive?
            sleep 1
          end
          fail!("the window never requested / from the app") unless root_done
          fail!("the window's request for / did not succeed: #{root_done}") unless root_done.include?("Completed 200")
          @out.puts "OK    the window loaded / — #{root_done.lstrip[0, 60]}"

          # Every check runs even after one fails, so a single CI run reports
          # everything that is wrong rather than only the first thing. The
          # shell's own log is only printed once, at the end.
          problems = @checks.count { |check| !run_check(check, url, stamp) }
          fail!("#{problems} check(s) failed") if problems.positive?

          # SIGKILL, so nothing in the shell gets to tidy up; the server must
          # still go.
          @shell.kill
          if Smoke.server_outlives?(url)
            @out.puts "FAIL  the server survived kill -9 of the shell — it would orphan"
            return 1
          end
          @out.puts "OK    server gone after kill -9 of the shell"
          0
        rescue Failed
          1
        ensure
          @shell&.kill
        end

        private

        def run_check(check, url, stamp)
          case check.kind
          when "text"
            _, body = Smoke.http_get("#{url}/", timeout: 20)
            body.include?(check.value) ? ok("GET / contains '#{check.value}'") : problem("GET / does not contain '#{check.value}'")
          when "path", "request"
            code, body = Smoke.http_get("#{url}#{check.value}", timeout: 30)
            if code == "200"
              ok("GET #{check.value} 200")
            else
              @out.puts body.byteslice(0, 2000).to_s.scrub
              problem("GET #{check.value} returned #{code}")
            end
          when "marker"
            file = File.join(reports, "#{check.value}.json")
            90.times do
              break if File.size?(file)
              break unless @shell.alive?

              sleep 1
            end
            if !File.size?(file)
              problem("no #{check.value} report in #{reports}")
            elsif Smoke.report_ok?(File.read(file))
              ok("#{check.value} report: #{Smoke.one_line(File.read(file))}")
            else
              @out.puts File.read(file)
              problem("the #{check.value} report says it failed")
            end
          when "unchanged"
            written = self.class.written_since(check.value, stamp).first(5)
            written.empty? ? ok("nothing written under #{check.value}") : problem("the app wrote inside its own read-only tree: #{written.join("\n")}")
          else
            problem("unknown check '#{[ check.kind, check.value ].uniq.join("=")}'")
          end
        end

        def ok(message)
          @out.puts "OK    #{message}"
          true
        end

        def problem(message)
          @out.puts "FAIL  #{message}"
          false
        end

        def fail!(message)
          @out.puts "FAIL  #{message}"
          @out.puts "      shell log:"
          Smoke.tail(@shell.log_path, 30).each { |line| @out.puts "        #{line.chomp}" }
          if File.file?(rails_log)
            @out.puts "      rails log:"
            Smoke.tail(rails_log, 40).each { |line| @out.puts "        #{line.chomp}" }
          end
          raise Failed, message
        end
      end
    end
  end
end
