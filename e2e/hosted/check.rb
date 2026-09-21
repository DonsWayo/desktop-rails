# What the hosted-mode CI job asserts, read from outside the app.
#
#   ruby e2e/hosted/check.rb wait URL...
#     Until each URL's /up answers. Only /up: a request for / from here would
#     satisfy the check that the window asked for it.
#
#   ruby e2e/hosted/check.rb window --shell-log PATH --app-log PATH \
#                                   --app-reports PATH --other-reports PATH
#     Once the packaged app is running: what the window loaded, and what the
#     bridge said to each origin, as each origin's own server recorded it.
#
# The app is launched by the workflow rather than from here. A GUI process
# started from a scripting language's subprocess API has aborted in tao before
# (see DesktopRails::Tooling::Smoke), and a shell's background job is the way
# known to work.

require "json"
require "net/http"
require "optparse"
require "rbconfig"
require "uri"

module HostedWindowCheck
  module_function

  def wait_for_servers(urls, timeout: 120)
    urls.each do |url|
      deadline = Time.now + timeout
      until up?(url)
        abort "FAIL  #{url}/up did not answer within #{timeout}s" if Time.now > deadline
        sleep 1
      end
      puts "OK    #{url} is up"
    end
  end

  # The package desktop:package:hosted produced holds the shell and its config
  # and nothing else — no interpreter, no app — and on macOS is sealed.
  def check_package(dist:, name:, server_url:)
    problems = []
    slug = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")

    if RbConfig::CONFIG["host_os"].match?(/darwin/)
      root = File.join(dist, "#{name}.app")
      expected = %w[Contents/Info.plist Contents/MacOS/desktop-rails Contents/Resources/desktop-rails.config.json
                    Contents/_CodeSignature/CodeResources]
      config = File.join(root, "Contents", "Resources", "desktop-rails.config.json")
      problems << "#{root} does not verify" unless system("codesign", "--verify", "--strict", "--deep", root)
    else
      root = File.join(dist, slug)
      expected = [ slug, "desktop-rails.config.json", "share/applications/dev.desktop-rails.hosted-check.desktop" ]
      config = File.join(root, "desktop-rails.config.json")
      tarball = Dir.glob(File.join(dist, "#{slug}-linux-*.tar.gz")).first
      problems << "no tarball beside #{root}" unless tarball && File.size?(tarball)
    end

    files = Dir.glob("**/*", base: root).reject { |path| File.directory?(File.join(root, path)) }.sort
    problems << "#{root} holds #{files.inspect}, expected #{expected.sort.inspect}" unless files == expected.sort
    configured = File.exist?(config) && JSON.parse(File.read(config))["server_url"]
    problems << "the packaged config points at #{configured.inspect}, not #{server_url}" unless configured == server_url

    if problems.empty?
      puts "OK    #{root} holds the shell and its config, and nothing else: #{files.join(", ")}"
    else
      problems.each { |problem| puts "FAIL  #{problem}" }
    end
    problems
  end

  def up?(url)
    Net::HTTP.get_response(URI("#{url}/up")).is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end

  def eventually(timeout, interval: 1)
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      return nil if Time.now > deadline

      sleep interval
    end
  end

  def reports(path, kind)
    return [] unless File.exist?(path)

    File.readlines(path).filter_map { |line| JSON.parse(line) rescue nil }.select { |r| r["kind"] == kind }
  end

  def run_window_checks(shell_log:, app_log:, app_reports:, other_reports:, timeout: 180)
    problems = []
    fail_check = ->(message) { puts "FAIL  #{message}"; problems << message }
    ok = ->(message) { puts "OK    #{message}" }

    # 1. The window asked the app's server for its page, and got it.
    loaded = eventually(timeout) do
      log = File.exist?(app_log) ? File.read(app_log) : ""
      log[/Started GET "\/" for .*?\n(?:.*\n)*?.*Completed \d+[^\n]*/]
    end
    if loaded.nil?
      fail_check.call("the window never requested / from #{app_log}")
    elsif loaded.include?("Completed 200")
      ok.call("the window loaded / from the app server (#{loaded.lines.last.strip[0, 60]})")
    else
      fail_check.call("the window's request for / did not succeed: #{loaded.lines.last}")
    end

    # 2. The app's origin reaches the bridge, and a config that says nothing
    #    leaves the shell, clipboard reads and the filesystem closed to it.
    trusted = eventually(timeout) { reports(app_reports, "trusted").first }
    if trusted.nil?
      fail_check.call("the app page never reported what the bridge said")
    elsif !trusted["internals"]
      fail_check.call("the app page had no invoke function: #{trusted}")
    else
      state = trusted["state"]
      if state["ok"] && state.dig("value", "status") == "ok"
        ok.call("the app origin called the bridge: window #{state.dig("value", "label")} " \
                "#{state.dig("value", "width")&.round}x#{state.dig("value", "height")&.round}")
      else
        fail_check.call("the app origin's call was refused: #{state}")
      end
      {
        "shell" => /shell bridge is disabled/,
        "clipboard" => /reading the clipboard is off/,
        "filesystem" => /no allowed roots|outside the allowed/
      }.each do |component, expected|
        result = trusted[component]
        if !result["ok"] && result["error"].to_s.match?(expected)
          ok.call("#{component} is closed by default: #{result["error"][0, 90]}")
        else
          fail_check.call("#{component} was not refused by default: #{result}")
        end
      end
    end

    # 3. A frame from another origin inside the app's page has no bridge.
    frame = eventually(timeout) { reports(other_reports, "frame").first }
    if frame.nil?
      fail_check.call("the embedded frame never reported")
    elsif frame["internals"] && frame.dig("state", "ok")
      fail_check.call("a frame of another origin called the bridge: #{frame}")
    else
      ok.call("a frame of another origin could not call the bridge " \
              "(own invoke: #{frame["internals"]}, parent: #{frame["parent"].to_s[0, 60]})")
    end

    # 4. A link to a site the config does not list went to the browser, and the
    #    window stayed on the app.
    stayed = eventually(timeout) { reports(app_reports, "stayed").first }
    handed_over = eventually(30) { File.exist?(shell_log) && File.read(shell_log)[%r{Opening http://127\.0\.0\.1:3102/elsewhere outside the app}] }
    if stayed && stayed["href"].to_s.start_with?(stayed["origin"].to_s) && handed_over
      ok.call("an unlisted link was handed to the browser (#{handed_over}) and the window stayed on the app")
    else
      fail_check.call("an unlisted link was not handed to the browser: stayed=#{stayed.inspect}, shell log=#{handed_over.inspect}")
    end

    # 5. Another origin loaded as the window's page — listed in internal_hosts,
    #    so it renders — has Tauri's invoke function and is still refused.
    untrusted = eventually(timeout) { reports(other_reports, "untrusted").first }
    if untrusted.nil?
      fail_check.call("the other origin's page never reported")
    elsif !untrusted["internals"]
      fail_check.call("the other origin's page had no invoke function, so its refusal proves nothing: #{untrusted}")
    elsif untrusted.dig("state", "ok")
      fail_check.call("another origin called the bridge: #{untrusted}")
    else
      ok.call("another origin in the window was refused: #{untrusted.dig("state", "error").to_s[0, 160]}")
    end

    problems
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  case command
  when "wait"
    HostedWindowCheck.wait_for_servers(ARGV)
  when "package"
    dist, name, server_url = ARGV
    exit 1 unless HostedWindowCheck.check_package(dist: dist, name: name, server_url: server_url).empty?
  when "window"
    options = {}
    OptionParser.new do |parser|
      parser.on("--shell-log PATH") { |v| options[:shell_log] = v }
      parser.on("--app-log PATH") { |v| options[:app_log] = v }
      parser.on("--app-reports PATH") { |v| options[:app_reports] = v }
      parser.on("--other-reports PATH") { |v| options[:other_reports] = v }
      parser.on("--timeout SECONDS", Integer) { |v| options[:timeout] = v }
    end.parse!(ARGV)

    problems = HostedWindowCheck.run_window_checks(**options)
    unless problems.empty?
      puts "\n#{problems.size} check(s) failed. Shell log:"
      puts File.exist?(options[:shell_log]) ? File.readlines(options[:shell_log]).last(40).join : "(none)"
      exit 1
    end
  else
    abort "usage: ruby e2e/hosted/check.rb wait URL... | window --shell-log ... --app-log ... --app-reports ... --other-reports ..."
  end
end
