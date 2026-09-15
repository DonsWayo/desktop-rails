require_relative "test_helper"
require "turbo_desktop/paths"
require "tmpdir"

class PathsPlatformTest < Minitest::Test
  # Every platform's answer is checked from whichever machine happens to run
  # the suite. A helper that is only ever exercised on the developer's own OS
  # is a helper whose other two branches are untested.
  def test_macos_uses_application_support
    dir = TurboDesktop::Paths.data_dir(
      app_id: "dev.example.ledger", host_os: "darwin24", env: { "HOME" => "/Users/ada" }
    )
    assert_equal "/Users/ada/Library/Application Support/dev.example.ledger", dir.to_s
  end

  def test_windows_uses_local_appdata
    dir = TurboDesktop::Paths.data_dir(
      app_id: "dev.example.ledger",
      host_os: "mingw32",
      env: { "HOME" => "C:/Users/ada", "LOCALAPPDATA" => "C:/Users/ada/AppData/Local" }
    )
    assert_equal "C:/Users/ada/AppData/Local/dev.example.ledger", dir.to_s
  end

  def test_windows_falls_back_to_appdata_local_under_home
    dir = TurboDesktop::Paths.data_dir(
      app_id: "app", host_os: "mswin", env: { "HOME" => "C:/Users/ada" }
    )
    assert_equal "C:/Users/ada/AppData/Local/app", dir.to_s
  end

  def test_linux_uses_xdg_data_home
    dir = TurboDesktop::Paths.data_dir(
      app_id: "dev.example.ledger",
      host_os: "linux-gnu",
      env: { "HOME" => "/home/ada", "XDG_DATA_HOME" => "/home/ada/.data" }
    )
    assert_equal "/home/ada/.data/dev.example.ledger", dir.to_s
  end

  def test_linux_defaults_to_local_share_when_xdg_is_unset
    dir = TurboDesktop::Paths.data_dir(
      app_id: "dev.example.ledger", host_os: "linux-gnu", env: { "HOME" => "/home/ada" }
    )
    assert_equal "/home/ada/.local/share/dev.example.ledger", dir.to_s
  end

  def test_empty_xdg_data_home_is_treated_as_unset
    # An exported-but-empty variable is the usual shape of "I meant to set this
    # and did not", and joining on "" would put the data directory at the root.
    dir = TurboDesktop::Paths.data_dir(
      app_id: "app", host_os: "linux-gnu", env: { "HOME" => "/home/ada", "XDG_DATA_HOME" => "" }
    )
    assert_equal "/home/ada/.local/share/app", dir.to_s
  end

  def test_platform_detection
    assert_equal :macos, TurboDesktop::Paths.platform("darwin24")
    assert_equal :windows, TurboDesktop::Paths.platform("mingw32")
    assert_equal :windows, TurboDesktop::Paths.platform("mswin64")
    assert_equal :linux, TurboDesktop::Paths.platform("linux-gnu")
    # Anything unrecognised is treated as a unix, which is the useful guess.
    assert_equal :linux, TurboDesktop::Paths.platform("freebsd14")
  end

  def test_desktop_data_dir_env_wins_over_every_platform_rule
    # The launchers the packers write export this after making the same
    # decision in shell. If Ruby disagreed with the launcher, the app would
    # write its database somewhere the launcher had not created.
    %w[darwin24 mingw32 linux-gnu].each do |host_os|
      dir = TurboDesktop::Paths.data_dir(
        app_id: "ignored", host_os: host_os,
        env: { "HOME" => "/home/ada", "DESKTOP_DATA_DIR" => "/somewhere/else" }
      )
      assert_equal "/somewhere/else", dir.to_s, "on #{host_os}"
    end
  end

  def test_returns_a_pathname_so_callers_can_join
    dir = TurboDesktop::Paths.data_dir(app_id: "app", host_os: "darwin24", env: { "HOME" => "/h" })
    assert_kind_of Pathname, dir
    assert_equal "/h/Library/Application Support/app/storage", dir.join("storage").to_s
  end

  def test_does_not_create_the_directory_unless_asked
    Dir.mktmpdir do |tmp|
      target = File.join(tmp, "nothing-here")
      TurboDesktop::Paths.data_dir(env: { "DESKTOP_DATA_DIR" => target })
      refute File.directory?(target), "data_dir must not have side effects by default"

      TurboDesktop::Paths.data_dir(env: { "DESKTOP_DATA_DIR" => target }, create: true)
      assert File.directory?(target)
    end
  end
end

class PathsSecretKeyBaseTest < Minitest::Test
  def test_generates_once_and_reuses_it
    Dir.mktmpdir do |tmp|
      env = { "DESKTOP_DATA_DIR" => tmp }
      first = TurboDesktop::Paths.secret_key_base(env: env)
      second = TurboDesktop::Paths.secret_key_base(env: env)

      assert_equal first, second, "a regenerated secret would invalidate every session on restart"
      assert_operator first.length, :>=, 64
      assert_equal first, File.read(File.join(tmp, "secret_key_base")).strip
    end
  end

  def test_is_not_world_readable
    Dir.mktmpdir do |tmp|
      TurboDesktop::Paths.secret_key_base(env: { "DESKTOP_DATA_DIR" => tmp })
      mode = File.stat(File.join(tmp, "secret_key_base")).mode & 0o777
      assert_equal 0o600, mode
    end
  end

  def test_environment_wins
    Dir.mktmpdir do |tmp|
      secret = TurboDesktop::Paths.secret_key_base(
        env: { "DESKTOP_DATA_DIR" => tmp, "SECRET_KEY_BASE" => "from-the-environment" }
      )
      assert_equal "from-the-environment", secret
      refute File.exist?(File.join(tmp, "secret_key_base")), "nothing to persist when it was given"
    end
  end

  def test_an_empty_file_is_regenerated
    # A half-written file from an interrupted first run must not become an
    # empty secret_key_base, which Rails would accept and then fail on.
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, "secret_key_base"), "   \n")
      secret = TurboDesktop::Paths.secret_key_base(env: { "DESKTOP_DATA_DIR" => tmp })
      refute_empty secret.strip
      assert_operator secret.length, :>=, 64
    end
  end
end

class TurboDesktopAppIdentityTest < Minitest::Test
  def test_app_id_is_derived_from_the_rails_application
    # test_helper boots DummyApp, so this exercises the real derivation rather
    # than a stub of it.
    assert_equal "dev.turbodesktop.dummy-app", TurboDesktop.app_id
    assert_equal "DummyApp", TurboDesktop.app_name
  end

  def test_configuration_overrides_the_derived_identity
    TurboDesktop.configure do |config|
      config.app_id = "dev.example.ledger"
      config.app_name = "Ledger"
    end
    assert_equal "dev.example.ledger", TurboDesktop.app_id
    assert_equal "Ledger", TurboDesktop.app_name
  end

  def test_data_dir_uses_the_app_id
    TurboDesktop.configure { |config| config.app_id = "dev.example.ledger" }
    assert_includes TurboDesktop.data_dir.to_s, "dev.example.ledger"
  end
end
