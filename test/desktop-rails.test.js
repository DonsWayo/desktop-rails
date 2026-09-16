import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const scriptSource = readFileSync(
  resolve(__dirname, "../src/desktop-rails.js"),
  "utf-8"
);
const { version: packageVersion } = JSON.parse(
  readFileSync(resolve(__dirname, "../package.json"), "utf-8")
);

/**
 * Create a fresh JSDOM window and execute the desktop-rails script in it.
 * When invoke is provided, it records all calls in an array for inspection.
 * Returns { window, calls } where calls is the array of { cmd, args } objects.
 */
function createEnvironment({ invoke = undefined, readyState = "complete" } = {}) {
  const dom = new JSDOM(
    `<!DOCTYPE html><html><head><title>Test Page</title></head><body></body></html>`,
    {
      url: "https://myapp.test/",
      runScripts: "dangerously",
      pretendToBeVisual: true,
    }
  );

  const { window } = dom;

  if (readyState !== "complete") {
    Object.defineProperty(window.document, "readyState", {
      get: () => readyState,
      configurable: true,
    });
  }

  const calls = [];

  if (invoke) {
    window.__TAURI_INTERNALS__ = {
      invoke: async (cmd, args) => {
        calls.push({ cmd, args });
        return invoke(cmd, args);
      },
    };
  }

  window.eval(scriptSource);

  return { dom, window, calls };
}

/** Wait a microtask tick so the async initial setTitle settles. */
const tick = () => new Promise((r) => setTimeout(r, 5));

/**
 * deepEqual that works across JSDOM/Node realms.
 * Objects from window.eval have a different Object prototype, so
 * assert.deepStrictEqual fails even with identical structures.
 * Round-trip through JSON to normalize.
 */
function assertDeepEqual(actual, expected, message) {
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(actual)),
    JSON.parse(JSON.stringify(expected)),
    message
  );
}

// ─── Initialization ───────────────────────────────────────────────────────

describe("DesktopRails initialization", () => {
  it("exposes DesktopRails on window", () => {
    const { window } = createEnvironment();
    assert.ok(window.DesktopRails);
    assert.ok(window.__DESKTOP_RAILS__);
    assert.strictEqual(window.DesktopRails, window.__DESKTOP_RAILS__);
  });

  it("sets version, platform, and isNative", () => {
    const { window } = createEnvironment();
    assert.strictEqual(window.DesktopRails.version, packageVersion);
    assert.strictEqual(window.DesktopRails.platform, "macos");
    assert.strictEqual(window.DesktopRails.isNative, true);
  });

  it("guards against double injection", () => {
    const dom = new JSDOM(
      `<!DOCTYPE html><html><head><title>Test</title></head><body></body></html>`,
      { url: "https://myapp.test/", runScripts: "dangerously", pretendToBeVisual: true }
    );
    const { window } = dom;

    window.eval(scriptSource);
    window.DesktopRails._marker = "first";

    // Second injection should be a no-op
    window.eval(scriptSource);
    assert.strictEqual(window.DesktopRails._marker, "first");
  });

  it("exposes BridgeComponent class", () => {
    const { window } = createEnvironment();
    assert.ok(window.DesktopRails.BridgeComponent);
    assert.strictEqual(typeof window.DesktopRails.BridgeComponent, "function");
  });

  it("exposes stimulusBridge function", () => {
    const { window } = createEnvironment();
    assert.strictEqual(typeof window.DesktopRails.stimulusBridge, "function");
  });
});

// ─── proposeVisit ─────────────────────────────────────────────────────────

