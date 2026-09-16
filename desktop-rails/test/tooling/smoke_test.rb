require_relative "tooling_test_helper"
require "desktop_rails/tooling/smoke"

# The smoke checks CI runs against packaged apps. The parsing is asserted
# directly; the checks themselves run against small Ruby stand-ins for a
# launcher and a shell, which serve HTTP on loopback and behave well or badly
# on purpose, because a check is only worth something if it can fail.
#
# The real bundles are driven by package-smoke.yml and fresh-app.yml.
class ToolingSmokeParsingTest < Minitest::Test
  Smoke = DesktopRails::Tooling::Smoke

  def test_the_announced_url_is_read_up_to_the_first_space
    log = "2026-09-16T10:00:00Z  INFO desktop_rails::server: listening at http://127.0.0.1:52345 (pid 4)\n"
    assert_equal "http://127.0.0.1:52345", Smoke.announced_url(log)
    assert_nil Smoke.announced_url("starting\n")
  end

  def test_the_windows_own_root_request_is_the_first_completed_after_it_started
    log = <<~LOG
      Started GET "/up" for 127.0.0.1 at 2026-09-16 10:00:00
      Completed 200 OK in 1ms
      Started GET "/" for 127.0.0.1 at 2026-09-16 10:00:01
      Processing by WelcomeController#index as HTML
        Rendered welcome/index.html.erb
      Completed 500 Internal Server Error in 12ms
      Started GET "/" for 127.0.0.1 at 2026-09-16 10:00:02
      Completed 200 OK in 3ms
    LOG
    assert_equal "Completed 500 Internal Server Error in 12ms", Smoke.root_request_completion(log)
    assert_nil Smoke.root_request_completion("Started GET \"/\" for 127.0.0.1\n"), "not finished yet"
    assert_nil Smoke.root_request_completion("Started GET \"/notes\" for 127.0.0.1\nCompleted 200 OK\n")
  end

  def test_reports
    assert Smoke.report_ok?(%({\n  "ok": true,\n  "calls": 3\n}))
    assert Smoke.report_ok?(%({"ok":true}))
    refute Smoke.report_ok?(%({"ok": false, "error": "denied"}))
    assert_equal %({ "ok": true, "calls": 3 }), Smoke.one_line(%({\n  "ok": true,\n  "calls": 3\n}))
    assert_equal 400, Smoke.one_line("x" * 1000).bytesize
  end

  def test_checks_are_kind_equals_value_and_the_value_may_contain_equals
    check = Smoke::AppCheck.parse("text=a=b")
    assert_equal [ "text", "a=b" ], [ check.kind, check.value ]
  end

  def test_written_since_lists_what_changed_under_a_tree_without_following_links
    Dir.mktmpdir do |dir|
      tree = File.join(dir, "tree")
      FileUtils.mkdir_p(File.join(tree, "config"))
      File.write(File.join(tree, "config", "old.rb"), "")
      past = Time.now - 60
      [ File.join(tree, "config", "old.rb"), File.join(tree, "config"), tree ].each { |p| File.utime(past, past, p) }
      stamp = Time.now - 30
      assert_empty Smoke::AppCheck.written_since(tree, stamp)

      FileUtils.mkdir_p(File.join(tree, "tmp", "cache"))
      written = Smoke::AppCheck.written_since(tree, stamp)
      assert_includes written, File.join(tree, "tmp", "cache")
      refute_includes written, File.join(tree, "config", "old.rb")
    end
  end
end

