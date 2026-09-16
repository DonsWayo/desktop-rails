import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  bundleIdentifier,
  desktopPackage,
  urlScheme,
  defaultBuildTarget,
  defaultUserAgent,
  extractIconFlag,
  gemfileLine,
  gemVersion,
  guessAppName,
  packageVersion,
  run,
} from "../cli/desktop-rails.js";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (...parts) => readFileSync(join(PACKAGE_ROOT, ...parts), "utf-8");

test("extractIconFlag returns the args untouched when --icon is absent", () => {
  const { iconPath, rest } = extractIconFlag(["myapp"]);

  assert.equal(iconPath, null);
  assert.deepEqual(rest, ["myapp"]);
});

test("extractIconFlag pulls the flag out and resolves the path", () => {
  const { iconPath, rest } = extractIconFlag(["myapp", "--icon", "./logo.png"]);

  assert.equal(iconPath, resolve("./logo.png"));
  assert.deepEqual(rest, ["myapp"]);
});

test("extractIconFlag keeps positional args either side of the flag", () => {
  const { iconPath, rest } = extractIconFlag(["--icon", "logo.png", "myapp"]);

  assert.equal(iconPath, resolve("logo.png"));
  assert.deepEqual(rest, ["myapp"]);
});

test("guessAppName turns a directory name into a title", () => {
  assert.equal(guessAppName("/tmp/my_cool-app"), "My Cool App");
});

test("defaultBuildTarget matches the host platform", () => {
  const target = defaultBuildTarget();

  assert.match(target, /^(aarch64|x86_64)-/);
  if (process.platform === "darwin") assert.ok(target.endsWith("-apple-darwin"));
  if (process.platform === "linux") assert.ok(target.endsWith("-unknown-linux-gnu"));
  if (process.platform === "win32") assert.ok(target.endsWith("-pc-windows-msvc"));
});

test("defaultUserAgent reports the running version and platform", () => {
  const ua = defaultUserAgent();

  assert.ok(
    ua.startsWith(`Desktop Rails/${packageVersion()}`),
    `user agent should carry the package version, got: ${ua}`
  );
  assert.doesNotMatch(ua, /undefined/);

  if (process.platform === "darwin") assert.match(ua, /\(macOS; /);
  if (process.platform === "linux") assert.match(ua, /\(Linux; /);
});

test("run passes arguments through without a shell", () => {
  // A semicolon inside an argument has to stay part of that argument. If the
  // command went through a shell this would run `echo hi` and then `whoami`.
  const result = run("node", ["-e", "process.stdout.write(process.argv[1])", "hi; whoami"], {
    stdio: "pipe",
  });

  assert.equal(result.stdout.toString(), "hi; whoami");
});

test("run surfaces a non-zero exit as an error", () => {
  assert.throws(
    () => run("node", ["-e", "process.exit(3)"], { stdio: "pipe" }),
    /exited with status 3/
  );
});

test("the injected bridge reports the same version as package.json", () => {
  const source = readFileSync(join(PACKAGE_ROOT, "src", "desktop-rails.js"), "utf-8");
  const match = source.match(/version:\s*"([^"]+)"/);

  assert.ok(match, "src/desktop-rails.js should declare a version");
  assert.equal(
    match[1],
    packageVersion(),
    "src/desktop-rails.js version drifted from package.json"
  );
});

test("the Rust crate reports the same version as package.json", () => {
  const cargo = readFileSync(join(PACKAGE_ROOT, "src-tauri", "Cargo.toml"), "utf-8");
  const match = cargo.match(/^version\s*=\s*"([^"]+)"/m);

  assert.ok(match, "Cargo.toml should declare a version");
  assert.equal(match[1], packageVersion(), "Cargo.toml version drifted from package.json");
});

test("the Ruby gem reports the same version as package.json", () => {
  const version = readFileSync(
    join(PACKAGE_ROOT, "desktop-rails", "lib", "desktop_rails", "version.rb"),
    "utf-8"
  );
  const match = version.match(/VERSION\s*=\s*"([^"]+)"/);

  assert.ok(match, "version.rb should declare a VERSION");
  // RubyGems and SemVer spell a prerelease differently: gem 0.3.0.pre1 is npm
  // 0.3.0-pre.1. This is DesktopRails::Packaging.semver — RubyGems' own
  // segments, the first three as the core and the rest as the prerelease —
  // and the release workflow refuses to publish when the two disagree.
  const [major, minor = 0, patch = 0, ...pre] = match[1].match(/\d+|[a-z]+/gi);
  const semver = [major, minor, patch].map(Number).join(".") + (pre.length ? `-${pre.join(".")}` : "");
  assert.equal(semver, packageVersion(), "the gem version drifted from package.json");
});

test("the scaffold copies every Rust module main.rs declares", () => {
  const cli = readFileSync(join(PACKAGE_ROOT, "cli", "desktop-rails.js"), "utf-8");
  const main = readFileSync(join(PACKAGE_ROOT, "src-tauri", "src", "main.rs"), "utf-8");

  const declared = [...main.matchAll(/^mod\s+(\w+);/gm)].map((m) => `${m[1]}.rs`);
  const copied = cli.match(/const rustFiles = \[([\s\S]*?)\]/)[1];

  assert.ok(declared.length > 0, "main.rs should declare modules");
  for (const file of declared) {
    assert.ok(
      copied.includes(`"${file}"`),
      `cli scaffold is missing ${file}; the generated project would not compile`
    );
  }
});