describe("DesktopRails.proposeVisit", () => {
  it("returns default fallback when no INVOKE available", async () => {
    const { window } = createEnvironment();
    const result = await window.DesktopRails.proposeVisit("https://myapp.test/page");
    assertDeepEqual(result, { action: "advance", presentation: "default" });
  });

  it("returns default fallback with custom action when no INVOKE", async () => {
    const { window } = createEnvironment();
    const result = await window.DesktopRails.proposeVisit("https://myapp.test/page", "replace");
    assertDeepEqual(result, { action: "replace", presentation: "default" });
  });

  it("calls invoke with correct arguments", async () => {
    const mockInvoke = async () => ({ action: "advance", presentation: "modal" });
    const { window, calls } = createEnvironment({ invoke: mockInvoke });

    // Wait for the initial setTitle call from script init
    await tick();

    await window.DesktopRails.proposeVisit("https://myapp.test/new", "advance");

    const visitCall = calls.find((c) => c.cmd === "handle_visit_proposal");
    assert.ok(visitCall, "Expected a handle_visit_proposal call");
    assert.strictEqual(visitCall.args.proposal.url, "https://myapp.test/new");
    assert.strictEqual(visitCall.args.proposal.path, "/new");
    assert.strictEqual(visitCall.args.proposal.action, "advance");
  });

  it("resolves relative URLs against window.location.origin", async () => {
    const mockInvoke = async () => ({ action: "advance", presentation: "default" });
    const { window, calls } = createEnvironment({ invoke: mockInvoke });
    await tick();

    await window.DesktopRails.proposeVisit("/relative/path");

    const visitCall = calls.find((c) => c.cmd === "handle_visit_proposal");
    assert.ok(visitCall);
    assert.strictEqual(visitCall.args.proposal.url, "https://myapp.test/relative/path");
    assert.strictEqual(visitCall.args.proposal.path, "/relative/path");
  });

  it("returns fallback on invoke error", async () => {
    const mockInvoke = async (cmd) => {
      if (cmd === "handle_visit_proposal") throw new Error("Rust panicked");
      // Let other calls succeed silently
    };
    const { window } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const result = await window.DesktopRails.proposeVisit("https://myapp.test/page");
    assertDeepEqual(result, { action: "advance", presentation: "default" });
  });
});

// ─── setTitle ─────────────────────────────────────────────────────────────

describe("DesktopRails.setTitle", () => {
  it("does nothing when no INVOKE available", async () => {
    const { window } = createEnvironment();
    await window.DesktopRails.setTitle("New Title");
    // No error thrown means pass
  });

  it("calls invoke with title", async () => {
    const mockInvoke = async () => {};
    const { window, calls } = createEnvironment({ invoke: mockInvoke });

    // Wait for the init setTitle("Test Page") to settle
    await tick();

    await window.DesktopRails.setTitle("My App - Dashboard");

    const titleCalls = calls.filter((c) => c.cmd === "update_window_title");
    // First call is from init ("Test Page"), second is our explicit call
    const lastCall = titleCalls[titleCalls.length - 1];
    assert.strictEqual(lastCall.args.title, "My App - Dashboard");
  });

  it("handles invoke error gracefully", async () => {
    const mockInvoke = async () => {
      throw new Error("fail");
    };
    const { window } = createEnvironment({ invoke: mockInvoke });
    await tick();

    // Should not throw
    await window.DesktopRails.setTitle("Title");
  });
});

// ─── Notifications, badge, shortcuts and menu items ──────────────────────
//
// Each of these used to answer "ok" from a stub. The page-side contract is
// what the shell now implements: the payload each call sends, a refusal that
// rejects rather than resolving to null, and what fires when the shell
// reports a click or a key press.

