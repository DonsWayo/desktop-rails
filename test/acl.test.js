import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const read = (...parts) => readFileSync(join(PACKAGE_ROOT, ...parts), "utf-8");

/** Commands registered with Tauri in main.rs, without their module paths. */
function registeredCommands() {
  const main = read("src-tauri", "src", "main.rs");
  const block = main.match(/generate_handler!\[([\s\S]*?)\]/);

  assert.ok(block, "main.rs should register commands with generate_handler!");

  return block[1]
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => entry.split("::").pop());
}

/**
 * Every command the web layer can call needs a permission, or Tauri refuses it
 * from remote content with "not allowed. Plugin not found" — which is silent
 * unless you happen to be watching the webview console. These two tests exist
 * because the whole bridge was dead that way and nothing caught it.
 */
test("every registered command is declared for the ACL in build.rs", () => {
  const buildScript = read("src-tauri", "build.rs");
  const declared = buildScript.match(/const APP_COMMANDS[^=]*=\s*&\[([\s\S]*?)\]/);

  assert.ok(declared, "build.rs should declare APP_COMMANDS");

  for (const command of registeredCommands()) {
    assert.ok(
      declared[1].includes(`"${command}"`),
      `${command} is registered but missing from APP_COMMANDS, so no permission is generated for it`
    );
  }
});

test("every registered command is granted in the main capability", () => {
  const capability = JSON.parse(read("src-tauri", "capabilities", "main.json"));

  for (const command of registeredCommands()) {
    const permission = `allow-${command.replace(/_/g, "-")}`;

    assert.ok(
      capability.permissions.includes(permission),
      `${command} is registered but ${permission} is not granted, so remote pages cannot call it`
    );
  }
});

test("the capability grants no permission for a command that does not exist", () => {
  const capability = JSON.parse(read("src-tauri", "capabilities", "main.json"));
  const commands = registeredCommands().map((c) => `allow-${c.replace(/_/g, "-")}`);

  // App permissions have no plugin prefix; core: and plugin permissions do.
  const appPermissions = capability.permissions.filter(
    (permission) => !permission.includes(":")
  );

  for (const permission of appPermissions) {
    assert.ok(
      commands.includes(permission),
      `${permission} is granted but no such command is registered`
    );
  }
});

/** The permissions src/security.rs grants the app's own origin at runtime. */
function runtimeOriginPermissions() {
  const security = read("src-tauri", "src", "security.rs");
  const block = security.match(/const APP_ORIGIN_PERMISSIONS[^=]*=\s*&\[([\s\S]*?)\]/);

  assert.ok(block, "security.rs should declare APP_ORIGIN_PERMISSIONS");

  return [...block[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

/**
 * The app's pages are remote, so they reach the shell only through what
 * admit_origin grants their origin once the config is read. A command left out
 * of that list works on the bundled error page and fails silently in every app.
 */
test("every registered command is granted to the app origin at runtime", () => {
  const granted = runtimeOriginPermissions();

  for (const command of registeredCommands()) {
    const permission = `allow-${command.replace(/_/g, "-")}`;
    assert.ok(
      granted.includes(permission),
      `${command} is registered but ${permission} is not granted to the app origin`
    );
  }
});

/**
 * The app origin is only known at runtime. A remote URL pattern in the static
 * capability can only be a guess wider than that origin: it used to be every
 * https site and every loopback port, which let any of them call plugin
 * commands, and left the bridge's origin check to the page the webview shows
 * rather than the frame that sent the request.
 */
test("the static capability admits no remote page", () => {
  const capability = JSON.parse(read("src-tauri", "capabilities", "main.json"));

  assert.strictEqual(
    capability.remote,
    undefined,
    "main.json must not list remote URLs; admit_origin grants the app origin at runtime"
  );
});

test("the app origin is granted app commands and no plugin permission", () => {
  for (const permission of runtimeOriginPermissions()) {
    assert.ok(
      !permission.includes(":"),
      `${permission} is a plugin or core permission; remote pages reach native features through the bridge and its policy`
    );
  }
});
