# What the native-features CI job asserts, from outside the app.
#
#   ruby e2e/native/check.rb session --logs DIR
#     Linux: until the X display answers and the stand-in notification service
#     owns its name on the session bus.
#
#   ruby e2e/native/check.rb bundle-macos BINARY --logs DIR
#     macOS: wrap the debug shell in a registered .app, since macOS only
#     notifies on behalf of a bundle. Prints the executable to launch last.
#
#   ruby e2e/native/check.rb run --platform linux|macos --logs DIR [--app URL]
#     Once the shell is running: what the page's calls answered, what reached
#     the OS services, and what happened when keys were pressed, a notification
#     was clicked and Ruby notified.
#
# Evidence comes from three places the app does not control: the reports its
# own server wrote (REPORTS_FILE, $LOGS/reports.jsonl), the stand-in
# notification service's log of what crossed the session bus
# ($LOGS/notifications.jsonl), and the X server, asked with xdotool which
# window is active. The app is launched by the workflow rather than from here;
# see e2e/hosted/check.rb for why.

require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "uri"

module NativeCheck
  module_function

  APP_TITLE = "Native Check"

  def eventually(timeout, interval: 0.5)
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      return nil if Time.now > deadline

      sleep interval
    end
  end

  def jsonl(path)
    return [] unless File.exist?(path)

    File.readlines(path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def command(*argv)
    output, status = Open3.capture2e(*argv)
    [ output.strip, status.success? ]
  rescue Errno::ENOENT => e
    [ e.message, false ]
  end

  class Run
    attr_reader :problems

    def initialize(platform:, logs:, app:, timeout:)
      @platform = platform
      @logs = logs
      @app = app
      @timeout = timeout
      @problems = []
    end

    def linux?
      @platform == "linux"
    end

    def ok(message)
      puts "OK    #{message}"
    end

    def note(message)
      puts "NOTE  #{message}"
    end

    def problem(message)
      puts "FAIL  #{message}"
      @problems << message
    end

    def check(condition, success, failure)
      condition ? ok(success) : problem(failure)
      condition
    end

    def reports(kind = nil)
      all = NativeCheck.jsonl(File.join(@logs, "reports.jsonl"))
      kind ? all.select { |report| report["kind"] == kind } : all
    end

    def service_log(event = nil)
      all = NativeCheck.jsonl(File.join(@logs, "notifications.jsonl"))
      event ? all.select { |entry| entry["event"] == event } : all
    end

    def call
      ready = NativeCheck.eventually(@timeout) { reports("ready").first || reports("error").first }
      if ready && ready["kind"] == "error"
        problem("the page's script failed: #{ready["error"]}")
        return problems
      end
      unless ready
        problem("the page never reported ready: #{reports.map { |r| r["kind"] }.inspect}")
        return problems
      end
      ok("the app loaded twice and reported ready")

      check_loads
      check_notifications_reached_the_service if linux?
      check_badge_reached_the_dock_signal if linux?
      check_ruby
      if linux?
        check_summon
        check_global_shortcut
        check_menu_item
        check_notification_click(ready)
      else
        try_synthetic_keys_on_macos
      end
      problems
    end

    # ─── what each call answered ─────────────────────────────────────────

    def check_loads
      first, second = [ 1, 2 ].map { |n| reports("load").find { |r| r["loads"] == n } }
      return problem("missing a load report: #{reports("load").inspect}") unless first && second

      { 1 => first, 2 => second }.each do |n, load|
        results = load["results"]
        label = "load #{n}:"

        permission = results["permission"]
        expected = linux? ? "granted" : "unknown"
        check(permission["ok"] && permission["value"] == expected,
              "#{label} notification permission is #{expected.inspect}",
              "#{label} notification permission: #{permission.inspect}, expected #{expected}")

        register = results["register"]
        check(register["ok"] && register.dig("value", "status") == "registered" &&
                register.dig("value", "alreadyRegistered") == (n == 2),
              "#{label} Ctrl+Alt+J registered (alreadyRegistered: #{n == 2})",
              "#{label} registering Ctrl+Alt+J answered #{register.inspect}")

        refusal(results["duplicate"], /already registered by 'palette'/, "#{label} a second id for Ctrl+Alt+J")
        refusal(results["bare"], /modifier/, "#{label} a bare K")
        refusal(results["summonClash"], /summon shortcut/, "#{label} the config's summon combination")
        if linux?
          refusal(results["taken"], /another application or the system/, "#{label} Ctrl+Alt+K, which xbindkeys holds")
        else
          note("#{label} Ctrl+Alt+K (no other holder on macOS) answered #{results["taken"].to_json[0, 160]}")
        end

        menu = results["menu"]
        check(menu["ok"] && menu.dig("value", "alreadyRegistered") == (n == 2),
              "#{label} the menu item is registered (alreadyRegistered: #{n == 2})",
              "#{label} adding the menu item answered #{menu.inspect}")

        badge = results["badge"]
        check(badge["ok"] && badge.dig("value", "supported") == true && badge.dig("value", "count") == 7,
              "#{label} badge count 7 is supported",
              "#{label} the badge answered #{badge.inspect}")
        label_result = results["label"]
        check(label_result["ok"] && label_result.dig("value", "supported") == !linux?,
              "#{label} a badge label is #{linux? ? "a declared no-op" : "supported"}",
              "#{label} the badge label answered #{label_result.inspect}")

        notify = results["notify"]
        check(notify["ok"] && notify.dig("value", "status") == "shown" &&
                notify.dig("value", "clickable") == linux?,
              "#{label} the page's notification was shown (clickable: #{linux?})",
              "#{label} the page's notification answered #{notify.inspect}")
      end
    end

    def refusal(result, pattern, what)
      check(result && !result["ok"] && result["error"].to_s.match?(pattern),
            "#{what} was refused: #{result && result["error"].to_s[0, 110]}",
            "#{what} was not refused as expected: #{result.inspect}")
    end

    # ─── what reached the OS services (Linux) ────────────────────────────

    def check_notifications_reached_the_service
      page = service_log("Notify").select { |n| n["summary"] == "Page says hello" }
      check(page.any? { |n| n["body"] == "from JavaScript" && n["actions"].include?("default") },
            "the notification service received Notify(\"Page says hello\", \"from JavaScript\") with a default action",
            "the notification service never received the page's notification: #{service_log("Notify").inspect}")
      if page.size >= 2
        check(page[1]["replaces_id"] == page[0]["id"],
              "the second load's notification with the same id replaced the first (replaces_id #{page[1]["replaces_id"]})",
              "the same notification id stacked instead of replacing: #{page.inspect}")
      end
    end

    def check_badge_reached_the_dock_signal
      update = NativeCheck.eventually(10) do
        service_log("LauncherEntry.Update").find { |u| u.dig("properties", "count") == 7 }
      end
      check(update && update.dig("properties", "count-visible") == true &&
              update["app_uri"].to_s.match?(%r{\Aapplication://.+\.desktop\z}),
            "com.canonical.Unity.LauncherEntry.Update went out on the session bus: #{update && update["app_uri"]} count 7",
            "no launcher badge update reached the session bus: #{service_log("LauncherEntry.Update").inspect}")
    end

    # ─── Ruby over the control channel ───────────────────────────────────

    def check_ruby
      response = Net::HTTP.post(URI("#{@app}/ruby/notify"), "")
      report = JSON.parse(response.body)
      check(report["available"] == true, "Ruby found the control channel",
            "DesktopRails::Native was not available to the app's Ruby: #{report.inspect}")
      check(report.dig("notify", "status") == "shown" && report.dig("notify", "id") == "ruby-job",
            "DesktopRails::Native.notify answered shown for ruby-job",
            "DesktopRails::Native.notify answered #{report.inspect}")
      expected = linux? ? "granted" : "unknown"
      check(report["permission"] == expected, "Ruby read the notification permission as #{expected.inspect}",
            "Ruby read the notification permission as #{report["permission"].inspect}")
      check(report.dig("badge", "supported") == true, "Ruby set the badge", "Ruby's badge answered #{report["badge"].inspect}")
      return unless linux?

      received = NativeCheck.eventually(10) do
        service_log("Notify").find { |n| n["summary"] == "Ruby says done" }
      end
      check(received && received["body"] == "from a Rails controller",
            "the notification service received Ruby's Notify(\"Ruby says done\", \"from a Rails controller\")",
            "Ruby's notification never reached the notification service: #{service_log("Notify").inspect}")
    rescue StandardError => e
      problem("could not ask the app's Ruby to notify: #{e.class}: #{e.message}")
    end

    # ─── keys, clicks and focus (Linux, under Xvfb with a window manager) ──

    def xdotool(*args)
      NativeCheck.command("xdotool", *args)
    end

    def active_window_name
      output, success = xdotool("getactivewindow", "getwindowname")
      success ? output : nil
    end

    # Give focus to another application's window, so bringing the app forward
    # is something that has to happen rather than something already true.
    def app_window
      NativeCheck.eventually(15) do
        output, success = xdotool("search", "--name", "^#{APP_TITLE}$")
        success && output.lines.first&.strip
      end
    end

    # Summoning only means something when the app is not already in front, so
    # the app is pushed to the back first. Two ways, because a bare X session
    # is not a desktop: another application's window taking focus, and, when
    # that does not settle, iconifying the app's own window — which is the
    # state a summon shortcut exists for anyway.
    #
    # Returns what was done, or nil when neither worked, in which case the
    # caller still checks that the event reached the page and says that
    # bringing the window forward was not observed.
    def move_focus_away
      if (window = other_application_window) &&
         activate(window) { (name = active_window_name) && name != APP_TITLE }
        note("another application's window has focus: #{active_window_name.inspect}")
        return "another application had focus"
      end

      window = app_window
      return nil unless window

      xdotool("windowminimize", "--sync", window)
      minimized = NativeCheck.eventually(10) do
        output, success = xdotool("search", "--onlyvisible", "--name", "^#{APP_TITLE}$")
        !success || output.strip.empty?
      end
      return nil unless minimized

      note("the app's window is minimized")
      "the window was minimized"
    end

    def other_application_window
      @other ||= Process.spawn("xmessage", "-name", "someone-else", "Someone else's window",
                               out: File.join(@logs, "xmessage.log"), err: [ :child, :out ])
      NativeCheck.eventually(15) do
        output, success = xdotool("search", "--classname", "someone-else")
        success && output.lines.last&.strip
      end
    end

    # Ask for the window repeatedly: a window manager may refuse the first
    # request while it is still mapping windows.
    def activate(window)
      NativeCheck.eventually(10, interval: 1) do
        xdotool("windowactivate", "--sync", window)
        yield
      end
    end

    def app_became_active(what, moved)
      unless moved
        return note("not observed: focus could not be taken away from the app first, so " \
                    "#{what} bringing the window forward was not checked")
      end

      active = NativeCheck.eventually(15) do
        visible, = xdotool("search", "--onlyvisible", "--name", "^#{APP_TITLE}$")
        active_window_name == APP_TITLE && !visible.strip.empty?
      end
      check(active, "#{what} brought #{APP_TITLE.inspect} to the front (from #{moved})",
            "#{what} left #{active_window_name.inspect} active, not #{APP_TITLE.inspect}")
    end

    def check_summon
      moved = move_focus_away

      xdotool("key", "--clearmodifiers", "ctrl+alt+s")
      summoned = NativeCheck.eventually(15) { reports("summon").first }
      check(summoned && summoned["accelerator"] == "Ctrl+Alt+S",
            "the config's summon shortcut fired with no page code registering it (desktop-rails:summon reached the page)",
            "pressing Ctrl+Alt+S never reached the page as desktop-rails:summon")
      app_became_active("Ctrl+Alt+S", moved)
    end

    def check_global_shortcut
      xdotool("key", "--clearmodifiers", "ctrl+alt+j")
      fired = NativeCheck.eventually(15) { reports("shortcut").first }
      check(fired && fired["id"] == "palette" && fired["accelerator"] == "Ctrl+Alt+J",
            "pressing Ctrl+Alt+J fired the page's palette shortcut",
            "pressing Ctrl+Alt+J never reached the page: #{reports.map { |r| r["kind"] }.inspect}")

      released = NativeCheck.eventually(15) { reports("shortcut-unregistered").first }
      check(released && released["ok"] && released.dig("value", "released") == true,
            "the page unregistered it", "unregistering answered #{released.inspect}")

      sleep 1
      xdotool("key", "--clearmodifiers", "ctrl+alt+j")
      sleep 4
      count = reports("shortcut").size
      check(count == 1, "after unregistering, pressing Ctrl+Alt+J again reached nobody (1 report, the reload did not double it)",
            "Ctrl+Alt+J produced #{count} reports; expected exactly 1")
    end

    def check_menu_item
      window = app_window
      return problem("could not find the app's window to press the menu accelerator in") unless window

      activate(window) { active_window_name == APP_TITLE }
      xdotool("key", "--clearmodifiers", "ctrl+shift+e")
      clicked = NativeCheck.eventually(15) { reports("menu-item").first }
      check(clicked && clicked["id"] == "export",
            "the menu item's accelerator (Ctrl+Shift+E in the focused window) reached the page as desktop-rails:menu-item",
            "the menu item never reached the page: #{reports.map { |r| r["kind"] }.inspect}")
    end

    def check_notification_click(ready)
      clickable = ready["clickable"]
      return problem("the clickable notification was not shown: #{clickable.inspect}") unless clickable && clickable["ok"]

      moved = move_focus_away
      output, success = NativeCheck.command(
        "dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.Notifications",
        "/org/freedesktop/Notifications", "org.desktop_rails.NotificationStub.Click", "string:Click me"
      )
      return problem("the stand-in service could not click the notification: #{output}") unless success

      clicked = NativeCheck.eventually(15) { reports("notification-click").first }
      check(clicked && clicked["id"] == "click-me",
            "clicking the notification (ActionInvoked \"default\") reached the page as desktop-rails:notification-click",
            "the notification click never reached the page")
      app_became_active("Clicking the notification", moved)
    end

    # ─── macOS: what can honestly be observed ────────────────────────────

    # Synthetic key events need the Accessibility permission for whatever
    # posts them, which a CI runner may not have granted. Tried, reported,
    # and not failed on: a silent result here says nothing about the shell.
    def try_synthetic_keys_on_macos
      delivered = NativeCheck.eventually(10) do
        NativeCheck.notification_center_records.any? { |bytes| bytes.include?("Ruby says done".b) }
      end
      if delivered
        ok("Notification Center's database holds Ruby's notification")
      else
        note("not observable on this runner: Notification Center's database is unreadable or does not show " \
             "Ruby's notification (#{NativeCheck.notification_center_records.size} database files readable)")
      end

      output, success = NativeCheck.command(
        "osascript", "-e", 'tell application "System Events" to key code 38 using {control down, option down}'
      )
      fired = success && NativeCheck.eventually(10) { reports("shortcut").first }
      if fired
        ok("a synthetic Ctrl+Option+J reached the page's global shortcut on macOS")
      else
        note("not observable on this runner: a synthetic Ctrl+Option+J did not reach the page " \
             "(osascript: #{success ? "ran" : output[0, 120]})")
      end
    end
  end

  BUNDLE_ID = "dev.desktop-rails.native-check"

  # macOS sends a notification under the sending app's bundle identifier, and
  # the shell refuses to notify from a process that has none rather than have
  # it vanish. So the debug shell runs from inside a minimal .app, registered
  # with Launch Services, as a packaged app would be once opened.
  def bundle_for_macos(binary:, out:)
    app = File.join(out, "#{APP_TITLE}.app")
    FileUtils.rm_rf(app)
    FileUtils.mkdir_p(File.join(app, "Contents", "MacOS"))
    FileUtils.cp(binary, File.join(app, "Contents", "MacOS", "desktop-rails"))
    File.write(File.join(app, "Contents", "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>#{BUNDLE_ID}</string>
        <key>CFBundleName</key><string>#{APP_TITLE}</string>
        <key>CFBundleExecutable</key><string>desktop-rails</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>NSHighResolutionCapable</key><true/>
      </dict></plist>
    PLIST
    signed = command("codesign", "--force", "--sign", "-", app)
    abort "FAIL  could not sign #{app}: #{signed.first}" unless signed.last
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    registered = command(lsregister, "-f", app)
    abort "FAIL  Launch Services did not register #{app}: #{registered.first}" unless registered.last
    puts "OK    #{app} is signed ad hoc and registered as #{BUNDLE_ID}"
    puts File.join(app, "Contents", "MacOS", "desktop-rails")
  end

  # Notification Center keeps what it delivered in a database. Where it is and
  # whether a runner may read it depends on the macOS version and on Full Disk
  # Access, so finding a notification there is reported and not finding it is
  # only noted.
  def notification_center_records
    user_dir = command("getconf", "DARWIN_USER_DIR").first
    [
      File.join(user_dir, "com.apple.notificationcenter", "db2", "db"),
      File.expand_path("~/Library/Group Containers/group.com.apple.usernoted/db2/db")
    ].flat_map { |db| [ db, "#{db}-wal" ] }.filter_map do |path|
      File.binread(path) if File.file?(path) && File.readable?(path)
    rescue SystemCallError
      nil
    end
  end

  def wait_for_session(logs:, timeout: 60)
    display = eventually(timeout) { command("xdotool", "getdisplaygeometry").last }
    abort "FAIL  the X display at #{ENV["DISPLAY"].inspect} never answered" unless display
    puts "OK    X display #{ENV["DISPLAY"]} is up"

    start_window_manager(logs: logs, timeout: timeout)

    service = eventually(timeout) { jsonl(File.join(logs, "notifications.jsonl")).any? { |e| e["event"] == "ready" } }
    abort "FAIL  the stand-in notification service never owned its name" unless service
    output, = command("dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                      "org.freedesktop.DBus.NameHasOwner", "string:org.freedesktop.Notifications")
    abort "FAIL  org.freedesktop.Notifications has no owner: #{output}" unless output.include?("boolean true")
    puts "OK    org.freedesktop.Notifications is owned on #{ENV["DBUS_SESSION_BUS_ADDRESS"]}"

    hold_a_shortcut(logs: logs, timeout: timeout)
  end

  # Which window has focus is a window manager's business, and a bare X server
  # has none: without one `xdotool getactivewindow` answers nothing, and
  # "the summon shortcut brought the window forward" cannot be observed at all.
  #
  # Started here rather than by the workflow because openbox has to come after
  # the display, and starting both as background jobs in one step raced: the
  # run that lost left no window manager and every focus check unanswerable.
  def start_window_manager(logs:, timeout: 60)
    Process.spawn("openbox", out: File.join(logs, "openbox.log"), err: [ :child, :out ], pgroup: true)
    running = eventually(timeout) do
      output, success = command("xprop", "-root", "-notype", "_NET_SUPPORTING_WM_CHECK")
      success && output.include?("window id")
    end
    abort "FAIL  no window manager on #{ENV["DISPLAY"]}: #{File.read(File.join(logs, "openbox.log")) rescue ""}" unless running
    puts "OK    a window manager is running, so focus can be observed"
  end

  # Another X client holding Ctrl+Alt+K, so the app's attempt to register it is
  # refused by the X server the way it would be if the person's window manager
  # or another application had that combination.
  #
  # Started here rather than by the workflow, and only reported as up once the
  # grab has actually fired: xbindkeys takes a moment to grab, and an app that
  # registers in that moment gets the combination, which used to make this
  # check fail for a reason that had nothing to do with the shell.
  def hold_a_shortcut(logs:, timeout: 60)
    fired = File.join(logs, "xbindkeys-fired")
    File.delete(fired) if File.exist?(fired)
    config = File.join(logs, "xbindkeysrc")
    File.write(config, <<~CONFIG)
      # Touch a file, so the grab can be seen from outside before the app starts.
      "touch #{fired}"
          control+alt + k
    CONFIG

    Process.spawn("xbindkeys", "-n", "-f", config,
                  out: File.join(logs, "xbindkeys.log"), err: [ :child, :out ], pgroup: true)

    grabbed = eventually(timeout) do
      command("xdotool", "key", "--clearmodifiers", "ctrl+alt+k")
      sleep 1
      File.exist?(fired)
    end
    abort "FAIL  xbindkeys never took Ctrl+Alt+K: #{File.read(File.join(logs, "xbindkeys.log")) rescue ""}" unless grabbed
    puts "OK    another X client (xbindkeys) holds Ctrl+Alt+K"
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  options = { platform: RUBY_PLATFORM.include?("darwin") ? "macos" : "linux", app: "http://127.0.0.1:3300", timeout: 180 }
  OptionParser.new do |parser|
    parser.on("--platform NAME") { |v| options[:platform] = v }
    parser.on("--logs DIR") { |v| options[:logs] = v }
    parser.on("--app URL") { |v| options[:app] = v }
    parser.on("--timeout SECONDS", Integer) { |v| options[:timeout] = v }
  end.parse!(ARGV)
  abort "--logs DIR is required" unless options[:logs]

  case command
  when "bundle-macos"
    NativeCheck.bundle_for_macos(binary: ARGV.fetch(0), out: options[:logs])
  when "session"
    NativeCheck.wait_for_session(logs: options[:logs])
  when "run"
    problems = NativeCheck::Run.new(**options).call
    unless problems.empty?
      puts "\n#{problems.size} check(s) failed. Shell log:"
      shell_log = File.join(options[:logs], "shell.log")
      puts File.exist?(shell_log) ? File.readlines(shell_log).last(60).join : "(none)"
      exit 1
    end
  else
    abort "usage: ruby e2e/native/check.rb session|run --logs DIR [--platform linux|macos] [--app URL]"
  end
end