describe("native features on the page", () => {
  /** An invoke that answers like the shell, refusing what the shell refuses. */
  function shellLike(refusals = {}) {
    return async (cmd, args) => {
      if (cmd !== "handle_bridge_message") return null;
      const { component, event, data } = args.message;
      const refusal = refusals[`${component}/${event}`];
      if (refusal) throw refusal;
      if (component === "notification" && event === "permission") {
        return { status: "ok", permission: "granted" };
      }
      return { status: "ok", component, event, data };
    };
  }

  const sentMessage = (calls, component, event) => {
    const call = calls.find(
      (c) => c.cmd === "handle_bridge_message" &&
             c.args.message.component === component &&
             c.args.message.event === event
    );
    return call && JSON.parse(JSON.stringify(call.args.message.data));
  };

  const deliver = (window, component, event, data) =>
    window.DesktopRails.__receive("bridge-response", { component, event, data });

  it("shows a notification with its title, body and id", async () => {
    const { window, calls } = createEnvironment({ invoke: shellLike() });
    await window.DesktopRails.notifications.show({ title: "Export finished", body: "invoice.pdf", id: "export" });
    assert.deepStrictEqual(sentMessage(calls, "notification", "show"), {
      title: "Export finished", body: "invoice.pdf", id: "export",
    });
  });

  it("notify() is shorthand for the same message", async () => {
    const { window, calls } = createEnvironment({ invoke: shellLike() });
    await window.DesktopRails.notify("Done", "3 files", { id: "sync" });
    assert.deepStrictEqual(sentMessage(calls, "notification", "show"), {
      title: "Done", body: "3 files", id: "sync",
    });
  });

  it("rejects with the shell's reason when there is no notification service", async () => {
    const { window } = createEnvironment({
      invoke: shellLike({ "notification/show": "The notification service refused or is not running" }),
    });
    await assert.rejects(
      window.DesktopRails.notifications.show({ title: "Done" }),
      /not running/
    );
  });

  it("reports the permission the shell reads", async () => {
    const { window } = createEnvironment({ invoke: shellLike() });
    assert.strictEqual(await window.DesktopRails.notifications.permission(), "granted");
    assert.strictEqual(await window.DesktopRails.notifications.requestPermission(), "granted");
  });

  it("hands a notification click to onClick and to a DOM event", () => {
    const { window } = createEnvironment();
    const clicked = [];
    let domDetail = null;
    window.DesktopRails.notifications.onClick((data) => clicked.push(data.id));
    window.document.addEventListener("desktop-rails:notification-click", (e) => { domDetail = e.detail; });

    deliver(window, "notification", "click", { id: "export" });

    assert.deepStrictEqual(clicked, ["export"]);
    assert.strictEqual(domDetail.id, "export");
  });

  it("sets, labels and clears the badge", async () => {
    const { window, calls } = createEnvironment({ invoke: shellLike() });
    await window.DesktopRails.badge.set(7);
    assert.deepStrictEqual(sentMessage(calls, "badge", "set"), { count: 7 });
    await window.DesktopRails.badge.clear();
    assert.deepStrictEqual(sentMessage(calls, "badge", "clear"), {});

    const labelled = createEnvironment({ invoke: shellLike() });
    await labelled.window.DesktopRails.badge.setLabel("new");
    assert.deepStrictEqual(sentMessage(labelled.calls, "badge", "set"), { label: "new" });
  });

  it("registers a shortcut with its id, accelerator and focus option", async () => {
    const { window, calls } = createEnvironment({ invoke: shellLike() });
    await window.DesktopRails.shortcuts.register("palette", "CmdOrCtrl+Shift+K", { focus: true });
    assert.deepStrictEqual(sentMessage(calls, "shortcut", "register"), {
      id: "palette", accelerator: "CmdOrCtrl+Shift+K", focus: true,
    });

    await window.DesktopRails.shortcuts.unregister("palette");
    assert.deepStrictEqual(sentMessage(calls, "shortcut", "unregister"), { id: "palette" });
    await window.DesktopRails.shortcuts.unregisterAll();
    assert.ok(sentMessage(calls, "shortcut", "unregister-all"));
  });

  it("rejects a shortcut another application holds instead of resolving to null", async () => {
    const { window } = createEnvironment({
      invoke: shellLike({
        "shortcut/register": "Could not register Ctrl+Alt+K: another application or the system already uses it",
      }),
    });
    await assert.rejects(
      window.DesktopRails.shortcuts.register("palette", "Ctrl+Alt+K"),
      (error) => error instanceof window.Error && /another application/.test(error.message)
    );
  });

  it("fires only the callbacks for the shortcut that was pressed", () => {
    const { window } = createEnvironment();
    const fired = [];
    const stop = window.DesktopRails.shortcuts.on("palette", (data) => fired.push(data.accelerator));
    window.DesktopRails.shortcuts.on("search", () => fired.push("wrong one"));
    const dom = [];
    window.document.addEventListener("desktop-rails:shortcut", (e) => dom.push(e.detail.id));

    deliver(window, "shortcut", "triggered", { id: "palette", accelerator: "Ctrl+Alt+J" });
    assert.deepStrictEqual(fired, ["Ctrl+Alt+J"]);
    assert.deepStrictEqual(dom, ["palette"]);

    stop();
    deliver(window, "shortcut", "triggered", { id: "palette", accelerator: "Ctrl+Alt+J" });
    assert.deepStrictEqual(fired, ["Ctrl+Alt+J"], "unsubscribing stops delivery");
  });

  it("announces the config's summon shortcut", () => {
    const { window } = createEnvironment();
    let summoned = null;
    let viaCallback = null;
    window.document.addEventListener("desktop-rails:summon", (e) => { summoned = e.detail; });
    window.DesktopRails.shortcuts.onSummon((data) => { viaCallback = data; });

    deliver(window, "shortcut", "summon", { accelerator: "CmdOrCtrl+Shift+Space" });

    assert.strictEqual(summoned.accelerator, "CmdOrCtrl+Shift+Space");
    assert.strictEqual(viaCallback.accelerator, "CmdOrCtrl+Shift+Space");
  });

  it("adds and removes a menu item, and hears its clicks", async () => {
    const { window, calls } = createEnvironment({ invoke: shellLike() });
    await window.DesktopRails.menu.add({ id: "export", title: "Export PDF", accelerator: "CmdOrCtrl+Shift+E" });
    assert.deepStrictEqual(sentMessage(calls, "menu-item", "register"), {
      id: "export", title: "Export PDF", accelerator: "CmdOrCtrl+Shift+E", menu: null,
    });

    const clicks = [];
    window.DesktopRails.menu.onClick("export", (data) => clicks.push(data.id));
    let dom = null;
    window.document.addEventListener("desktop-rails:menu-item", (e) => { dom = e.detail; });
    deliver(window, "menu-item", "click", { id: "export" });
    deliver(window, "menu-item", "click", { id: "print" });
    assert.deepStrictEqual(clicks, ["export"]);
    assert.strictEqual(dom.id, "print", "the DOM event carries every item's clicks");

    await window.DesktopRails.menu.remove("export");
    assert.deepStrictEqual(sentMessage(calls, "menu-item", "unregister"), { id: "export" });
  });

  it("is a quiet no-op outside the shell", async () => {
    const { window } = createEnvironment();
    assert.strictEqual(await window.DesktopRails.notifications.show({ title: "x" }), null);
    assert.strictEqual(await window.DesktopRails.shortcuts.register("a", "Ctrl+Alt+A"), null);
    assert.strictEqual(await window.DesktopRails.notifications.permission(), "unavailable");
  });
});

