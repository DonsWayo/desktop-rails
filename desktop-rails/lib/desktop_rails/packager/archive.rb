# frozen_string_literal: true

require "fileutils"
require "pathname"
require "rubygems/package"
require "zlib"

module DesktopRails
  module Packager
    # The archives a packaged app is handed out as, written in Ruby.
    #
    # Shelling out to zip, tar or Compress-Archive would make the result depend
    # on which of them the build machine has and how that version behaves, and
    # would give the three platforms three code paths. Zlib and RubyGems' tar
    # writer are in every Ruby, so one implementation produces the same archive
    # everywhere, and a Windows zip can be built and checked on a Mac.
    #
    # Both keep the Unix permission bits, because a Linux tree whose binary lost
    # its executable bit does not start, and an entry's path always begins with
    # the directory being archived, the way `tar -C out dir` and
    # `Compress-Archive -Path dir` lay theirs out.
    module Archive
      module_function

      # A .tar.gz of `dir`, for Linux, where a tarball keeps the executable bits
      # a zip extracted by most tools would drop.
      def tar_gz(dir, into:)
        dir = Pathname.new(dir.to_s)
        FileUtils.mkdir_p(File.dirname(into.to_s))
        File.open(into.to_s, "wb") do |file|
          Zlib::GzipWriter.wrap(file) do |gzip|
            Gem::Package::TarWriter.new(gzip) do |tar|
              entries(dir).each do |path, name|
                mode = File.stat(path).mode & 0o7777
                if File.directory?(path)
                  tar.mkdir(name, mode)
                else
                  tar.add_file_simple(name, mode, File.size(path)) do |io|
                    File.open(path, "rb") { |source| IO.copy_stream(source, io) }
                  end
                end
              end
            end
          end
        end
        into
      end

      # A .zip of `dir`, for Windows, where Explorer opens one with nothing
      # installed.
      #
      # Deflated entries, a UTF-8 name flag, and the Unix mode in the external
      # attributes. No ZIP64: the 4 GB limit is far beyond a shell and a config,
      # and every reader handles the plain format.
      def zip(dir, into:)
        dir = Pathname.new(dir.to_s)
        FileUtils.mkdir_p(File.dirname(into.to_s))
        central = []

        File.open(into.to_s, "wb") do |out|
          entries(dir).each do |path, name|
            directory = File.directory?(path)
            name = "#{name}/" if directory
            data = directory ? "" : File.binread(path)
            compressed = directory ? "" : raw_deflate(data)
            method = directory ? 0 : 8
            time, date = dos_time(File.mtime(path))
            crc = Zlib.crc32(data)
            offset = out.pos
            flags = 0x0800

            out.write([ 0x04034b50, 20, flags, method, time, date, crc,
                        compressed.bytesize, data.bytesize, name.bytesize, 0 ].pack("VvvvvvVVVvv"))
            out.write(name)
            out.write(compressed)

            mode = File.stat(path).mode & 0o177777
            attributes = (mode << 16) | (directory ? 0x10 : 0)
            central << [ [ 0x02014b50, (3 << 8) | 20, 20, flags, method, time, date, crc,
                           compressed.bytesize, data.bytesize, name.bytesize, 0, 0, 0, 0,
                           attributes, offset ].pack("VvvvvvvVVVvvvvvVV"), name ]
          end

          start = out.pos
          central.each do |header, name|
            out.write(header)
            out.write(name)
          end
          size = out.pos - start
          out.write([ 0x06054b50, 0, 0, central.size, central.size, size, start, 0 ].pack("VvvvvVVv"))
        end
        into
      end

      # Every path under `dir`, parents before children, named from the
      # directory itself down, in a stable order so the same tree always makes
      # the same archive.
      def entries(dir)
        base = dir.dirname
        [ dir, *Dir.glob("**/*", File::FNM_DOTMATCH, base: dir.to_s)
          .reject { |p| File.basename(p) == "." || File.basename(p) == ".." }
          .sort
          .map { |p| dir.join(p) } ]
          .map { |path| [ path.to_s, path.relative_path_from(base).to_s ] }
      end

      def raw_deflate(data)
        # Negative window bits: zip entries carry bare deflate data, without
        # the zlib header and checksum Zlib::Deflate.deflate would add.
        deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
        deflater.deflate(data, Zlib::FINISH)
      ensure
        deflater&.close
      end

      # MS-DOS date and time, the only kind the basic zip headers have. Their
      # epoch is 1980, so anything older is clamped rather than wrapped.
      def dos_time(time)
        time = Time.local(1980, 1, 1) if time.year < 1980
        [ (time.hour << 11) | (time.min << 5) | (time.sec / 2),
          ((time.year - 1980) << 9) | (time.month << 5) | time.day ]
      end
    end
  end
end
