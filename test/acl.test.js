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

/**
 * A packaged app's server binds 127.0.0.1 on a port the OS picks, and the
 * window loads exactly that origin. The capability only listed localhost, so
 * Tauri refused every bridge call from every packaged app before it reached
 * the shell's own origin check: invoke existed and every call failed. Found by
 * launching examples/notes in CI and asking the shell for its window state.
 */
test("the capability admits the origin every packager configures", () => {
  const capability = JSON.parse(read("src-tauri", "capabilities", "main.json"));

  for (const packer of ["pack.sh", "pack-linux.sh", "pack-windows.ps1"]) {
    const source = read("packaging", packer);
    const configured = source.match(/server_url["\s=:]+"?(http:\/\/[^:"]+):0"?/);

    assert.ok(configured, `${packer} should configure a loopback server_url with port 0`);
    assert.ok(
      capability.remote.urls.includes(`${configured[1]}:*`),
      `${packer} points the window at ${configured[1]}, which the capability does not admit`
    );
  }
});
