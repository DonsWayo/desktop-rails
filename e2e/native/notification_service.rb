# A stand-in for the desktop's notification daemon, on the session bus of the
# Linux job.
#
#   bundle exec ruby notification_service.rb --log PATH
#
# It owns org.freedesktop.Notifications and implements the part of the spec a
# client uses, so the shell talks to it exactly as it would to GNOME Shell,
# dunst or Plasma. Every Notify call is appended to the log with the arguments
# as they crossed the bus. A real daemon's user clicks a notification; this one
# is told to, through org.desktop_rails.NotificationStub.Click, and answers the
# way a daemon does: an ActionInvoked signal carrying the "default" action.
#
# It also records com.canonical.Unity.LauncherEntry updates, the signal docks
# read a badge count from, since nothing else on this bus would show them.

require "dbus"
require "json"
require "optparse"

log_path = nil
OptionParser.new { |parser| parser.on("--log PATH") { |value| log_path = value } }.parse!(ARGV)
abort "usage: ruby notification_service.rb --log PATH" unless log_path

Record = lambda do |entry|
  File.open(log_path, "a") { |file| file.puts(JSON.generate(entry.merge(at: Time.now.to_f))) }
  $stdout.puts(JSON.generate(entry))
  $stdout.flush
end

class NotificationService < DBus::Object
  def initialize(path)
    super
    @next_id = 0
    @shown = {}
  end

  dbus_interface "org.freedesktop.Notifications" do
    dbus_method :Notify,
                "in app_name:s, in replaces_id:u, in app_icon:s, in summary:s, in body:s, " \
                "in actions:as, in hints:a{sv}, in expire_timeout:i, out id:u" do |app_name, replaces_id, _icon, summary, body, actions, _hints, expire|
      id = replaces_id.positive? ? replaces_id : (@next_id += 1)
      @shown[summary] = id
      Record.call(event: "Notify", id: id, app_name: app_name, replaces_id: replaces_id,
                  summary: summary, body: body, actions: actions, expire_timeout: expire)
      [ id ]
    end

    dbus_method :GetServerInformation, "out name:s, out vendor:s, out version:s, out spec_version:s" do
      Record.call(event: "GetServerInformation")
      [ "desktop-rails-stub", "desktop-rails", "1.0", "1.2" ]
    end

    dbus_method :GetCapabilities, "out capabilities:as" do
      [ %w[actions body] ]
    end

    dbus_method :CloseNotification, "in id:u" do |id|
      NotificationClosed(id, 3)
    end

    dbus_signal :ActionInvoked, "id:u, action_key:s"
    dbus_signal :NotificationClosed, "id:u, reason:u"
  end

  dbus_interface "org.desktop_rails.NotificationStub" do
    # Click the most recent notification with this summary, as a person would.
    dbus_method :Click, "in summary:s, out id:u" do |summary|
      id = @shown.fetch(summary) { raise DBus.error("org.desktop_rails.NotShown"), "nothing shown as #{summary.inspect}" }
      Record.call(event: "Click", id: id, summary: summary)
      ActionInvoked(id, "default")
      [ id ]
    end
  end
end

bus = DBus::SessionBus.instance
bus.object_server.export(NotificationService.new("/org/freedesktop/Notifications"))

launcher = DBus::MatchRule.new
launcher.type = "signal"
launcher.interface = "com.canonical.Unity.LauncherEntry"
bus.add_match(launcher) do |message|
  app_uri, properties = message.params
  Record.call(event: "LauncherEntry.Update", member: message.member, app_uri: app_uri, properties: properties)
end

bus.request_name("org.freedesktop.Notifications")
Record.call(event: "ready")

main = DBus::Main.new
main << bus
main.run
