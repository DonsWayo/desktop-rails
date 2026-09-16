# A one-file Rails app playing two servers in the hosted-mode CI job.
#
# Started on 127.0.0.1:3100 it is the app: the origin the packaged window is
# configured with, and so the only one the bridge should answer. Started again
# on localhost:3101 it is someone else's site, which the config lets load in the
# window (navigation.internal_hosts) but must not let near the bridge. Every
# page reports what the shell said to it back to the server that served it, and
# e2e/hosted/check.rb reads those reports, so each result is observed by the
# origin it is about.

require "fileutils"
require "json"
require "logger"
require "bundler/setup"
require "rails"
require "action_controller/railtie"

# As a generated app's config/application.rb does, which is what loads the
# desktop-rails engine and with it the desktop:* rake tasks.
Bundler.require(*Rails.groups)

module HostedCheck
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "hosted-check-not-a-secret"
    config.hosts.clear
    config.consider_all_requests_local = false
    # A file the CI job reads when it is given one; standard output otherwise,
    # so loading the app for its rake tasks writes nowhere.
    config.logger = ActiveSupport::Logger.new(ENV["HOSTED_LOG"] || $stdout)
    config.log_level = :info

    routes.append do
      root "pages#app"
      get "untrusted", to: "pages#untrusted"
      get "frame", to: "pages#frame"
      post "reports", to: "reports#create"
      get "up", to: proc { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }
    end
  end
end

# The script every page shares: call the shell the way desktop-rails.js does,
# and tell this page's own server what happened.
BRIDGE_SCRIPT = <<~JS
  const report = (kind, detail) =>
    fetch("/reports", { method: "POST", headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({ kind, origin: location.origin, ...detail }) });

  const waitFor = async (check, timeout = 20000) => {
    for (let waited = 0; waited < timeout; waited += 100) {
      const value = check();
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return null;
  };

  // Resolves to { ok, value } or { ok: false, error } instead of throwing, so
  // a refusal is data to report rather than an exception to lose.
  const call = async (component, event, data = {}) => {
    try {
      const value = await window.__TAURI_INTERNALS__.invoke("handle_bridge_message", {
        message: { component, event, data }
      });
      return { ok: true, value };
    } catch (error) {
      return { ok: false, error: String(error) };
    }
  };
JS

class PagesController < ActionController::Base
  UNTRUSTED = ENV.fetch("UNTRUSTED_URL", "http://localhost:3101")
  ELSEWHERE = ENV.fetch("ELSEWHERE_URL", "http://127.0.0.1:3102/elsewhere")

  # The app. It checks that the bridge works for it and that everything a
  # minimal config leaves closed is closed, then embeds a frame from the other
  # origin, follows a link to a site the config does not list, and finally
  # navigates the window to the other origin.
  def app
    render html: page("Hosted check", <<~JS)
      (async () => {
        const internals = await waitFor(() => window.__TAURI_INTERNALS__?.invoke);
        if (!internals) return report("trusted", { internals: false });

        const state = await call("window", "state");
        const shell = await call("shell", "spawn", { id: "hosted-check", command: "echo", args: ["pwned"] });
        const clipboard = await call("clipboard", "read-text");
        const filesystem = await call("filesystem", "read", { path: "/etc/hosts" });
        await report("trusted", { internals: true, state, shell, clipboard, filesystem });

        const frame = document.createElement("iframe");
        frame.src = #{"#{UNTRUSTED}/frame".to_json};
        document.body.appendChild(frame);
        await new Promise((resolve) => setTimeout(resolve, 4000));

        // Not in the config, so the shell hands it to the browser and the
        // window stays here.
        location.href = #{ELSEWHERE.to_json};
        await new Promise((resolve) => setTimeout(resolve, 3000));
        await report("stayed", { href: location.href });

        location.href = #{"#{UNTRUSTED}/untrusted".to_json};
      })();
    JS
  end

  # Someone else's page, loaded in the window as a top-level page. It has what
  # every page in the window has — Tauri's invoke function — and asks for the
  # same harmless thing the app just got.
  def untrusted
    render html: page("Someone else", <<~JS)
      (async () => {
        const internals = await waitFor(() => window.__TAURI_INTERNALS__?.invoke);
        const state = internals ? await call("window", "state") : null;
        await report("untrusted", { internals: Boolean(internals), state });
      })();
    JS
  end

  # Someone else's page inside the app's page. Tauri gives frames no invoke
  # function and no key, and the parent is a different origin it cannot reach.
  def frame
    # Rails sends X-Frame-Options: SAMEORIGIN by default, which would keep this
    # page out of the app's frame before it could try anything, and prove
    # nothing about the shell.
    response.headers.delete("X-Frame-Options")
    render html: page("Frame", <<~JS)
      (async () => {
        let parent;
        try { parent = Boolean(window.parent.__TAURI_INTERNALS__); } catch (error) { parent = String(error); }
        const own = typeof window.__TAURI_INTERNALS__?.invoke === "function";
        const state = own ? await call("window", "state") : null;
        await report("frame", { internals: own, parent, state });
      })();
    JS
  end

  private

  def page(title, script)
    <<~HTML.html_safe
      <!doctype html>
      <html><head><title>#{title}</title></head>
      <body><h1>#{title}</h1><script>#{BRIDGE_SCRIPT}\n#{script}</script></body></html>
    HTML
  end
end

# API rather than Base: a report carries no session, so there is no CSRF token
# to check, and Base would refuse it without one.
class ReportsController < ActionController::API
  def create
    report = JSON.parse(request.raw_post)
    Rails.logger.info("REPORT #{report.to_json}")
    File.open(reports_file, "a") { |file| file.puts(report.to_json) }
    head :no_content
  end

  private

  def reports_file
    ENV.fetch("REPORTS_FILE") do
      File.expand_path("log/reports.jsonl", __dir__).tap { |path| FileUtils.mkdir_p(File.dirname(path)) }
    end
  end
end