// ─── Window API ───────────────────────────────────────────────────────────

describe("DesktopRails.window", () => {
  const bridgeInvoke = async (cmd) => (cmd === "handle_bridge_message" ? { status: "ok" } : null);

  const sent = (calls, event) =>
    calls.find(
      (c) => c.cmd === "handle_bridge_message" &&
             c.args.message.component === "window" &&
             c.args.message.event === event
    );

  it("sends a resize with the requested size", async () => {
    const { window, calls } = createEnvironment({ invoke: bridgeInvoke });
    await tick();

    await window.DesktopRails.window.resize(1200, 900);

    const call = sent(calls, "resize");
    assert.ok(call, "no window/resize message was sent");
    assertDeepEqual(call.args.message.data, { width: 1200, height: 900 });
  });

  it("defaults the toggling actions to enabling them", async () => {
    const { window, calls } = createEnvironment({ invoke: bridgeInvoke });
    await tick();

    await window.DesktopRails.window.fullscreen();
    await window.DesktopRails.window.alwaysOnTop();

    assertDeepEqual(sent(calls, "fullscreen").args.message.data, { enabled: true });
    assertDeepEqual(sent(calls, "always-on-top").args.message.data, { enabled: true });
  });

  it("passes false through rather than treating it as absent", async () => {
    const { window, calls } = createEnvironment({ invoke: bridgeInvoke });
    await tick();

    await window.DesktopRails.window.fullscreen(false);

    assertDeepEqual(sent(calls, "fullscreen").args.message.data, { enabled: false });
  });

  it("sends the parameterless actions with an empty payload", async () => {
    const { window, calls } = createEnvironment({ invoke: bridgeInvoke });
    await tick();

    for (const action of ["minimize", "maximize", "unmaximize", "center", "focus", "state"]) {
      await window.DesktopRails.window[action]();
      assert.ok(sent(calls, action), `no window/${action} message was sent`);
    }
  });
});

// ─── sendBridgeMessage ────────────────────────────────────────────────────

describe("DesktopRails.sendBridgeMessage", () => {
  it("returns null when no INVOKE available", async () => {
    const { window } = createEnvironment();
    const result = await window.DesktopRails.sendBridgeMessage("menu", "click", { id: 1 });
    assert.strictEqual(result, null);
  });

  it("calls invoke with correct message structure", async () => {
    const mockInvoke = async (cmd) => {
      if (cmd === "handle_bridge_message") return { ok: true };
    };
    const { window, calls } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const result = await window.DesktopRails.sendBridgeMessage("notification", "show", { title: "Hello" });

    // The script also sends its own startup messages (e.g. draining files the
    // OS asked the app to open), so look for this call rather than the first.
    const bridgeCall = calls.find(
      (c) => c.cmd === "handle_bridge_message" && c.args.message.component === "notification"
    );
    assert.ok(bridgeCall);
    assertDeepEqual(bridgeCall.args.message, {
      component: "notification",
      event: "show",
      data: { title: "Hello" },
    });
    assertDeepEqual(result, { ok: true });
  });

  it("returns null on error", async () => {
    const mockInvoke = async (cmd) => {
      if (cmd === "handle_bridge_message") throw new Error("fail");
    };
    const { window } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const result = await window.DesktopRails.sendBridgeMessage("menu", "click");
    assert.strictEqual(result, null);
  });
});

