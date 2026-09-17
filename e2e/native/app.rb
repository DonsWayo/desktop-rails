# A one-file Rails app for .github/workflows/native-features.yml.
#
# The shell starts it (server.command in desktop-rails.config.json), so it gets
# the control channel, and the window loads it on 127.0.0.1:3300. Its page uses
# the notification, badge, shortcut and menu-item components the way an app
# would, and reports every answer and every event back to this server, which
# appends them to REPORTS_FILE. e2e/native/check.rb reads that file, presses the
# keys, clicks the notification through the stand-in notification service, and
# asks this server to notify from Ruby.

require "fileutils"
require "json"
require "logger"
require "bundler/setup"
require "rails"
require "action_controller/railtie"

# Loads the desktop-rails engine, which reads the shell's handshake at boot.
Bundler.require(*Rails.groups)

module NativeCheck
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "native-check-not-a-secret"
    config.hosts.clear
    config.consider_all_requests_local = false
    config.logger = ActiveSupport::Logger.new(ENV["NATIVE_LOG"] || $stderr)
    config.log_level = :info

    routes.append do
      root "pages#show"
      post "reports", to: "reports#create"
      post "ruby/notify", to: "ruby#notify"
      get "up", to: proc { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }
    end
  end
end

module Reports
  module_function

  def append(report)
    Rails.logger.info("REPORT #{report.to_json}")
    File.open(path, "a") { |file| file.puts(report.to_json) }
  end

  def path
    ENV.fetch("REPORTS_FILE") do
      File.expand_path("log/reports.jsonl", __dir__).tap { |file| FileUtils.mkdir_p(File.dirname(file)) }
    end
  end
end

class PagesController < ActionController::Base
  # Everything runs on every load. The page reloads itself once after the first,
  # so the second load registers the same shortcut and menu item again, which
  # is what an app does on every navigation and must not grab anything twice.
  SCRIPT = <<~JS
    const report = (kind, detail = {}) =>
      fetch("/reports", { method: "POST", headers: { "Content-Type": "application/json" },
                          body: JSON.stringify({ kind, ...detail }) });

    const waitFor = async (check, timeout = 20000) => {
      for (let waited = 0; waited < timeout; waited += 100) {
        const value = check();
        if (value) return value;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      return null;
    };

    // A refusal is data to report, not an exception to lose.
    const attempt = async (call) => {
      try { return { ok: true, value: await call() }; }
      catch (error) { return { ok: false, error: String(error && error.message || error) }; }
    };

    (async () => {
      const injected = await waitFor(() => window.__TAURI_INTERNALS__ && window.DesktopRails && window.DesktopRails.shortcuts);
      if (!injected) return report("load", { bridge: false });
      const dr = window.DesktopRails;

      const loads = Number(sessionStorage.getItem("loads") || 0) + 1;
      sessionStorage.setItem("loads", String(loads));

      // Listen before registering anything, so no event can be missed.
      dr.shortcuts.on("palette", async (data) => {
        await report("shortcut", { ...data, loads });
        // Released on the first press: the next press must reach nobody.
        await report("shortcut-unregistered", await attempt(() => dr.shortcuts.unregister("palette")));
      });
      document.addEventListener("desktop-rails:summon", (event) =>
        report("summon", { ...event.detail, loads }));
      document.addEventListener("desktop-rails:notification-click", (event) =>
        report("notification-click", { ...event.detail, loads }));
      document.addEventListener("desktop-rails:menu-item", (event) =>
        report("menu-item", { ...event.detail, loads }));

      const results = {
        permission: await attempt(() => dr.notifications.permission()),
        register: await attempt(() => dr.shortcuts.register("palette", "Ctrl+Alt+J")),
        // Held by xbindkeys in the Linux job: another application's grab.
        taken: await attempt(() => dr.shortcuts.register("taken", "Ctrl+Alt+K")),
        duplicate: await attempt(() => dr.shortcuts.register("other", "Ctrl+Alt+J")),
        bare: await attempt(() => dr.shortcuts.register("bare", "K")),
        summonClash: await attempt(() => dr.shortcuts.register("clash", "Ctrl+Alt+S")),
        menu: await attempt(() => dr.menu.add({ id: "export", title: "Export Report", accelerator: "Ctrl+Shift+E", menu: "File" })),
        badge: await attempt(() => dr.badge.set(7)),
        label: await attempt(() => dr.badge.setLabel("new")),
        notify: await attempt(() => dr.notifications.show({ title: "Page says hello", body: "from JavaScript", id: "page-hello" })),
      };
      await report("load", { loads, results });

      if (loads === 1) {
        location.reload();
        return;
      }

      // Shown once the page will stay, so the click lands on a page listening.
      const clickable = await attempt(() => dr.notifications.show({ title: "Click me", body: "the stand-in service clicks this", id: "click-me" }));
      await report("ready", { loads, clickable });
    })().catch((error) => report("error", { error: String(error && error.stack || error) }));
  JS

  def show
    render html: <<~HTML.html_safe
      <!doctype html>
      <html><head><title>Native Check</title></head>
      <body><h1>Native Check</h1><script>#{SCRIPT}</script></body></html>
    HTML
  end
end

# API rather than Base: a report carries no session, so there is no CSRF token
# to check, and Base would refuse it without one.
class ReportsController < ActionController::API
  def create
    Reports.append(JSON.parse(request.raw_post))
    head :no_content
  end
end

# Ruby reaching the shell over the control channel, the way a background job
# would when a long task finishes.
class RubyController < ActionController::API
  def notify
    report = { kind: "ruby", available: DesktopRails::Native.available? }
    begin
      report[:notify] = DesktopRails::Native.notify(title: "Ruby says done", body: "from a Rails controller", id: "ruby-job")
      report[:permission] = DesktopRails::Native.notification_permission
      report[:badge] = DesktopRails::Native.badge(3)
    rescue DesktopRails::Native::Error => e
      report[:error] = "#{e.class}: #{e.message}"
    end
    Reports.append(report)
    render json: report
  end
end
