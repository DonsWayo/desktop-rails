require_relative "test_helper"
require "desktop_rails/packager/tree_copy"
require "fileutils"
require "tmpdir"

# The copy that replaced `rsync -a --exclude` and robocopy /XD. The exclude
# rules are rsync's, because that is how the shell packers' rules were written
# and what every earlier fix to them was about.
class PackagerTreeCopyTest < Minitest::Test
  TreeCopy = DesktopRails::Packager::TreeCopy

  def with_tree
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "source")
      {
        "tmp/cache/x" => "", "lib/tmp/y" => "", "lib/tmp.rb" => "code",
        "storage/db.sqlite3" => "", "lib/storage/z.rb" => "",
        "config/master.key" => "k", "config/credentials/desktop.key" => "k", "config/credentials.yml.enc" => "e",
        "bin/run" => "#!/bin/sh\n"
      }.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(source, path)))
        File.write(File.join(source, path), content)
      end
      FileUtils.chmod(0o755, File.join(source, "bin", "run"))
      File.symlink("run", File.join(source, "bin", "run-link"))
      yield tmp, source
    end
  end

  def test_an_unanchored_directory_pattern_matches_at_any_depth_and_only_directories
    with_tree do |tmp, source|
      out = TreeCopy.copy(source, File.join(tmp, "out"), excludes: %w[tmp/])
      refute File.exist?(File.join(out, "tmp"))
      refute File.exist?(File.join(out, "lib", "tmp"))
      assert File.exist?(File.join(out, "lib", "tmp.rb")), "tmp/ names directories, not files"
    end
  end

  def test_an_anchored_pattern_matches_only_at_the_top
    with_tree do |tmp, source|
      out = TreeCopy.copy(source, File.join(tmp, "out"),
                          excludes: %w[/storage/ /config/master.key /config/credentials/*.key])
      refute File.exist?(File.join(out, "storage"))
      assert File.exist?(File.join(out, "lib", "storage", "z.rb"))
      refute File.exist?(File.join(out, "config", "master.key"))
      refute File.exist?(File.join(out, "config", "credentials", "desktop.key"))
      assert File.exist?(File.join(out, "config", "credentials.yml.enc")), "* never crosses a slash or widens the match"
    end
  end

  def test_modes_are_kept_and_symlinks_stay_links
    with_tree do |tmp, source|
      out = TreeCopy.copy(source, File.join(tmp, "out"))
      assert_equal 0o755, File.stat(File.join(out, "bin", "run")).mode & 0o777
      assert File.symlink?(File.join(out, "bin", "run-link"))
      assert_equal "run", File.readlink(File.join(out, "bin", "run-link"))
    end
  end
end
