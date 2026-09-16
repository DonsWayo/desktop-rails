require_relative "tooling_test_helper"
require "desktop_rails/tooling/disk_image"
require "desktop_rails/tooling/notarization"

# The disk image and notarisation steps, with hdiutil, codesign and notarytool
# replaced by a recorder: what is signed, in which order, with what.
class ToolingDiskImageTest < Minitest::Test
  include ToolingTestSupport

  Image = DesktopRails::Tooling::DiskImage

  def test_the_image_is_named_after_the_app_and_sits_beside_it_by_default
    image = Image.new("/dist/My Ledger.app")
    assert_equal "My Ledger", image.name
    assert_equal "/dist/My Ledger.dmg", image.output
    assert_equal "/out/x.dmg", Image.new("/dist/My Ledger.app", output: "/out/x.dmg").output
  end

  def test_hdiutil_builds_a_compressed_image_from_the_staging_folder
    assert_equal [ "hdiutil", "create", "-volname", "Ledger", "-srcfolder", "/stage", "-ov",
                   "-format", "UDZO", "-quiet", "/dist/Ledger.dmg" ],
                 Image.new("/dist/Ledger.app").hdiutil_argv("/stage")
  end

  def test_the_app_is_staged_with_ditto_beside_an_applications_link
    # FileUtils does not copy extended attributes, where a signed launcher
    # script keeps its signature.
    Dir.mktmpdir do |dir|
      app = File.join(dir, "Ledger.app")
      write(File.join(app, "Contents", "Info.plist"))
      staged = nil
      runner = RecordingRunner.new
      runner.on(->(argv) { argv.first == "hdiutil" }) do |argv|
        stage = argv[argv.index("-srcfolder") + 1]
        staged = File.readlink(File.join(stage, "Applications"))
        write(argv.last, "image")
      end

      output = Image.new(app, runner: runner, log: StringIO.new).create!
      assert_equal "ditto", runner.argvs.first.first
      assert_equal app, runner.argvs.first[1]
      assert_equal "Ledger.app", File.basename(runner.argvs.first[2])
      assert_equal "/Applications", staged
      assert_equal File.join(dir, "Ledger.dmg"), output
    end
  end

  def test_something_that_is_not_an_app_is_refused
    assert_raises(DesktopRails::Tooling::MissingPrerequisite) { Image.new("/nonexistent/Ledger.app").create! }
  end
end

class ToolingNotarizationTest < Minitest::Test
  include ToolingTestSupport

  Notarization = DesktopRails::Tooling::Notarization
  IDENTITY = "Developer ID Application: Ada Lovelace (TEAM123456)"

  def with_app
    Dir.mktmpdir do |dir|
      app = File.join(dir, "Ledger.app")
      resources = File.join(app, "Contents", "Resources")
      files = {
        extension: write("#{resources}/ruby/lib/ruby/3.4.0/arm64-darwin/openssl.bundle"),
        gem_so: write("#{resources}/gems/gems/sqlite3-2/lib/sqlite3_native.so"),
        dylib: write("#{resources}/ruby/lib/libffi.dylib"),
        ruby: executable("#{resources}/ruby/bin/ruby"),
        shell: executable("#{app}/Contents/MacOS/desktop-rails"),
        launch: executable("#{app}/Contents/MacOS/launch"),
        entitlements: write("#{dir}/entitlements.plist")
      }
      yield app, files
    end
  end

  def test_signing_runs_inside_out_ending_with_the_bundle
    with_app do |app, files|
      order = Notarization.new(app: app, identity: IDENTITY, entitlements: files[:entitlements]).signing_order
      nested = [ files[:extension], files[:gem_so], files[:dylib] ]
      assert_equal nested.sort, order.first(3).sort
      assert_equal files[:ruby], order[3]
      assert_equal [ files[:shell], files[:launch] ].sort, order[4, 2].sort,
                   "Contents/MacOS is code too; an ad-hoc shell there would be rejected"
      assert_equal app, order.last
    end
  end

  def test_signatures_carry_a_timestamp_the_hardened_runtime_and_the_entitlements
    with_app do |app, files|
      argv = Notarization.new(app: app, identity: IDENTITY, entitlements: files[:entitlements]).codesign_argv("/x")
      assert_equal [ "codesign", "--force", "--timestamp", "--options", "runtime",
                     "--entitlements", files[:entitlements], "--sign", IDENTITY, "/x" ], argv
    end
  end

  def test_notarytool_gets_a_zip_and_a_keychain_profile
    n = Notarization.new(app: "/dist/Ledger.app", identity: IDENTITY, keychain_profile: "ci")
    assert_equal [ "ditto", "-c", "-k", "--keepParent", "/dist/Ledger.app", "/t/Ledger.zip" ], n.archive_argv("/t/Ledger.zip")
    assert_equal [ "xcrun", "notarytool", "submit", "/t/Ledger.zip", "--keychain-profile", "ci", "--wait" ],
                 n.submit_argv("/t/Ledger.zip")
    assert_equal [ "xcrun", "stapler", "staple", "/dist/Ledger.app" ], n.staple_argv
    assert_equal "notary", Notarization.new(app: "/a.app").keychain_profile
  end

  def test_the_whole_run_in_order
    with_app do |app, files|
      runner = RecordingRunner.new
      Notarization.new(app: app, identity: IDENTITY, entitlements: files[:entitlements],
                       runner: runner, log: StringIO.new).notarize!
      tools = runner.argvs.map { |argv| argv.first(2).join(" ") }
      assert_equal [ "codesign --force" ] * 7 + [ "ditto -c", "xcrun notarytool", "xcrun stapler",
                                                  "codesign --verify", "spctl -a" ], tools
    end
  end

  def test_a_failed_signature_stops_before_submitting
    with_app do |app, files|
      runner = RecordingRunner.new
      runner.on(->(argv) { argv.last.end_with?(".so") }, success: false)
      assert_raises(DesktopRails::Tooling::CommandFailed) do
        Notarization.new(app: app, identity: IDENTITY, entitlements: files[:entitlements],
                         runner: runner, log: StringIO.new).notarize!
      end
      refute(runner.argvs.any? { |argv| argv[1] == "notarytool" })
    end
  end

  def test_a_missing_identity_lists_the_developer_ids_in_the_keychain
    with_app do |app, files|
      runner = RecordingRunner.new
      runner.on(->(argv) { argv.first == "security" }, output: <<~OUT)
          1) ABCDEF "Apple Development: Ada (XYZ)"
          2) 123456 "Developer ID Application: Ada Lovelace (TEAM123456)"
             2 valid identities found
      OUT
      error = assert_raises(DesktopRails::Tooling::MissingPrerequisite) do
        Notarization.new(app: app, entitlements: files[:entitlements], runner: runner).notarize!
      end
      assert_match(/--identity is required/, error.message)
      assert_includes error.message, "Developer ID Application: Ada Lovelace (TEAM123456)"
      refute_includes error.message, "Apple Development"
    end
  end
end