// ─── getWindowInfo ────────────────────────────────────────────────────────

describe("DesktopRails.getWindowInfo", () => {
  it("returns null when no INVOKE", async () => {
    const { window } = createEnvironment();
    const result = await window.DesktopRails.getWindowInfo();
    assert.strictEqual(result, null);
  });

  it("calls invoke and returns result", async () => {
    const mockInvoke = async (cmd) => {
      if (cmd === "get_window_info") return { label: "main", title: "App" };
    };
    const { window } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const info = await window.DesktopRails.getWindowInfo();
    assertDeepEqual(info, { label: "main", title: "App" });
  });
});

// ─── closeModal ───────────────────────────────────────────────────────────

describe("DesktopRails.closeModal", () => {
  it("does nothing when no INVOKE", async () => {
    const { window } = createEnvironment();
    await window.DesktopRails.closeModal("modal-1");
  });

  it("calls invoke with label", async () => {
    const mockInvoke = async () => {};
    const { window, calls } = createEnvironment({ invoke: mockInvoke });
    await tick();

    await window.DesktopRails.closeModal("modal-1");

    const modalCall = calls.find((c) => c.cmd === "close_modal");
    assert.ok(modalCall);
    assert.strictEqual(modalCall.args.label, "modal-1");
  });
});

// ─── BridgeComponent ─────────────────────────────────────────────────────

describe("BridgeComponent", () => {
  it("has default component name 'unknown'", () => {
    const { window } = createEnvironment();
    const BC = window.DesktopRails.BridgeComponent;
    assert.strictEqual(BC.component, "unknown");
  });

  it("stores element reference", () => {
    const { window } = createEnvironment();
    const BC = window.DesktopRails.BridgeComponent;
    const el = window.document.createElement("div");
    const instance = new BC(el);
    assert.strictEqual(instance.element, el);
  });

  it("send() delegates to DesktopRails.sendBridgeMessage", async () => {
    const mockInvoke = async (cmd) => {
      if (cmd === "handle_bridge_message") return { handled: true };
    };
    const { window, calls } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const BC = window.DesktopRails.BridgeComponent;

    // Create a subclass inside the JSDOM context so it shares the same class identity
    const TestComponent = window.eval(`
      (function(BC) {
        class TestComponent extends BC {
          static component = "test-widget";
        }
        return TestComponent;
      })
    `)(BC);

    const el = window.document.createElement("div");
    const instance = new TestComponent(el);
    const result = await instance.send("activate", { color: "red" });

    const bridgeCall = calls.find(
      (c) => c.cmd === "handle_bridge_message" && c.args.message.component === "test-widget"
    );
    assert.ok(bridgeCall);
    assert.strictEqual(bridgeCall.args.message.component, "test-widget");
    assert.strictEqual(bridgeCall.args.message.event, "activate");
    assertDeepEqual(bridgeCall.args.message.data, { color: "red" });
    assertDeepEqual(result, { handled: true });
  });

  it("disconnect() sends a disconnect message", async () => {
    const mockInvoke = async () => {};
    const { window, calls } = createEnvironment({ invoke: mockInvoke });
    await tick();

    const BC = window.DesktopRails.BridgeComponent;

    const MyComponent = window.eval(`
      (function(BC) {
        class MyComponent extends BC {
          static component = "my-comp";
        }
        return MyComponent;
      })
    `)(BC);

    const el = window.document.createElement("div");
    const instance = new MyComponent(el);
    await instance.disconnect();

    const disconnectCall = calls.find(
      (c) => c.cmd === "handle_bridge_message" && c.args.message.event === "disconnect"
    );
    assert.ok(disconnectCall);
    assert.strictEqual(disconnectCall.args.message.component, "my-comp");
  });

  it("_handleReceive filters by component name", () => {
    const { window } = createEnvironment();
    const BC = window.DesktopRails.BridgeComponent;

    const WidgetA = window.eval(`
      (function(BC) {
        class WidgetA extends BC {
          static component = "widget-a";
        }
        return WidgetA;
      })
    `)(BC);

    const el = window.document.createElement("div");
    const instance = new WidgetA(el);

    let received = null;
    instance.onReceive = (msg) => {
      received = msg;
    };

    // Matching component
    instance._handleReceive({ payload: { component: "widget-a", event: "update", data: {} } });
    assert.ok(received);
    assert.strictEqual(received.component, "widget-a");

    // Non-matching component — should not call onReceive
    received = null;
    instance._handleReceive({ payload: { component: "widget-b", event: "update", data: {} } });
    assert.strictEqual(received, null);
  });
});