class ToolingSmokeProcessTest < Minitest::Test
  include WithoutBundlerInChildren
  include ToolingTestSupport

  Smoke = DesktopRails::Tooling::Smoke

  # A tiny HTTP server: 200 with a body for the routes given, 404 otherwise.
  SERVER = <<~RUBY
    require "socket"
    def serve(server, routes)
      Thread.new do
        loop do
          client = server.accept
          path = client.gets.to_s.split[1]
          while (line = client.gets) && line != "\\r\\n"; end
          body = routes.fetch(path, nil)
          status = body ? "200 OK" : "404 Not Found"
          body ||= "missing"
          client.write "HTTP/1.1 \#{status}\\r\\nContent-Length: \#{body.bytesize}\\r\\nConnection: close\\r\\n\\r\\n\#{body}"
          client.close
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  RUBY

  def script(dir, name, body)
    executable(File.join(dir, name), "#!#{RbConfig.ruby}\n#{SERVER}\n#{body}")
  end

  # ─── launch ──────────────────────────────────────────────────────────────

  def launcher(dir, on_stdin_eof: "exit 0", first_line: nil)
    script(dir, "launch", <<~RUBY)
      require "json"
      $stdout.sync = true
      server = TCPServer.new("127.0.0.1", 0)
      serve(server, "/up" => "ok")
      puts #{first_line ? first_line.inspect : 'JSON.generate(protocol: "1.0", url: "http://127.0.0.1:#{server.addr[1]}", pid: Process.pid)'}
      warn "Puma starting in single mode..."
      $stdin.read
      #{on_stdin_eof}
    RUBY
  end

  def test_launch_passes_an_app_that_announces_answers_and_exits_on_eof
    Dir.mktmpdir do |dir|
      out = StringIO.new
      assert_equal 0, Smoke::LaunchCheck.new(launcher(dir), out: out).run, out.string
      assert_match(%r{^OK    handshake http://127\.0\.0\.1:\d+ pid=\d+$}, out.string)
      assert_includes out.string, "OK    GET /up 200"
      assert_match(/^OK    exited \d+(\.\d)?s after stdin closed, code 0$/, out.string)
    end
  end

  def test_launch_fails_an_app_that_would_orphan_its_server
    Dir.mktmpdir do |dir|
      out = StringIO.new
      assert_equal 1, Smoke::LaunchCheck.new(launcher(dir, on_stdin_eof: "sleep"), out: out).run
      assert_includes out.string, "FAIL  still running after stdin closed; this would orphan a server"
    end
  end

  def test_launch_fails_when_stdout_carries_something_other_than_the_handshake
    Dir.mktmpdir do |dir|
      out = StringIO.new
      assert_equal 1, Smoke::LaunchCheck.new(launcher(dir, first_line: "Puma starting"), out: out).run
      assert_includes out.string, %(FAIL  first stdout line was not a handshake: "Puma starting")
    end
  end

  def test_launch_fails_with_stderr_when_nothing_is_announced
    Dir.mktmpdir do |dir|
      bad = script(dir, "launch", "warn 'LoadError: cannot load such file -- rack'\nexit 1\n")
      out = StringIO.new
      assert_equal 1, Smoke::LaunchCheck.new(bad, out: out).run
      assert_includes out.string, "FAIL  no handshake on stdout"
      assert_includes out.string, "cannot load such file -- rack"
    end
  end

  # ─── shell ───────────────────────────────────────────────────────────────

  # A shell stand-in: starts a server child holding the write end of its stdin,
  # logs the address the way the real shell does, then waits to be killed.
  # The child exits on EOF unless told to ignore it.
  def shell(dir, child_ignores_stdin: false, routes: { "/up" => "ok" }, extra: "")
    child = script(dir, "server", <<~RUBY)
      server = TCPServer.new("127.0.0.1", 0)
      serve(server, #{routes.inspect})
      File.write(ARGV[0], server.addr[1].to_s)
      File.write(ARGV[1], Process.pid.to_s)
      #{child_ignores_stdin ? "sleep" : "$stdin.read"}
    RUBY
    script(dir, "desktop-rails", <<~RUBY)
      $stdout.sync = true
      port_file = File.join(#{dir.inspect}, "port")
      reader, writer = IO.pipe
      Process.spawn(#{child.inspect}, port_file, File.join(#{dir.inspect}, "child.pid"), in: reader)
      reader.close
      sleep 0.05 until File.size?(port_file)
      #{extra}
      puts "  INFO desktop_rails: listening at http://127.0.0.1:\#{File.read(port_file)} as the app server"
      sleep
    RUBY
  end

  # A scratch directory whose stand-in server is killed afterwards, whatever
  # the check concluded: the orphan test leaves one running on purpose.
  def with_stand_ins
    Dir.mktmpdir do |dir|
      yield dir
    ensure
      pid_file = File.join(dir, "child.pid")
      if File.size?(pid_file)
        begin
          Process.kill(:KILL, File.read(pid_file).to_i)
        rescue SystemCallError
          nil
        end
      end
    end
  end

  def test_shell_passes_a_chain_that_starts_serves_and_reaps
    with_stand_ins do |dir|
      out = StringIO.new
      assert_equal 0, Smoke::ShellCheck.new(shell(dir), deadline: 60, out: out).run, out.string
      assert_match(%r{^OK    shell announced http://127\.0\.0\.1:\d+$}, out.string)
      assert_includes out.string, "OK    GET /up 200 — the bundled interpreter is serving"
      assert_includes out.string, "OK    server gone after kill -9 of the shell — no orphan"
    end
  end

  def test_shell_fails_when_the_server_outlives_the_shell
    with_stand_ins do |dir|
      out = StringIO.new
      assert_equal 1, Smoke::ShellCheck.new(shell(dir, child_ignores_stdin: true), deadline: 60, out: out).run
      assert_includes out.string, "FAIL  the server survived kill -9 of the shell — it would orphan"
    end
  end

  def test_shell_fails_with_the_log_when_nothing_is_announced
    Dir.mktmpdir do |dir|
      silent = script(dir, "desktop-rails", "puts 'panicked at tray.rs'\nexit 101\n")
      out = StringIO.new
      assert_equal 1, Smoke::ShellCheck.new(silent, deadline: 30, out: out).run
      assert_includes out.string, "FAIL  the shell never announced a server address within 30s"
      assert_includes out.string, "panicked at tray.rs"
    end
  end

  def test_the_shell_log_is_written_outside_the_bundle
    # Writing inside a signed .app breaks its seal, and macOS then refuses to
    # launch it: the first run passes and every one after fails.
    Dir.mktmpdir do |dir|
      process = Smoke::ShellProcess.new(File.join(dir, "Ledger.app", "Contents", "MacOS", "desktop-rails"), log_prefix: "shell_check")
      refute process.log_path.start_with?(dir)
      assert process.log_path.start_with?(File.realpath(Dir.tmpdir)) || process.log_path.start_with?(Dir.tmpdir)
    end
  end

  # ─── app ─────────────────────────────────────────────────────────────────

  # The stand-in shell plays the window too: it logs the root request to the
  # Rails log and writes the bridge's reports, as the real app does.
  def app_shell(dir, root_status: 200, report: %({"ok": true}), write_into: nil)
    extra = <<~RUBY
      data = ENV.fetch("DESKTOP_DATA_DIR")
      Dir.mkdir(File.join(data, "log")) rescue nil
      File.write(File.join(data, "log", "desktop.log"),
                 "Started GET \\"/\\" for 127.0.0.1\\nCompleted #{root_status} OK in 4ms (Views: 1ms)\\n")
      Dir.mkdir(File.join(data, "native-reports")) rescue nil
      File.write(File.join(data, "native-reports", "javascript.json"), #{report.inspect})
      #{write_into ? "File.write(File.join(#{write_into.inspect}, 'bootsnap-cache'), 'x')" : ""}
    RUBY
    shell(dir, routes: { "/up" => "ok", "/" => "<h1>Welcome to Notes</h1>", "/native/window" => "{}" }, extra: extra)
  end

  def run_app(dir, binary, checks, data: File.join(dir, "data"))
    FileUtils.mkdir_p(data)
    out = StringIO.new
    status = Smoke::AppCheck.new(binary, checks, data_dir: data, deadline: 60, out: out).run
    [ status, out.string ]
  end

  def test_app_passes_when_the_window_loaded_and_every_check_holds
    with_stand_ins do |dir|
      tree = File.join(dir, "tree")
      FileUtils.mkdir_p(tree)
      File.utime(Time.now - 60, Time.now - 60, tree)
      status, out = run_app(dir, app_shell(dir), [ "text=Welcome to Notes", "marker=javascript",
                                                   "request=/native/window", "path=/native/window", "unchanged=#{tree}" ])
      assert_equal 0, status, out
      assert_includes out, "OK    the window loaded / — Completed 200 OK in 4ms (Views: 1ms)"
      assert_includes out, "OK    GET / contains 'Welcome to Notes'"
      assert_includes out, %(OK    javascript report: {"ok": true})
      assert_includes out, "OK    GET /native/window 200"
      assert_includes out, "OK    nothing written under #{tree}"
      assert_includes out, "OK    server gone after kill -9 of the shell"
    end
  end

  def test_app_runs_every_check_and_reports_each_failure
    with_stand_ins do |dir|
      tree = File.join(dir, "tree")
      FileUtils.mkdir_p(tree)
      binary = app_shell(dir, report: %({"ok": false, "error": "denied"}), write_into: tree)
      status, out = run_app(dir, binary, [ "text=Not on the page", "marker=javascript", "path=/missing",
                                           "unchanged=#{tree}", "bogus=1" ])
      assert_equal 1, status
      assert_includes out, "FAIL  GET / does not contain 'Not on the page'"
      assert_includes out, "FAIL  the javascript report says it failed"
      assert_includes out, "FAIL  GET /missing returned 404"
      assert_includes out, "FAIL  the app wrote inside its own read-only tree: "
      assert_includes out, File.join(tree, "bootsnap-cache")
      assert_includes out, "FAIL  unknown check 'bogus=1'"
      assert_includes out, "FAIL  5 check(s) failed"
      assert_includes out, "      shell log:"
      assert_includes out, "      rails log:"
    end
  end

  def test_app_fails_when_the_window_could_not_load_the_root_page
    with_stand_ins do |dir|
      status, out = run_app(dir, app_shell(dir, root_status: 500), [])
      assert_equal 1, status
      assert_includes out, "FAIL  the window's request for / did not succeed: Completed 500 OK in 4ms (Views: 1ms)"
    end
  end

  def test_app_needs_a_data_directory
    out = StringIO.new
    assert_equal 1, Smoke::AppCheck.new("/bin/false", [], data_dir: nil, out: out).run
    assert_includes out.string, "DESKTOP_DATA_DIR"
  end
end
