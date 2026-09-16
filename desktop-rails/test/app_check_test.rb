require_relative "test_helper"
require "tmpdir"
require "fileutils"

# The Windows window check, packaging/smoke/app_check.rb, only runs on a CI
# runner that can open a window. The decisions in it that can go wrong without
# one — which request was the window's, which processes were the server's, what
# counts as writing inside the bundle — are tested here, so a mistake in the
# harness is not first seen as a mysterious red Windows job.
class AppCheckTest < Minitest::Test
  HARNESS = File.expand_path("../../packaging/smoke/app_check.rb", __dir__)

  def setup
    super
    skip "no checkout at #{HARNESS}" unless File.exist?(HARNESS)
    load HARNESS unless defined?(::AppCheck)
  end

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
    assert_equal "Completed 500 Internal Server Error in 47ms", AppCheck.window_root_request(log)
  end

  def test_no_request_for_root_yet_is_nil_even_with_other_requests_logged
    assert_nil AppCheck.window_root_request(%(Started GET "/up" for 127.0.0.1\nCompleted 200 OK\n))
    assert_nil AppCheck.window_root_request(%(Started GET "/" for 127.0.0.1\nProcessing by X\n))
  end

  # Ruby writes its logs in text mode on Windows, so every line ends in CRLF.
  def test_a_log_written_on_windows_reads_the_same
    log = %(Started GET "/" for 127.0.0.1\r\nCompleted 200 OK in 5ms\r\n)
    assert_equal "Completed 200 OK in 5ms", AppCheck.window_root_request(log)
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
    assert AppCheck.report_ok?(%({"kind": "ruby", "ok": true}))
    refute AppCheck.report_ok?(%({"kind": "ruby", "ok": false}))
    refute AppCheck.report_ok?(%({"kind": "ruby", "ok": "true"}))
    refute AppCheck.report_ok?("not json")
  end

  private

  def process(pid, parent, name, created)
    { "ProcessId" => pid, "ParentProcessId" => parent, "Name" => name, "Created" => created }
  end
end