// ─── Bridge response delivery ────────────────────────────────────────────

describe("bridge-response delivery", () => {
  // Tauri's event API is not exposed to remote pages, so responses arrive
  // through __receive and fan out to the registered listeners.
  it("reaches shell.onOutput through __receive", () => {
    const { window } = createEnvironment();
    const td = window.DesktopRails;
    const seen = [];

    td.shell.onOutput("job-1", (message) => seen.push(message));
    td.__receive("bridge-response", {
      component: "shell",
      event: "stdout",
      data: { id: "job-1", line: "hi" },
    });

    assert.strictEqual(seen.length, 1);
    assert.strictEqual(seen[0].event, "stdout");
    assert.strictEqual(seen[0].line, "hi");

    // Another job's output does not leak in.
    td.__receive("bridge-response", {
      component: "shell",
      event: "stdout",
      data: { id: "job-2", line: "not mine" },
    });
    assert.strictEqual(seen.length, 1);

    // And unsubscribing stops delivery.
    td.shell.offOutput("job-1");
    td.__receive("bridge-response", {
      component: "shell",
      event: "stdout",
      data: { id: "job-1", line: "after off" },
    });
    assert.strictEqual(seen.length, 1);
  });

  it("mirrors drag-drop responses as DOM events", () => {
    const { window } = createEnvironment();
    let detail = null;
    window.document.addEventListener("desktop-rails:drop", (e) => {
      detail = e.detail;
    });

    window.DesktopRails.__receive("bridge-response", {
      component: "drag-drop",
      event: "drop",
      data: { paths: ["/tmp/a.csv"], position: { x: 1, y: 2 } },
    });

    assert.ok(detail, "the DOM event should have fired");
    assert.deepStrictEqual(detail.paths, ["/tmp/a.csv"]);
  });
});

// ─── stimulusBridge ──────────────────────────────────────────────────────

describe("stimulusBridge", () => {
  it("creates a subclass with bridge methods", () => {
    const { window } = createEnvironment();

    class FakeController {
      constructor() {
        this.element = window.document.createElement("div");
      }
      connect() {}
      disconnect() {}
    }

    const BridgedController = window.DesktopRails.stimulusBridge(FakeController, "toolbar");
    const instance = new BridgedController();

    assert.strictEqual(typeof instance.sendBridge, "function");
    assert.strictEqual(typeof instance.receiveBridge, "function");
    assert.ok(instance instanceof FakeController);
  });

  it("connect creates internal bridge component", () => {
    const { window } = createEnvironment();

    class FakeController {
      constructor() {
        this.element = window.document.createElement("div");
      }
      connect() {}
      disconnect() {}
    }

    const BridgedController = window.DesktopRails.stimulusBridge(FakeController, "toolbar");
    const instance = new BridgedController();
    instance.connect();

    assert.ok(instance._bridge);
    assert.strictEqual(instance._bridge.constructor.component, "toolbar");
    assert.strictEqual(instance._bridge.element, instance.element);
  });
});

// ─── Title sync on initial load ──────────────────────────────────────────

describe("Title sync on initial load", () => {
  it("syncs title when document is already complete", async () => {
    const mockInvoke = async () => {};
    const { calls } = createEnvironment({ invoke: mockInvoke, readyState: "complete" });

    await tick();

    const titleCall = calls.find((c) => c.cmd === "update_window_title");
    assert.ok(titleCall, "Expected an update_window_title call on init");
    assert.strictEqual(titleCall.args.title, "Test Page");
  });

  it("does not sync title synchronously when document is loading", async () => {
    const mockInvoke = async () => {};
    const { calls } = createEnvironment({ invoke: mockInvoke, readyState: "loading" });

    // No title call should have happened yet (DOMContentLoaded hasn't fired)
    const titleCall = calls.find((c) => c.cmd === "update_window_title");
    assert.strictEqual(titleCall, undefined);
  });
});

