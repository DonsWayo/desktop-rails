/**
 * Desktop Rails — JavaScript Bridge
 *
 * This script is injected into the WebView by the Tauri shell.
 * It hooks into Turbo Drive events and provides the bridge between
 * web components and native desktop features.
 *
 * Architecture (mirrors Hotwire Native mobile):
 * 1. Intercept Turbo navigation → send visit proposals to Rust
 * 2. Sync page title → native window title bar
 * 3. Bridge components → JS ↔ Rust message passing (Strada equivalent)
 */
(function () {
  "use strict";

  // Guard against double-injection
  if (window.__DESKTOP_RAILS__) return;

  const INVOKE = window.__TAURI_INTERNALS__?.invoke;

  // Native → page events. Tauri's own event API is not exposed to pages
  // loaded from a remote URL — which an app page always is — so the shell
  // delivers responses through __receive and this fans them out. Handlers
  // get the same `{ payload }` shape Tauri's `listen` would have given them.
  const bridgeResponseHandlers = new Set();
  function onBridgeResponse(handler) {
    bridgeResponseHandlers.add(handler);
    return () => bridgeResponseHandlers.delete(handler);
  }
  /** Call back with the data of one component's event. */
  function listenFor(component, eventName, callback) {
    return onBridgeResponse((event) => {
      const payload = event.payload;
      if (payload && payload.component === component && payload.event === eventName) {
        callback(payload.data || {});
      }
    });
  }
  function dispatchBridgeResponse(payload) {
    bridgeResponseHandlers.forEach((handler) => {
      try {
        handler({ payload });
      } catch (e) {
        console.error("[desktop-rails] A bridge-response handler failed:", e);
      }
    });
  }

  // ─── Core API ──────────────────────────────────────────────────────────────

  const DesktopRails = {
    version: "0.3.0-pre.3",
    platform: "macos",
    isNative: true,

    /**
     * Send a visit proposal to the native shell.
     * The shell consults the path configuration and decides how to present the URL.
     */
    async proposeVisit(url, action = "advance") {
      if (!INVOKE) return { action, presentation: "default" };

      try {
        const urlObj = new URL(url, window.location.origin);
        return await INVOKE("handle_visit_proposal", {
          proposal: {
            url: urlObj.href,
            path: urlObj.pathname,
            action: action,
          },
        });
      } catch (e) {
        console.error("[desktop-rails] Visit proposal failed:", e);
        return { action, presentation: "default" };
      }
    },

    /**
     * Update the native window title.
     */
    async setTitle(title) {
      if (!INVOKE) return;
      try {
        await INVOKE("update_window_title", { title });
      } catch (e) {
        console.error("[desktop-rails] Set title failed:", e);
      }
    },

    /**
     * Send a bridge message to the native shell.
     */
    async sendBridgeMessage(component, event, data = {}) {
      if (!INVOKE) return null;
      try {
        return await INVOKE("handle_bridge_message", {
          message: { component, event, data },
        });
      } catch (e) {
        console.error("[desktop-rails] Bridge message failed:", e);
        return null;
      }
    },

    /**
     * Send a bridge message and reject when the shell refuses it.
     *
     * sendBridgeMessage() turns every failure into null, which is how a stub
     * used to read as success. The notification, badge, shortcut and menu APIs
     * use this instead, so "another application already uses Ctrl+Alt+K"
     * reaches the caller as an Error with that message. Outside the shell it
     * resolves to null, the same no-op as everything else.
     */
    async invokeBridge(component, event, data = {}) {
      if (!INVOKE) return null;
      try {
        return await INVOKE("handle_bridge_message", {
          message: { component, event, data },
        });
      } catch (e) {
        throw new Error(typeof e === "string" ? e : (e && e.message) || String(e), { cause: e });
      }
    },

    /**
     * Get information about the current window.
     */
    async getWindowInfo() {
      if (!INVOKE) return null;
      try {
        return await INVOKE("get_window_info");
      } catch (e) {
        console.error("[desktop-rails] Window info failed:", e);
        return null;
      }
    },

    /**
     * The label of the window this page is in, or null outside the shell.
     */
    get windowLabel() {
      return window.__DESKTOP_RAILS_WINDOW_LABEL__ || null;
    },

    /**
     * True when this page is in a modal window rather than the main one.
     */
    get isModal() {
      return String(this.windowLabel || "").startsWith("modal-");
    },

    /**
     * Close a modal window. Defaults to the window this page is in, so a page
     * can dismiss itself without being told which window it was opened in.
     */
    async closeModal(label = undefined) {
      if (!INVOKE) return;

      const target = label || DesktopRails.windowLabel;
      if (!target) {
        console.warn("[desktop-rails] No window label to close");
        return;
      }

      try {
        await INVOKE("close_modal", { label: target });
      } catch (e) {
        console.error("[desktop-rails] Close modal failed:", e);
      }
    },

    /**
     * Close this modal and go back on the screen underneath, as if it had
     * never been opened. Named after Hotwire Native's dismissal semantics.
     */
    async recede() {
      return DesktopRails.dismiss("recede");
    },

    /**
     * Close this modal and reload the screen underneath — what you usually
     * want after a form submits.
     */
    async refresh() {
      return DesktopRails.dismiss("refresh");
    },

    /** Close this modal and leave the screen underneath as it was. */
    async resume() {
      return DesktopRails.dismiss("resume");
    },

    async dismiss(then = "resume", label = undefined) {
      if (!INVOKE) return;

      try {
        await INVOKE("dismiss_modal", { label: label || null, then });
      } catch (e) {
        console.error("[desktop-rails] Dismiss failed:", e);
      }
    },

    /**
     * Toggle developer tools (dispatches to Rust which can open the inspector).
     */
    toggleDevTools() {
      // Tauri 2 doesn't expose devtools toggle from JS directly,
      // but we can emit a custom event for the Rust side to handle
      console.log("[desktop-rails] DevTools toggle requested");
    },

    // ─── Shell Execution API ─────────────────────────────────────────────────

    shell: {
      _listeners: new Map(),

      async spawn(id, command, args = [], options = {}) {
        return DesktopRails.sendBridgeMessage("shell", "spawn", {
          id,
          command,
          args,
          env: options.env || {},
          cwd: options.cwd || null,
        });
      },

      async kill(id) {
        return DesktopRails.sendBridgeMessage("shell", "kill", { id });
      },

      async status(id) {
        return DesktopRails.sendBridgeMessage("shell", "status", { id });
      },

      async list() {
        return DesktopRails.sendBridgeMessage("shell", "list", {});
      },

      onOutput(id, callback) {
        const handler = (event) => {
          const payload = event.payload;
          if (
            payload &&
            payload.component === "shell" &&
            payload.data &&
            payload.data.id === id
          ) {
            callback({
              event: payload.event,
              line: payload.data.line,
              code: payload.data.code,
            });
          }
        };

        this._listeners.set(id, onBridgeResponse(handler));
      },

      offOutput(id) {
        const unlisten = this._listeners.get(id);
        if (unlisten) {
          unlisten();
          this._listeners.delete(id);
        }
      },
    },

    // ─── Sudo API ─────────────────────────────────────────────────────────────

    sudo: {
      async execute(command) {
        return DesktopRails.sendBridgeMessage("sudo", "execute", { command });
      },

      _listeners: new Map(),

      async spawn(id, command) {
        return DesktopRails.sendBridgeMessage("sudo", "spawn", { id, command });
      },

      onOutput(id, callback) {
        const handler = (event) => {
          const payload = event.payload;
          if (
            payload &&
            payload.component === "sudo" &&
            payload.data &&
            payload.data.id === id
          ) {
            callback({
              event: payload.event,
              line: payload.data.line,
              code: payload.data.code,
            });
          }
        };

        this._listeners.set(id, onBridgeResponse(handler));
      },

      offOutput(id) {
        const unlisten = this._listeners.get(id);
        if (unlisten) {
          unlisten();
          this._listeners.delete(id);
        }
      },
    },

    // ─── Updater API ─────────────────────────────────────────────────────────

    updater: {
      async check() {
        return DesktopRails.sendBridgeMessage("updater", "check", {});
      },

      async downloadAndInstall() {
        return DesktopRails.sendBridgeMessage("updater", "download-and-install", {});
      },
    },

    // ─── Window API ──────────────────────────────────────────────────────────
    //
    // The frame around the page, which CSS cannot reach. Layout, zoom and
    // scrolling stay in the stylesheet where they belong; this is only the
    // window itself.
    //
    //   import { DesktopRails } from "desktop-rails-bridge"
    //   await DesktopRails.window.resize(1200, 900)
    //   await DesktopRails.window.fullscreen(true)
    //
    // resize() honours the app's own config: a window declared non-resizable
    // refuses, and the configured minimums win over a smaller request, so the
    // page cannot produce a window nobody can use.

    window: {
      async resize(width, height) {
        return DesktopRails.sendBridgeMessage("window", "resize", { width, height });
      },

      async minimize() {
        return DesktopRails.sendBridgeMessage("window", "minimize", {});
      },

      async unminimize() {
        return DesktopRails.sendBridgeMessage("window", "unminimize", {});
      },

      async maximize() {
        return DesktopRails.sendBridgeMessage("window", "maximize", {});
      },

      async unmaximize() {
        return DesktopRails.sendBridgeMessage("window", "unmaximize", {});
      },

      async toggleMaximize() {
        return DesktopRails.sendBridgeMessage("window", "toggle-maximize", {});
      },

      async fullscreen(enabled = true) {
        return DesktopRails.sendBridgeMessage("window", "fullscreen", { enabled });
      },

      async center() {
        return DesktopRails.sendBridgeMessage("window", "center", {});
      },

      async alwaysOnTop(enabled = true) {
        return DesktopRails.sendBridgeMessage("window", "always-on-top", { enabled });
      },

      async focus() {
        return DesktopRails.sendBridgeMessage("window", "focus", {});
      },

      /** Current size and state. Unlike getWindowInfo(), this goes through the
       *  bridge, so it works from any window and reports minimized too. */
      async state() {
        return DesktopRails.sendBridgeMessage("window", "state", {});
      },
    },

    // ─── File System API ─────────────────────────────────────────────────────

    fs: {
      async read(path, encoding = "utf8") {
        return DesktopRails.sendBridgeMessage("filesystem", "read", {
          path,
          encoding,
        });
      },

      async write(path, content, options = {}) {
        return DesktopRails.sendBridgeMessage("filesystem", "write", {
          path,
          content,
          append: options.append || false,
        });
      },

      async exists(path) {
        return DesktopRails.sendBridgeMessage("filesystem", "exists", { path });
      },

      async list(path) {
        return DesktopRails.sendBridgeMessage("filesystem", "list", { path });
      },

      async mkdir(path) {
        return DesktopRails.sendBridgeMessage("filesystem", "mkdir", { path });
      },

      async remove(path, options = {}) {
        return DesktopRails.sendBridgeMessage("filesystem", "remove", {
          path,
          recursive: options.recursive || false,
        });
      },
    },

    // ─── Drag & Drop API ─────────────────────────────────────────────────────
    //
    // Files dragged from the Finder/Explorer arrive here with their real
    // paths (the shell also grants them for reading, like a dialog pick).
    // Also dispatched as DOM events for Stimulus actions:
    //   desktop-rails:drag-enter, desktop-rails:drop, desktop-rails:drag-leave
    // with { paths, position } in event.detail.

    dragDrop: {
      onDrop(callback) {
        return this._listen("drop", callback);
      },

      onEnter(callback) {
        return this._listen("enter", callback);
      },

      onLeave(callback) {
        return this._listen("leave", callback);
      },

      _listen(name, callback) {
        return onBridgeResponse((event) => {
          const payload = event.payload;
          if (
            payload &&
            payload.component === "drag-drop" &&
            payload.event === name
          ) {
            callback(payload.data);
          }
        });
      },
    },

    // ─── Clipboard API ───────────────────────────────────────────────────────
    //
    // The system clipboard, beyond what the webview can do itself: read what
    // another application put there, write without a user gesture.

    clipboard: {
      async readText() {
        const result = await DesktopRails.sendBridgeMessage(
          "clipboard",
          "read-text",
          {}
        );
        return result ? result.text : null;
      },

      async writeText(text) {
        return DesktopRails.sendBridgeMessage("clipboard", "write-text", {
          text,
        });
      },
    },

    // ─── Notifications API ───────────────────────────────────────────────────
    //
    // OS notifications, delivered by the platform's own service. show()
    // resolves with { status: "shown", id, clickable } once the service has
    // accepted it, and rejects when there is none or the config turned
    // notifications off. A click brings the window forward and fires
    // desktop-rails:notification-click with { id } (Linux and Windows; on
    // macOS the OS activates the app and reports nothing).
    //
    //   await DesktopRails.notifications.show({ title: "Export finished", body: "invoice.pdf", id: "export" })
    //   DesktopRails.notifications.onClick(({ id }) => Turbo.visit(`/exports/${id}`))

    notifications: {
      async show({ title, body = null, id = null } = {}) {
        return DesktopRails.invokeBridge("notification", "show", { title, body, id });
      },

      /** "granted", "denied" (turned off in the config), "unavailable" (no
       *  notification service) or "unknown" (the platform cannot say without
       *  prompting). Desktop platforms never prompt, so asking is looking. */
      async permission() {
        const result = await DesktopRails.invokeBridge("notification", "permission", {});
        return result ? result.permission : "unavailable";
      },

      async requestPermission() {
        return DesktopRails.notifications.permission();
      },

      onClick(callback) {
        return listenFor("notification", "click", callback);
      },
    },

    /** Shorthand for notifications.show(). */
    async notify(title, body = null, options = {}) {
      return DesktopRails.notifications.show({ ...options, title, body });
    },

    // ─── Badge API ───────────────────────────────────────────────────────────
    //
    // The Dock (macOS) or launcher (Linux docks that speak the Unity launcher
    // protocol) badge. Resolves with { supported }: false on Windows, which has
    // no badge for desktop apps, and for labels anywhere but macOS.

    badge: {
      async set(count) {
        return DesktopRails.invokeBridge("badge", "set", { count });
      },

      /** macOS only; elsewhere resolves with supported: false. */
      async setLabel(label) {
        return DesktopRails.invokeBridge("badge", "set", { label });
      },

      async clear() {
        return DesktopRails.invokeBridge("badge", "clear", {});
      },
    },

    // ─── Global Shortcuts API ────────────────────────────────────────────────
    //
    // Combinations that reach the app while another application has focus.
    // They need a Control, Alt/Option or Command/Super modifier. Registering
    // the same id and combination again (after a reload, say) resolves with
    // alreadyRegistered: true rather than grabbing it twice; a combination
    // another application holds rejects.
    //
    //   await DesktopRails.shortcuts.register("palette", "CmdOrCtrl+Shift+K", { focus: true })
    //   DesktopRails.shortcuts.on("palette", () => openPalette())
    //
    // Also dispatched as desktop-rails:shortcut with { id, accelerator }, and
    // the config's summon shortcut as desktop-rails:summon.

    shortcuts: {
      async register(id, accelerator, options = {}) {
        return DesktopRails.invokeBridge("shortcut", "register", {
          id,
          accelerator,
          focus: Boolean(options.focus),
        });
      },

      async unregister(id) {
        return DesktopRails.invokeBridge("shortcut", "unregister", { id });
      },

      /** Releases every shortcut pages registered; the summon shortcut stays. */
      async unregisterAll() {
        return DesktopRails.invokeBridge("shortcut", "unregister-all", {});
      },

      async list() {
        return DesktopRails.invokeBridge("shortcut", "list", {});
      },

      /** Call back when `id` fires. Returns a function that stops listening. */
      on(id, callback) {
        return listenFor("shortcut", "triggered", (data) => {
          if (data && data.id === id) callback(data);
        });
      },

      onSummon(callback) {
        return listenFor("shortcut", "summon", callback);
      },
    },

    // ─── Menu API ────────────────────────────────────────────────────────────
    //
    // Items in the app's menu bar that trigger page actions. `menu` names a
    // top-level menu: an existing one ("File", "View") or a new one, created
    // before "Window". Defaults to "File".
    //
    //   await DesktopRails.menu.add({ id: "export", title: "Export PDF", accelerator: "CmdOrCtrl+Shift+E" })
    //   DesktopRails.menu.onClick("export", () => this.export())
    //
    // Also dispatched as desktop-rails:menu-item with { id }.

    menu: {
      async add({ id, title, accelerator = null, menu = null } = {}) {
        return DesktopRails.invokeBridge("menu-item", "register", { id, title, accelerator, menu });
      },

      async remove(id) {
        return DesktopRails.invokeBridge("menu-item", "unregister", { id });
      },

      async list() {
        return DesktopRails.invokeBridge("menu-item", "list", {});
      },

      onClick(id, callback) {
        return listenFor("menu-item", "click", (data) => {
          if (data && data.id === id) callback(data);
        });
      },
    },

    // ─── Autostart API ───────────────────────────────────────────────────────
    //
    // Launch-at-login, meant to be driven by a toggle in the app's own
    // settings page rather than turned on silently.

    autostart: {
      async enable() {
        return DesktopRails.sendBridgeMessage("autostart", "enable", {});
      },

      async disable() {
        return DesktopRails.sendBridgeMessage("autostart", "disable", {});
      },

      async isEnabled() {
        const result = await DesktopRails.sendBridgeMessage(
          "autostart",
          "status",
          {}
        );
        return Boolean(result && result.enabled);
      },
    },
  };

  // Surface what the shell reports as DOM events, so a Stimulus controller can
  // subscribe with a plain action instead of the DesktopRails API:
  //   data-action="desktop-rails:shortcut@document->palette#open"
  {
    const domEventNames = {
      "drag-drop": {
        enter: "desktop-rails:drag-enter",
        drop: "desktop-rails:drop",
        leave: "desktop-rails:drag-leave",
      },
      notification: { click: "desktop-rails:notification-click" },
      shortcut: { triggered: "desktop-rails:shortcut", summon: "desktop-rails:summon" },
      "menu-item": { click: "desktop-rails:menu-item" },
    };
    onBridgeResponse((event) => {
      const payload = event.payload;
      const names = payload && domEventNames[payload.component];
      const name = names && Object.prototype.hasOwnProperty.call(names, payload.event)
        ? names[payload.event]
        : null;
      if (name) {
        document.dispatchEvent(new CustomEvent(name, { detail: payload.data }));
      }
    });
  }

  // ─── Turbo Drive Integration ───────────────────────────────────────────────

  /**
   * Intercept Turbo Drive's "before-visit" to propose the visit to the native shell.
   * If the shell decides to open a modal or new window, we cancel the Turbo visit.
   */
  document.addEventListener("turbo:before-visit", async (event) => {
    const url = event.detail.url;

    // Notify Rust that a page is loading
    if (INVOKE) {
      INVOKE("page_loading", { url }).catch(() => {});
    }

    // Propose the visit to the native shell
    const response = await DesktopRails.proposeVisit(url, "advance");

    // If the native shell handled it (modal, new window, native screen),
    // cancel the Turbo visit — the native side opens the URL itself.
    if (response.action === "none") {
      event.preventDefault();
    }
    // If "replace", tell Turbo to replace instead of advance
    else if (response.action === "replace") {
      event.preventDefault();
      window.Turbo?.visit(url, { action: "replace" });
    }
  });

  /**
   * After Turbo loads a page, sync the title and notify Rust.
   */
  document.addEventListener("turbo:load", () => {
    const title = document.title;
    DesktopRails.setTitle(title);

    if (INVOKE) {
      INVOKE("page_loaded", { url: window.location.href }).catch(() => {});
    }
  });

  /**
   * Handle Turbo frame navigation — these don't trigger turbo:before-visit
   * but we still want to track them.
   */
  document.addEventListener("turbo:frame-load", (event) => {
    // Frame loads don't change the main URL, but we log them
    console.debug("[desktop-rails] Frame loaded:", event.target.id);
  });

  /**
   * Handle form submissions that Turbo intercepts.
   */
  document.addEventListener("turbo:submit-start", () => {
    // Could show a native loading indicator here
    console.debug("[desktop-rails] Form submit started");
  });

  // ─── Bridge Component Base Class ───────────────────────────────────────────

  /**
   * BridgeComponent — the desktop equivalent of Strada's BridgeComponent.
   *
   * Extend this class in your Stimulus controllers to communicate with native features.
   *
   * Example:
   *   class NotificationBridge extends DesktopRails.BridgeComponent {
   *     static component = "notification"
   *     connect() {
   *       super.connect()
   *       this.send("connect", { title: "My App" })
   *     }
   *     onReceive(message) {
   *       if (message.event === "clicked") { ... }
   *     }
   *   }
   */
  class BridgeComponent {
    static component = "unknown";

    constructor(element) {
      this.element = element;
      this._boundReceive = this._handleReceive.bind(this);
    }

    connect() {
      // Listen for responses from the native shell
      this._unlisten = onBridgeResponse(this._boundReceive);
    }

    disconnect() {
      if (this._unlisten) {
        this._unlisten();
        this._unlisten = null;
      }
      // Notify native side that this component is going away
      this.send("disconnect", {});
    }

    /**
     * Send a message to the native shell.
     */
    async send(event, data = {}) {
      return DesktopRails.sendBridgeMessage(
        this.constructor.component,
        event,
        data
      );
    }

    /**
     * Override this to handle messages from the native shell.
     */
    onReceive(_message) {
      // Override in subclass
    }

    _handleReceive(event) {
      const response = event.payload;
      if (response && response.component === this.constructor.component) {
        this.onReceive(response);
      }
    }
  }

  DesktopRails.BridgeComponent = BridgeComponent;

  // ─── Stimulus Integration Helper ───────────────────────────────────────────

  /**
   * Helper to create a Stimulus-compatible bridge controller.
   * This creates a mixin that can be used with Stimulus controllers.
   *
   * Usage in a Stimulus controller:
   *   import { Controller } from "@hotwired/stimulus"
   *
   *   export default class extends DesktopRails.stimulusBridge(Controller, "notification") {
   *     connect() {
   *       super.connect()
   *       this.sendBridge("connect", { title: "Hello" })
   *     }
   *     receiveBridge(message) {
   *       console.log("Native says:", message)
   *     }
   *   }
   */
  DesktopRails.stimulusBridge = function (BaseController, componentName) {
    return class extends BaseController {
      connect() {
        super.connect();
        this._bridge = new BridgeComponent(this.element);
        this._bridge.constructor.component = componentName;
        this._bridge.onReceive = (msg) => this.receiveBridge(msg);
        this._bridge.connect();
      }

      disconnect() {
        super.disconnect();
        if (this._bridge) {
          this._bridge.disconnect();
        }
      }

      sendBridge(event, data = {}) {
        return this._bridge.send(event, data);
      }

      receiveBridge(_message) {
        // Override in subclass
      }
    };
  };

  // ─── Connection & Visit Errors ─────────────────────────────────────────────

  /**
   * Error names, matching Hotwire Native's TurboError / VisitError so the same
   * words mean the same thing on mobile and desktop.
   */
  DesktopRails.errors = {
    NETWORK_FAILURE: "network_failure",
    TIMEOUT_FAILURE: "timeout_failure",
    HTTP_FAILURE: "http_failure",
    PAGE_LOAD_FAILURE: "page_load_failure",
  };

  const OVERLAY_ID = "desktop-rails-offline-overlay";

  /**
   * Whether the shell presents failures itself.
   *
   * Opt out to present your own, the same way Hotwire Native lets you override
   * visitableDidFailRequest:
   *
   *   <meta name="desktop-rails-error-handling" content="manual">
   *
   * Then listen for the events below and render whatever you like.
   */
  function shellPresentsErrors() {
    const meta = document.querySelector('meta[name="desktop-rails-error-handling"]');
    return !meta || meta.content !== "manual";
  }

  /**
   * Announce a failed visit. Cancelable: preventDefault() suppresses the shell's
   * own banner for this one event, whatever the meta tag says.
   *
   * Listeners receive { error, status, retry }, where retry() attempts the visit
   * again — the desktop equivalent of Hotwire Native's retryHandler.
   */
  function reportVisitError(error, { status = null, retry = null } = {}) {
    const event = new CustomEvent("desktop-rails:visit-error", {
      detail: { error, status, retry: retry || (() => window.location.reload()) },
      cancelable: true,
    });

    const notPrevented = document.dispatchEvent(event);
    console.warn("[desktop-rails] Visit error:", error, status ?? "");

    if (notPrevented && shellPresentsErrors()) showOfflineBanner();
  }

  function reportConnection(online, error) {
    document.dispatchEvent(
      new CustomEvent("desktop-rails:connection", { detail: { online, error } })
    );

    if (online) {
      hideOfflineBanner();
    } else if (shellPresentsErrors()) {
      showOfflineBanner();
    }
  }

  function showOfflineBanner() {
    if (!document.body || document.getElementById(OVERLAY_ID)) return;

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.setAttribute("role", "status");
    overlay.style.cssText =
      "position:fixed;bottom:0;left:0;right:0;padding:12px 20px;background:#1a1a2e;" +
      "color:#e0e0e0;font-family:system-ui,sans-serif;font-size:14px;text-align:center;" +
      "z-index:99999;border-top:2px solid #e73c7e;";
    overlay.textContent = "Can't reach the server — retrying…";
    document.body.appendChild(overlay);
  }

  function hideOfflineBanner() {
    const overlay = document.getElementById(OVERLAY_ID);
    if (overlay) overlay.remove();
  }

  DesktopRails.reportVisitError = reportVisitError;

  /**
   * The shell watches the server and tells us when it goes away or comes back.
   *
   * The browser's own offline event only fires when this machine loses its
   * network, which is not the case that usually happens — the server going down
   * while the network is fine looks entirely healthy from in here.
   */
  /**
   * Entry point the shell calls into. Not part of the public API.
   *
   * The shell reaches the page this way rather than through Tauri's event API,
   * which would need the whole JS API exposed on window for any loaded page to
   * reach.
   */
  DesktopRails.__receive = function (kind, payload) {
    const detail = payload || {};

    switch (kind) {
      case "connection":
        reportConnection(Boolean(detail.online), detail.error || null);
        break;
      case "navigate":
        performNavigation(detail.action);
        break;
      case "focus":
        handleFocusReturn(detail);
        break;
      case "visit":
        performVisit(detail.url);
        break;
      case "file-open-pending":
        drainOpenedFiles();
        break;
      case "bridge-response":
        dispatchBridgeResponse(detail);
        break;
      default:
        console.debug("[desktop-rails] Ignoring unknown message:", kind);
    }
  };

  /**
   * Collect files the OS asked the app to open (double-click on an associated
   * type, "Open With…"), announced as a desktop-rails:file-open DOM event.
   *
   * Pull rather than push: launching by double-click queues the file in the
   * shell before any page exists, so the page asks — on its own startup, and
   * again whenever the shell pings a running page.
   */
  async function drainOpenedFiles() {
    try {
      const result = await DesktopRails.sendBridgeMessage(
        "file-open",
        "pending",
        {}
      );
      const paths = result && result.paths;
      if (Array.isArray(paths) && paths.length > 0) {
        document.dispatchEvent(
          new CustomEvent("desktop-rails:file-open", { detail: { paths } })
        );
      }
    } catch (_e) {
      // Not running inside the shell, or the bridge is not ready.
    }
  }

  drainOpenedFiles();

  /**
   * True when someone is part-way through entering something.
   *
   * A refresh would throw it away, which is a far worse outcome than showing
   * data a few seconds stale, so it is the one case the shell's proposal is
   * declined without being asked.
   */
  function isEditing() {
    const active = document.activeElement;
    if (!active) return false;

    const tag = active.tagName;
    return (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      active.isContentEditable === true
    );
  }

  /**
   * The window came back after being away.
   *
   * Announced as a cancelable event whether or not a refresh is proposed, so an
   * app can revalidate its own way — or veto the refresh, which is worth doing
   * if it knows about unsaved state the focus check cannot see.
   */
  function handleFocusReturn(detail) {
    const event = new CustomEvent("desktop-rails:focus", {
      detail: {
        awaySeconds: detail.awaySeconds || 0,
        refreshing: Boolean(detail.refreshing),
      },
      cancelable: true,
    });

    const notPrevented = document.dispatchEvent(event);
    if (!detail.refreshing || !notPrevented) return;

    if (isEditing()) {
      console.debug("[desktop-rails] Not refreshing on focus while editing");
      return;
    }

    performNavigation("refresh");
  }

  /**
   * Go to a URL the shell asked for — a deep link, usually.
   *
   * Through Turbo where it exists, so the visit behaves like any other and the
   * path configuration still decides how the page is presented.
   */
  function performVisit(url) {
    if (!url) return;

    if (window.Turbo && window.Turbo.visit) {
      window.Turbo.visit(url);
    } else {
      window.location.assign(url);
    }
  }

  /**
   * Act on what the shell asked the page underneath to do after a modal closed.
   */
  function performNavigation(action) {
    switch (action) {
      case "back":
        window.history.back();
        break;
      case "forward":
        window.history.forward();
        break;
      case "reload":
        window.location.reload();
        break;
      case "refresh":
        // Turbo's own refresh keeps scroll position and morphs where it can.
        if (window.Turbo && window.Turbo.visit) {
          window.Turbo.visit(window.location.href, { action: "replace" });
        } else {
          window.location.reload();
        }
        break;
      case "none":
        break;
      default:
        console.debug("[desktop-rails] Ignoring unknown navigation:", action);
    }
  }

  /**
   * Turbo reports its own failures. In a Turbo app most navigation is a fetch
   * rather than a document load, so this fires long before anything reaches the
   * webview's own error page.
   */
  document.addEventListener("turbo:fetch-request-error", (event) => {
    const url = event.detail && event.detail.url;
    reportVisitError(DesktopRails.errors.NETWORK_FAILURE, {
      retry: () => (url ? window.location.replace(url) : window.location.reload()),
    });
  });

  /** A visit that completed with an error status. */
  document.addEventListener("turbo:before-fetch-response", (event) => {
    const response = event.detail && event.detail.fetchResponse;
    if (!response || response.succeeded || response.statusCode < 500) return;

    reportVisitError(DesktopRails.errors.HTTP_FAILURE, { status: response.statusCode });
  });

  // This machine losing its network is a different thing, but it looks the same
  // to the person using the app.
  window.addEventListener("offline", () =>
    reportConnection(false, DesktopRails.errors.NETWORK_FAILURE)
  );
  window.addEventListener("online", () => reportConnection(true, null));

  // ─── Initial Setup ─────────────────────────────────────────────────────────

  // Sync title on initial load (before Turbo is initialized)
  if (document.readyState === "complete" || document.readyState === "interactive") {
    DesktopRails.setTitle(document.title);
  } else {
    document.addEventListener("DOMContentLoaded", () => {
      DesktopRails.setTitle(document.title);
    });
  }

  // Expose the API globally
  window.__DESKTOP_RAILS__ = DesktopRails;
  window.DesktopRails = DesktopRails;

  console.log(`[desktop-rails] v${DesktopRails.version} initialized`);

  // ─── Dev Inspector (lazy, dev-only) ──────────────────────────────────────
  function inspectorEnabled() {
    try {
      if (window.localStorage && window.localStorage.getItem("td:inspector") === "1") return true;
    } catch (_e) { /* storage may be blocked */ }
    if (document.querySelector('meta[name="desktop-rails-inspector"][content="enabled"]')) return true;
    if (window.__DESKTOP_RAILS_INSPECTOR_ENABLED__ === true) return true;
    return false;
  }
  DesktopRails._inspectorEnabled = inspectorEnabled;

  if (INVOKE && inspectorEnabled()) {
    // Resolve the inspector entry URL, in priority order:
    //   1. an explicit override global,
    //   2. the same-origin URL the Rails gem advertises on the meta tag
    //      (desktop_rails_inspector_meta_tag → data-inspector-url), served by
    //      the gem's engine so this import() is same-origin,
    //   3. a relative fallback for setups that serve ./inspector.js themselves.
    var inspectorMeta = document.querySelector('meta[name="desktop-rails-inspector"]');
    var inspectorUrl =
      window.__DESKTOP_RAILS_INSPECTOR_URL__ ||
      (inspectorMeta && inspectorMeta.dataset && inspectorMeta.dataset.inspectorUrl) ||
      "./inspector.js";
    import(inspectorUrl)
      .then(function (m) { m.startInspector(DesktopRails, { doc: document, win: window }); })
      .catch(function (e) { console.error("[desktop-rails] inspector failed to load", e); });
  }
})();
