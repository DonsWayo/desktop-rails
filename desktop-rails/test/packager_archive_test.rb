require_relative "test_helper"
require "desktop_rails/packager"
require "fileutils"
require "open3"
require "tmpdir"

# The archives are written by hand rather than by zip or tar, so these read them
# back the way the tools people will open them with do: a zip parsed field by
# field and inflated, checked with unzip when the machine has it, and a tarball
# read through RubyGems' own reader and tar.
class PackagerArchiveTest < Minitest::Test
  Archive = DesktopRails::Packager::Archive

  def with_tree
    Dir.mktmpdir do |tmp|
      tree = File.join(tmp, "acme-assistant")
      FileUtils.mkdir_p(File.join(tree, "share", "applications"))
      File.binwrite(File.join(tree, "acme-assistant"), "#!/bin/sh\necho hi\n" + ("x" * 5000))
      FileUtils.chmod(0o755, File.join(tree, "acme-assistant"))
      File.write(File.join(tree, "desktop-rails.config.json"), %({"server_url":"https://app.example.com"}\n))
      File.write(File.join(tree, "share", "applications", "com.acme.desktop"), "[Desktop Entry]\n")
      yield tmp, tree
    end
  end

  # name => [mode, contents] (contents nil for a directory), read from the
  # central directory and each entry's local data.
  def read_zip(path)
    bytes = File.binread(path)
    eocd = bytes.rindex([ 0x06054b50 ].pack("V"))
    refute_nil eocd, "no end of central directory record"
    count, _size, offset = bytes.byteslice(eocd + 10, 10).unpack("vVV")

    entries = {}
    count.times do
      header = bytes.byteslice(offset, 46).unpack("VvvvvvvVVVvvvvvVV")
      assert_equal 0x02014b50, header[0], "bad central directory signature"
      method, crc, csize, name_length, extra, comment = header.values_at(4, 7, 8, 10, 11, 12)
      external, local = header.values_at(15, 16)
      name = bytes.byteslice(offset + 46, name_length)

      local_name_length, local_extra = bytes.byteslice(local + 26, 4).unpack("vv")
      data = bytes.byteslice(local + 30 + local_name_length + local_extra, csize)
      contents = method == 8 ? Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data) : data
      assert_equal crc, Zlib.crc32(contents), "CRC mismatch for #{name}"

      entries[name] = [ (external >> 16) & 0o7777, name.end_with?("/") ? nil : contents ]
      offset += 46 + name_length + extra + comment
    end
    entries
  end

  def test_a_zip_holds_the_tree_under_its_own_directory_with_modes_and_contents
    with_tree do |tmp, tree|
      zip = Archive.zip(tree, into: File.join(tmp, "out", "acme-assistant-windows-x64.zip"))
      entries = read_zip(zip)

      assert_equal %w[
        acme-assistant/
        acme-assistant/acme-assistant
        acme-assistant/desktop-rails.config.json
        acme-assistant/share/
        acme-assistant/share/applications/
        acme-assistant/share/applications/com.acme.desktop
      ], entries.keys
      assert_equal 0o755, entries["acme-assistant/acme-assistant"][0]
      assert_equal File.binread(File.join(tree, "acme-assistant")), entries["acme-assistant/acme-assistant"][1]
      assert_equal %({"server_url":"https://app.example.com"}\n),
                   entries["acme-assistant/desktop-rails.config.json"][1]
    end
  end

  def test_unzip_accepts_the_zip
    skip "unzip is not installed" unless system("unzip -v", out: File::NULL, err: File::NULL)

    with_tree do |tmp, tree|
      zip = Archive.zip(tree, into: File.join(tmp, "a.zip"))
      output, status = Open3.capture2e("unzip", "-t", zip.to_s)
      assert status.success?, output
      assert_match(/No errors detected/, output)

      extracted = File.join(tmp, "extracted")
      _, status = Open3.capture2e("unzip", "-q", zip.to_s, "-d", extracted)
      assert status.success?
      assert File.executable?(File.join(extracted, "acme-assistant", "acme-assistant")),
             "the executable bit did not survive unzip"
    end
  end

  def test_a_tarball_keeps_the_executable_bit
    with_tree do |tmp, tree|
      tarball = Archive.tar_gz(tree, into: File.join(tmp, "acme-assistant-linux-x86_64.tar.gz"))

      modes = {}
      Zlib::GzipReader.open(tarball.to_s) do |gzip|
        Gem::Package::TarReader.new(gzip).each do |entry|
          modes[entry.full_name.chomp("/")] = [ entry.header.mode & 0o7777, entry.file? ? entry.read : nil ]
        end
      end

      assert_equal 0o755, modes["acme-assistant/acme-assistant"][0]
      assert_equal File.binread(File.join(tree, "acme-assistant")), modes["acme-assistant/acme-assistant"][1]
      assert modes.key?("acme-assistant/share/applications/com.acme.desktop")

      if system("tar --version", out: File::NULL, err: File::NULL)
        extracted = File.join(tmp, "extracted")
        FileUtils.mkdir_p(extracted)
        assert system("tar", "-xzf", tarball.to_s, "-C", extracted)
        assert File.executable?(File.join(extracted, "acme-assistant", "acme-assistant"))
      end
    end
  end

  def test_the_same_tree_makes_the_same_entry_order
    with_tree do |tmp, tree|
      first = read_zip(Archive.zip(tree, into: File.join(tmp, "1.zip"))).keys
      second = read_zip(Archive.zip(tree, into: File.join(tmp, "2.zip"))).keys
      assert_equal first, second
    end
  end
end