describe("Connection and visit errors", () => {
  const BANNER = "#desktop-rails-offline-overlay";

  it("exposes the same error names as Hotwire Native", () => {
    const { window } = createEnvironment();

    assertDeepEqual(window.DesktopRails.errors, {
      NETWORK_FAILURE: "network_failure",
      TIMEOUT_FAILURE: "timeout_failure",
      HTTP_FAILURE: "http_failure",
      PAGE_LOAD_FAILURE: "page_load_failure",
    });
  });

  it("shows a banner when a Turbo fetch fails", () => {
    const { window } = createEnvironment();

    window.document.dispatchEvent(
      new window.CustomEvent("turbo:fetch-request-error", { detail: {} })
    );

    assert.ok(window.document.querySelector(BANNER), "expected the shell's banner");
  });

  it("announces failures as a cancelable event carrying a retry handler", () => {
    const { window } = createEnvironment();
    const seen = [];

    window.document.addEventListener("desktop-rails:visit-error", (event) => {
      seen.push(event.detail);
    });

    window.document.dispatchEvent(
      new window.CustomEvent("turbo:fetch-request-error", { detail: {} })
    );

    assert.strictEqual(seen.length, 1);
    assert.strictEqual(seen[0].error, "network_failure");
    assert.strictEqual(typeof seen[0].retry, "function");
  });

  it("lets a listener suppress the shell's banner with preventDefault", () => {
    const { window } = createEnvironment();

    window.document.addEventListener("desktop-rails:visit-error", (event) =>
      event.preventDefault()
    );
    window.document.dispatchEvent(
      new window.CustomEvent("turbo:fetch-request-error", { detail: {} })
    );

    assert.strictEqual(
      window.document.querySelector(BANNER),
      null,
      "the app took over presentation, so the shell should stay out of the way"
    );
  });

  it("stays out of the way entirely when error handling is set to manual", () => {
    const { window } = createEnvironment();
    const meta = window.document.createElement("meta");
    meta.name = "desktop-rails-error-handling";
    meta.content = "manual";
    window.document.head.appendChild(meta);

    window.document.dispatchEvent(
      new window.CustomEvent("turbo:fetch-request-error", { detail: {} })
    );

    assert.strictEqual(window.document.querySelector(BANNER), null);
  });

  it("reports server errors with their status code", () => {
    const { window } = createEnvironment();
    const seen = [];

    window.document.addEventListener("desktop-rails:visit-error", (event) =>
      seen.push(event.detail)
    );

    window.document.dispatchEvent(
      new window.CustomEvent("turbo:before-fetch-response", {
        detail: { fetchResponse: { succeeded: false, statusCode: 503 } },
      })
    );

    assert.strictEqual(seen.length, 1);
    assert.strictEqual(seen[0].error, "http_failure");
    assert.strictEqual(seen[0].status, 503);
  });

  it("ignores responses the app is expected to handle itself", () => {
    const { window } = createEnvironment();
    const seen = [];

    window.document.addEventListener("desktop-rails:visit-error", (event) =>
      seen.push(event.detail)
    );

    // A 404 or a failed form validation is the app's own page to render.
    for (const statusCode of [404, 422]) {
      window.document.dispatchEvent(
        new window.CustomEvent("turbo:before-fetch-response", {
          detail: { fetchResponse: { succeeded: false, statusCode } },
        })
      );
    }

    assert.deepStrictEqual(seen, []);
  });

  it("clears the banner when the machine comes back online", () => {
    const { window } = createEnvironment();

    window.dispatchEvent(new window.Event("offline"));
    assert.ok(window.document.querySelector(BANNER));

    window.dispatchEvent(new window.Event("online"));
    assert.strictEqual(window.document.querySelector(BANNER), null);
  });
});