test("each app gets its own URL scheme", () => {
  assert.equal(urlScheme("Task Manager"), "task-manager");
  assert.equal(urlScheme("rbenv Manager"), "rbenv-manager");
  assert.equal(urlScheme("My  App!!"), "my-app");
});

test("a scheme always starts with a letter", () => {
  // Schemes may not begin with a digit, and a name can.
  assert.match(urlScheme("1Password Clone"), /^[a-z]/);
  assert.equal(urlScheme("1Password Clone"), "app-1password-clone");
});

test("each app gets its own bundle identifier", () => {
  assert.equal(bundleIdentifier("Task Manager"), "com.task-manager.app");
  assert.notEqual(
    bundleIdentifier("Task Manager"),
    bundleIdentifier("Invoice Tracker"),
    "two apps sharing an identifier would share their stored preferences"
  );
});

test("the shell's own config does not leak its identity into scaffolds", () => {
  const conf = JSON.parse(read("src-tauri", "tauri.conf.json"));
  const cli = read("cli", "desktop-rails.js");

  // The scaffold must rewrite these rather than copying them.
  for (const key of ["productName", "identifier"]) {
    assert.ok(
      cli.includes(`tauriConf.${key} =`),
      `the scaffold should set ${key} rather than inherit "${conf[key]}"`
    );
  }
  assert.ok(cli.includes('tauriConf.plugins["deep-link"]'));
});

test("a scaffolded project gets its own package identity", () => {
  const shell = JSON.parse(read("package.json"));
  const scaffold = desktopPackage("Task Manager");

  assert.equal(scaffold.name, "task-manager-desktop");
  assert.notEqual(scaffold.name, shell.name, "every app would be called desktop-rails");
  assert.ok(!scaffold.bin, "a scaffold has no cli/ directory for a bin to point at");
  assert.equal(scaffold.private, true);
});

// The package is not on npm, so a semver range names something `npm install`
// cannot find. The release tag of this version is what exists.
test("a scaffolded project depends on the shell released with this CLI", () => {
  const scaffold = desktopPackage("Task Manager");

  assert.equal(
    scaffold.dependencies["desktop-rails"],
    `github:DonsWayo/desktop-rails#v${gemVersion()}`
  );
  assert.ok(scaffold.devDependencies["@tauri-apps/cli"], "desktop-rails dev shells out to tauri");
});

test("gemVersion spells this version the way the gem and its release tag do", () => {
  const version = read("desktop-rails", "lib", "desktop_rails", "version.rb").match(/VERSION\s*=\s*"([^"]+)"/)[1];

  assert.equal(gemVersion(), version);
  assert.equal(gemVersion("0.3.0-pre.2"), "0.3.0.pre2");
  assert.equal(gemVersion("1.0.0"), "1.0.0");
});

// The gem is not on RubyGems either; the "~> 0.1" `new` used to write resolved
// to nothing.
test("new adds the gem from GitHub at this version's tag", () => {
  assert.equal(
    gemfileLine("0.3.0-pre.2"),
    'gem "desktop-rails", github: "DonsWayo/desktop-rails", tag: "v0.3.0.pre2"'
  );
});

test("help describes what the CLI is for now, not upstream's tagline", () => {
  const result = spawnSync(process.execPath, [join(PACKAGE_ROOT, "cli", "desktop-rails.js"), "help"], {
    encoding: "utf-8",
  });

  assert.equal(result.status, 0);
  assert.doesNotMatch(result.stdout, /Turbo Native/);
  assert.match(result.stdout, /bin\/rails desktop:package/, "should point bundled apps at the gem");
  assert.match(result.stdout, /not published to npm/);
});

test("the published package carries everything the scaffold copies", () => {
  const { files } = JSON.parse(read("package.json"));

  // The CLI copies these out of the installed package at scaffold time.
  for (const needed of ["cli", "src", "src-tauri/src", "src-tauri/capabilities"]) {
    assert.ok(files.includes(needed), `files must include ${needed}`);
  }
  assert.ok(
    files.some((f) => f.startsWith("src-tauri/Cargo.toml")),
    "the scaffolded project needs a Cargo.toml"
  );
});

test("missing prerequisites stop before anything is created", () => {
  // An empty PATH makes every prerequisite unavailable.
  const result = spawnSync(
    process.execPath,
    [join(PACKAGE_ROOT, "cli", "desktop-rails.js"), "new", "scratch-app"],
    { cwd: mkdtempSync(join(tmpdir(), "desktop-rails-preflight-")), env: { PATH: "" }, encoding: "utf-8" }
  );

  assert.equal(result.status, 1, "a missing prerequisite should be a clean exit, not a crash");
  assert.match(result.stderr, /Rails is not installed/);
  assert.doesNotMatch(
    result.stderr,
    /at \w+ \(node:/,
    "a stack trace buries the thing the reader needs to see"
  );
});
