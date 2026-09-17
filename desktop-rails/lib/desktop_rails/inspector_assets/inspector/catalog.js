/**
 * Static catalog of built-in bridge components.
 * Single source of truth for the Inspector's "Available" list and snippets.
 * Each entry: { description, erb, stimulus }.
 */
export const CATALOG = {
  "notification": {
    description: "Show native OS notifications; a click focuses the window.",
    erb: `<button data-controller="notification"\n        data-action="click->notification#notify"\n        data-body="Saved!">Notify</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  notify(e) { DesktopRails.notifications.show({ title: "My App", body: e.target.dataset.body, id: "saved" }) }\n}`,
  },
  "menu-item": {
    description: "Add an item to the native menu bar that triggers a page action.",
    erb: `<div data-controller="menu-item"\n     data-action="desktop-rails:menu-item@document->menu-item#clicked"></div>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  connect() { DesktopRails.menu.add({ id: "export", title: "Export PDF", accelerator: "CmdOrCtrl+Shift+E" }) }\n  clicked(e) { if (e.detail.id === "export") console.log("export") }\n}`,
  },
  "file-picker": {
    description: "Open a native file open/save dialog.",
    erb: `<button data-controller="file-picker"\n        data-action="click->file-picker#open">Choose file…</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "file-picker") {\n  open() { this.sendBridge("open", { multiple: false }) }\n  receiveBridge(msg) { console.log("picked", msg.data) }\n}`,
  },
  "badge": {
    description: "Set the Dock / launcher badge count (no-op on Windows).",
    erb: `<span data-controller="badge" data-badge-count-value="3"></span>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  static values = { count: Number }\n  connect() { DesktopRails.badge.set(this.countValue) }\n}`,
  },
  "shortcut": {
    description: "Register a global keyboard shortcut.",
    erb: `<div data-controller="shortcut" data-shortcut-keys-value="CmdOrCtrl+Shift+K"\n     data-action="desktop-rails:shortcut@document->shortcut#fired"></div>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  static values = { keys: String }\n  connect() { DesktopRails.shortcuts.register("palette", this.keysValue, { focus: true }) }\n  fired(e) { if (e.detail.id === "palette") { /* fired when the shortcut is pressed */ } }\n}`,
  },
  "shell": {
    description: "Spawn and manage native shell processes.",
    erb: `<button data-controller="shell" data-action="click->shell#run">Run</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "shell") {\n  run() { DesktopRails.shell.spawn("job-1", "echo", ["hello"]) }\n}`,
  },
  "filesystem": {
    description: "Read and write files through the native filesystem bridge.",
    erb: `<button data-controller="fs" data-action="click->fs#read">Read file</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "filesystem") {\n  read() { this.sendBridge("read", { path: "~/notes.txt" }) }\n  receiveBridge(msg) { console.log(msg.data) }\n}`,
  },
  "sudo": {
    description: "Run a privileged command via the native elevation prompt.",
    erb: `<button data-controller="sudo" data-action="click->sudo#elevate">Install</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "sudo") {\n  elevate() { this.sendBridge("execute", { command: "brew install foo" }) }\n}`,
  },
  "tray": {
    description: "Add items to the system tray / menu-bar icon.",
    erb: `<div data-controller="tray" data-tray-title-value="My App"></div>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "tray") {\n  static values = { title: String }\n  connect() { super.connect(); this.sendBridge("set", { tooltip: this.titleValue }) }\n}`,
  },
  "deep-link": {
    description: "Handle custom-scheme deep links opened from outside the app.",
    erb: `<div data-controller="deep-link"></div>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "deep-link") {\n  receiveBridge(msg) { Turbo.visit(msg.data.path) }\n}`,
  },
  "updater": {
    description: "Check for and apply native app updates.",
    erb: `<button data-controller="updater" data-action="click->updater#check">Check for updates</button>`,
    stimulus: `import { Controller } from "@hotwired/stimulus"\nexport default class extends DesktopRails.stimulusBridge(Controller, "updater") {\n  check() { this.sendBridge("check", {}) }\n  receiveBridge(msg) { console.log("update status", msg.data) }\n}`,
  },
};

for (const entry of Object.values(CATALOG)) Object.freeze(entry);
Object.freeze(CATALOG);

/** Names of every catalogued component. */
export function listComponents() {
  return Object.keys(CATALOG);
}

/** Look up one component's metadata, or null if unknown. */
export function getComponent(name) {
  return Object.prototype.hasOwnProperty.call(CATALOG, name) ? CATALOG[name] : null;
}