describe("Modal dismissal", () => {
  it("knows the window it is in", () => {
    const { window } = createEnvironment();
    window.__DESKTOP_RAILS_WINDOW_LABEL__ = "modal-abc123";

    assert.strictEqual(window.DesktopRails.windowLabel, "modal-abc123");
    assert.strictEqual(window.DesktopRails.isModal, true);
  });

  it("does not think the main window is a modal", () => {
    const { window } = createEnvironment();
    window.__DESKTOP_RAILS_WINDOW_LABEL__ = "main";

    assert.strictEqual(window.DesktopRails.isModal, false);
  });

  it("closes the window it is in when given no label", async () => {
    const { window, calls } = createEnvironment({ invoke: async () => {} });
    window.__DESKTOP_RAILS_WINDOW_LABEL__ = "modal-abc123";
    await tick();

    await window.DesktopRails.closeModal();

    const call = calls.find((c) => c.cmd === "close_modal");
    assert.ok(call, "expected a close_modal call");
    assert.strictEqual(call.args.label, "modal-abc123");
  });

  it("uses Hotwire Native's dismissal names", async () => {
    for (const [method, then] of [
      ["recede", "recede"],
      ["refresh", "refresh"],
      ["resume", "resume"],
    ]) {
      const { window, calls } = createEnvironment({ invoke: async () => {} });
      await tick();

      await window.DesktopRails[method]();

      const call = calls.find((c) => c.cmd === "dismiss_modal");
      assert.ok(call, `expected ${method}() to dismiss`);
      assert.strictEqual(call.args.then, then);
    }
  });
});

describe("Messages from the shell", () => {
  it("refreshes the page when told to", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    window.DesktopRails.__receive("navigate", { action: "refresh" });

    assert.strictEqual(visits.length, 1);
    assert.strictEqual(visits[0].opts.action, "replace");
  });

  it("leaves the page alone when told to resume", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    window.DesktopRails.__receive("navigate", { action: "none" });

    assert.deepStrictEqual(visits, []);
  });

  it("shows the banner when the shell reports a lost connection", () => {
    const { window } = createEnvironment();

    window.DesktopRails.__receive("connection", {
      online: false,
      error: "network_failure",
    });

    assert.ok(window.document.querySelector("#desktop-rails-offline-overlay"));
  });

  it("clears the banner when the shell reports reconnection", () => {
    const { window } = createEnvironment();

    window.DesktopRails.__receive("connection", { online: false });
    window.DesktopRails.__receive("connection", { online: true });

    assert.strictEqual(
      window.document.querySelector("#desktop-rails-offline-overlay"),
      null
    );
  });

  it("ignores messages it does not understand", () => {
    const { window } = createEnvironment();

    // Must not throw — the shell may be newer than the injected script.
    window.DesktopRails.__receive("something-new", { a: 1 });
  });
});

describe("Returning to the window", () => {
  function focusReturn(window, detail) {
    window.DesktopRails.__receive("focus", detail);
  }

  it("refreshes when the shell says the absence was long enough", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    focusReturn(window, { awaySeconds: 120, refreshing: true });

    assert.strictEqual(visits.length, 1);
    assert.strictEqual(visits[0].opts.action, "replace");
  });

  it("does nothing when the absence was short", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    focusReturn(window, { awaySeconds: 3, refreshing: false });

    assert.deepStrictEqual(visits, []);
  });

  it("announces the return either way", () => {
    const { window } = createEnvironment();
    const seen = [];
    window.document.addEventListener("desktop-rails:focus", (e) => seen.push(e.detail));

    focusReturn(window, { awaySeconds: 3, refreshing: false });
    focusReturn(window, { awaySeconds: 300, refreshing: true });

    assert.strictEqual(seen.length, 2);
    assert.strictEqual(seen[0].awaySeconds, 3);
    assert.strictEqual(seen[1].refreshing, true);
  });

  it("lets the app veto the refresh", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };
    window.document.addEventListener("desktop-rails:focus", (e) => e.preventDefault());

    focusReturn(window, { awaySeconds: 300, refreshing: true });

    assert.deepStrictEqual(visits, [], "the app knows about state we cannot see");
  });

  it("does not throw away what someone is typing", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    const input = window.document.createElement("input");
    window.document.body.appendChild(input);
    input.focus();

    focusReturn(window, { awaySeconds: 3600, refreshing: true });

    assert.deepStrictEqual(visits, [], "a half-filled form outranks stale data");
  });

  it("refreshes once the field is no longer focused", () => {
    const { window } = createEnvironment();
    const visits = [];
    window.Turbo = { visit: (url, opts) => visits.push({ url, opts }) };

    const input = window.document.createElement("input");
    window.document.body.appendChild(input);
    input.focus();
    input.blur();

    focusReturn(window, { awaySeconds: 3600, refreshing: true });

    assert.strictEqual(visits.length, 1);
  });
});
