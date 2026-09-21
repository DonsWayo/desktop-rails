require_relative "tooling_test_helper"
require "desktop_rails/tooling/smoke/windows_app_check"
require "tmpdir"
require "fileutils"

# `smoke app` on Windows only runs for real on a CI runner that can open a
# window. The decisions in it that can go wrong without one — which request was
# the window's, which processes were the server's, what counts as writing inside
# the bundle — are tested here, so a mistake in the harness is not first seen as
# a mysterious red Windows job.
class AppCheckTest < Minitest::Test
  AppCheck = DesktopRails::Tooling::Smoke::WindowsAppCheck

  # The same reading of a Rails log as the Unix check: Smoke.root_request_completion.
  def test_the_windows_request_for_root_is_the_first_one_that_completed
    log = <<~LOG
      Started GET "/desktop-rails/path-configuration.json" for 127.0.0.1 at 2026-09-16 13:37:30 +0000
      Completed 200 OK in 0ms
      Started GET "/" for 127.0.0.1 at 2026-09-16 13:37:39 +0000
      Processing by WelcomeController#index as HTML
      Completed 500 Internal Server Error in 47ms
      Started GET "/" for 127.0.0.1 at 2026-09-16 13:37:40 +0000
      Completed 200 OK in 2ms
    LOG

    # The path configuration completed first, and a later request for / by the
    # harness itself succeeded; neither is the window's.
    assert_equal "Completed 500 Internal Server Error in 47ms", DesktopRails::Tooling::Smoke.root_request_completion(log)
  end

  def test_no_request_for_root_yet_is_nil_even_with_other_requests_logged
    assert_nil DesktopRails::Tooling::Smoke.root_request_completion(%(Started GET "/up" for 127.0.0.1\nCompleted 200 OK\n))
    assert_nil DesktopRails::Tooling::Smoke.root_request_completion(%(Started GET "/" for 127.0.0.1\nProcessing by X\n))
  end

  # Ruby writes its logs in text mode on Windows, so every line ends in CRLF.
  def test_a_log_written_on_windows_reads_the_same
    log = %(Started GET "/" for 127.0.0.1\r\nCompleted 200 OK in 5ms\r\n)
    assert_equal "Completed 200 OK in 5ms", DesktopRails::Tooling::Smoke.root_request_completion(log)
  end

  def test_the_server_tree_is_followed_through_the_launcher
    shell = process(100, 1, "notes.exe", 10)
    table = [
      shell,
      process(200, 100, "cmd.exe", 20),
      process(300, 200, "ruby.exe", 30),
      process(400, 100, "msedgewebview2.exe", 40),
      process(500, 1, "unrelated.exe", 50)
    ]

    tree = AppCheck.descendants([ shell ], table)
    assert_equal [ 200, 400, 300 ], tree.map { |p| p["ProcessId"] }
    assert_equal %w[cmd.exe ruby.exe], AppCheck.server_processes(tree).map { |p| p["Name"] }
  end

  # Windows keeps a dead parent's id on its children and hands ids out again, so
  # a process older than the shell that happens to name its pid as parent is not
  # the shell's.
  def test_a_reused_parent_id_does_not_adopt_an_older_process
    shell = process(100, 1, "notes.exe", 10)
    stale = process(600, 100, "ruby.exe", 5)

    assert_empty AppCheck.descendants([ shell ], [ shell, stale ])
  end

  # What the screenshot of the first green Windows run showed: Windows Terminal
  # hosting cmd.exe on top of the app's own window.
  def test_a_console_that_opened_with_the_app_is_a_stray_window
    windows = [
      { "Id" => 100, "Name" => "notes", "Title" => "Notes", "Started" => 50 },
      { "Id" => 200, "Name" => "WindowsTerminal", "Title" => 'C:\Windows\system32\cmd.exe', "Started" => 60 },
      { "Id" => 300, "Name" => "explorer", "Title" => "Program Manager", "Started" => 1 }
    ]

    stray = AppCheck.stray_windows(windows, shell_pid: 100, shell_started: 50)
    assert_equal [ 200 ], stray.map { |w| w["Id"] }
  end

  # A terminal that was already open takes the console as a new tab, so its
  # start time says nothing; the console's title still does.
  def test_a_console_in_a_terminal_that_was_already_open_is_still_found
    windows = [ { "Id" => 200, "Name" => "WindowsTerminal", "Title" => 'C:\Windows\system32\cmd.exe', "Started" => 1 } ]

    assert_equal 1, AppCheck.stray_windows(windows, shell_pid: 100, shell_started: 50).size
    assert_empty AppCheck.stray_windows([ { "Id" => 7, "Title" => "Program Manager", "Started" => 1 } ],
                                        shell_pid: 100, shell_started: 50)
  end

  def test_changes_name_what_was_added_removed_and_modified
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "kept.rb"), "a")
      File.write(File.join(dir, "lib", "edited.rb"), "a")
      File.write(File.join(dir, "gone.txt"), "a")
      before = AppCheck.snapshot(dir)

      File.write(File.join(dir, "lib", "edited.rb"), "changed")
      File.delete(File.join(dir, "gone.txt"))
      File.write(File.join(dir, ".hidden"), "")
      after = AppCheck.snapshot(dir)

      changes = AppCheck.changes(before, after)
      assert_includes changes, "added .hidden"
      assert_includes changes, "removed gone.txt"
      assert_includes changes, "modified lib/edited.rb"
      refute(changes.any? { |line| line.include?("kept.rb") })
    end
  end

  def test_an_untouched_tree_has_no_changes
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a"), "a")
      assert_empty AppCheck.changes(AppCheck.snapshot(dir), AppCheck.snapshot(dir))
    end
  end

  def test_a_report_is_ok_only_when_it_says_so
    assert DesktopRails::Tooling::Smoke.report_ok?(%({"kind": "ruby", "ok": true}))
    refute DesktopRails::Tooling::Smoke.report_ok?(%({"kind": "ruby", "ok": false}))
    refute DesktopRails::Tooling::Smoke.report_ok?(%({"kind": "ruby", "ok": "true"}))
    refute DesktopRails::Tooling::Smoke.report_ok?("not json")
  end

  # The one thing the harness decides before it starts anything, and the check
  # every CI step depends on being made: without a data directory there is
  # nothing to read the app's own reports from.
  def test_without_a_data_directory_it_fails_before_launching_anything
    out = StringIO.new
    status = AppCheck::Check.new("C:/nope/app.exe", [], data_dir: nil, out: out).run

    assert_equal 1, status
    assert_includes out.string, "DESKTOP_DATA_DIR"
  end

  private

  def process(pid, parent, name, created)
    { "ProcessId" => pid, "ParentProcessId" => parent, "Name" => name, "Created" => created }
  end
end
