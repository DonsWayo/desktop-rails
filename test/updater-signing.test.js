import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  createHash,
  createPublicKey,
  randomBytes,
  verify as edVerify,
} from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { blake2b } from "../desktop-rails/lib/desktop_rails/tooling/updater/blake2b.mjs";
import {
  decodePublicKey,
  decodeSecretKey,
  forManifest,
  fromManifest,
  generateKeyPair,
  scryptParams,
  signBytes,
  verifyBytes,
} from "../desktop-rails/lib/desktop_rails/tooling/updater/minisign.mjs";

const PACKAGE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CLI = join(PACKAGE_ROOT, "desktop-rails", "lib", "desktop_rails", "tooling", "updater", "updater-cli.mjs");

// Deriving a key costs ~100ms of scrypt, which is the point of scrypt. One
// keypair is shared by the tests that only need *a* key.
const PASSWORD = "correct horse battery staple";
let keys;
let workdir;

before(() => {
  keys = generateKeyPair({ password: PASSWORD });
  workdir = mkdtempSync(join(tmpdir(), "desktop-rails-signing-"));
});

after(() => {
  rmSync(workdir, { recursive: true, force: true });
});

const cli = (...args) =>
  execFileSync(process.execPath, [CLI, ...args], { encoding: "utf8" }).trim();

/**
 * Verify exactly the way tauri-plugin-updater does, written out here rather
 * than by calling the library under test.
 *
 * The plugin (2.10.0, src/updater.rs `verify_signature`) base64-decodes both
 * the configured pubkey and the manifest's signature into minisign text, then
 * hands them to minisign-verify, which reads the public key as 2 bytes of
 * algorithm + 8 of key id + 32 of key, and the signature as 4 lines: comment,
 * base64 of 74 bytes, "trusted comment: ...", base64 of a 64-byte global
 * signature. A test that reuses our own parser would pass even if that layout
 * were wrong, so this one re-reads the bytes and checks them with Node's own
 * Ed25519.
 */
function verifyAsTheUpdaterWould(pubkeyForConfig, signatureFromManifest, artifact) {
  const pubText = Buffer.from(pubkeyForConfig, "base64").toString("utf8");
  const sigText = Buffer.from(signatureFromManifest, "base64").toString("utf8");

  const pubBytes = Buffer.from(pubText.split("\n")[1], "base64");
  assert.equal(pubBytes.length, 42, "a minisign public key is 42 bytes");

  const sigLines = sigText.split("\n");
  const body = Buffer.from(sigLines[1], "base64");
  assert.equal(body.length, 74, "a minisign signature body is 74 bytes");
  assert.ok(
    sigLines[2].startsWith("trusted comment: "),
    "the third line must be the trusted comment",
  );

  const algorithm = body.subarray(0, 2).toString("latin1");
  assert.ok(["Ed", "ED"].includes(algorithm), `unexpected algorithm ${algorithm}`);

  assert.deepEqual(
    body.subarray(2, 10),
    pubBytes.subarray(2, 10),
    "the signature must name the same key id as the public key",
  );

  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      pubBytes.subarray(10),
    ]),
    format: "der",
    type: "spki",
  });

  const signature = body.subarray(10);
  const message =
    algorithm === "ED" ? createHash("blake2b512").update(artifact).digest() : artifact;

  const trustedComment = sigLines[2].slice("trusted comment: ".length);
  const globalSignature = Buffer.from(sigLines[3], "base64");

  return {
    artifactMatches: edVerify(null, message, key, signature),
    commentMatches: edVerify(
      null,
      Buffer.concat([signature, Buffer.from(trustedComment, "utf8")]),
      key,
      globalSignature,
    ),
    trustedComment,
  };
}

describe("BLAKE2b", () => {
  // The 32-byte digest is hand-rolled because Node only exposes the 64-byte
  // one, and it guards the secret key: get it wrong and every key written here
  // is rejected as having the wrong password by minisign and by this code on
  // the next run. Holding the 64-byte output against Node's native
  // implementation exercises the same compression function.
  test("matches Node's native blake2b512 across block boundaries", () => {
    for (const size of [0, 1, 63, 64, 127, 128, 129, 255, 1000]) {
      const data = randomBytes(size);
      assert.equal(
        blake2b(data, 64).toString("hex"),
        createHash("blake2b512").update(data).digest("hex"),
        `mismatch at ${size} bytes`,
      );
    }
  });

  test("produces the published BLAKE2b-256 vectors", () => {
    assert.equal(
      blake2b(Buffer.from("abc"), 32).toString("hex"),
      "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319",
    );
    assert.equal(
      blake2b(Buffer.alloc(0), 32).toString("hex"),
      "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8",
    );
  });
});

describe("minisign keys", () => {
  test("the secret key round-trips through its password", () => {
    const opened = decodeSecretKey(keys.secretKeyFile, PASSWORD);
    const published = decodePublicKey(keys.publicKeyFile);

    assert.equal(opened.keyId, keys.keyId);
    assert.deepEqual(opened.keynum, Buffer.from(published.keynum));
    assert.deepEqual(
      opened.publicKeyRaw,
      Buffer.from(published.publicKeyRaw),
      "the public key inside the secret key must be the one that was published",
    );
  });

  test("a wrong password is reported, not used to sign with garbage", () => {
    assert.throws(
      () => decodeSecretKey(keys.secretKeyFile, "not the password"),
      /Wrong password/,
    );
  });

  test("uses the scrypt parameters minisign's own defaults produce", () => {
    // Ported from rust-minisign's raw_scrypt_params. If this drifts, keys made
    // here stop opening in `minisign` and `tauri signer` and vice versa —
    // silently, as a wrong-password error.
    assert.deepEqual(scryptParams(33554432n, 1048576n), { N: 32768, r: 8, p: 1 });
  });

  test("the published key is the 42 bytes minisign-verify expects", () => {
    const bytes = Buffer.from(keys.publicKeyLine, "base64");
    assert.equal(bytes.length, 42);
    assert.equal(bytes.subarray(0, 2).toString("latin1"), "Ed");
  });
});

describe("signing an artifact", () => {
  test("a signature round-trips and the updater's own checks accept it", () => {
    const artifact = randomBytes(4096);
    const secretKey = decodeSecretKey(keys.secretKeyFile, PASSWORD);
    const signature = signBytes(secretKey, artifact, { fileName: "App.app.tar.gz" });

    const mine = verifyBytes(keys.publicKeyFile, artifact, signature);
    assert.equal(mine.ok, true, mine.reason);

    const theirs = verifyAsTheUpdaterWould(
      forManifest(keys.publicKeyFile),
      forManifest(signature),
      artifact,
    );
    assert.equal(theirs.artifactMatches, true);
    assert.equal(theirs.commentMatches, true);
    assert.match(theirs.trustedComment, /file:App\.app\.tar\.gz/);
  });

  test("a tampered artifact fails", () => {
    const artifact = randomBytes(4096);
    const secretKey = decodeSecretKey(keys.secretKeyFile, PASSWORD);
    const signature = signBytes(secretKey, artifact, {});

    const tampered = Buffer.from(artifact);
    tampered[2048] ^= 0x01; // one bit

    const mine = verifyBytes(keys.publicKeyFile, tampered, signature);
    assert.equal(mine.ok, false);
    assert.match(mine.reason, /does not match/);

    const theirs = verifyAsTheUpdaterWould(
      forManifest(keys.publicKeyFile),
      forManifest(signature),
      tampered,
    );
    assert.equal(theirs.artifactMatches, false, "one flipped bit must fail verification");
  });

  test("a truncated artifact fails", () => {
    const artifact = randomBytes(4096);
    const secretKey = decodeSecretKey(keys.secretKeyFile, PASSWORD);
    const signature = signBytes(secretKey, artifact, {});

    assert.equal(verifyBytes(keys.publicKeyFile, artifact.subarray(0, 4095), signature).ok, false);
  });

  test("a rewritten trusted comment fails", () => {
    // The trusted comment is what an app can show the user, so it gets its own
    // signature. Editing it without the key has to be detectable.
    const artifact = randomBytes(1024);
    const secretKey = decodeSecretKey(keys.secretKeyFile, PASSWORD);
    const signature = signBytes(secretKey, artifact, { trustedComment: "version:1.0.0" });

    const edited = signature.replace("trusted comment: version:1.0.0", "trusted comment: version:9.9.9");
    const result = verifyBytes(keys.publicKeyFile, artifact, edited);

    assert.equal(result.ok, false);
    assert.match(result.reason, /trusted comment/);
  });

  test("another key's signature fails, named as a key mismatch", () => {
    const artifact = randomBytes(1024);
    const attacker = generateKeyPair({ password: "" });
    const signature = signBytes(decodeSecretKey(attacker.secretKeyFile, ""), artifact, {});

    const result = verifyBytes(keys.publicKeyFile, artifact, signature);
    assert.equal(result.ok, false);
    assert.match(result.reason, /signed by key/);
  });
});

describe("the manifest tauri-plugin-updater fetches", () => {
  test("sign then manifest produces the documented shape", () => {
    const artifactPath = join(workdir, "Ledger.app.tar.gz");
    const manifestPath = join(workdir, "latest.json");
    const secretPath = join(workdir, "key.key");
    const publicPath = join(workdir, "key.pub");
    const artifact = randomBytes(2048);

    writeFileSync(artifactPath, artifact);
    cli("generate", "--secret", secretPath, "--public", publicPath, "--password", "");
    cli("sign", "--key", secretPath, "--artifact", artifactPath, "--password", "");

    cli(
      "manifest",
      "--manifest", manifestPath,
      "--version", "1.2.0",
      "--target", "darwin-aarch64",
      "--url", "https://example.com/1.2.0/Ledger.app.tar.gz",
      "--sig", `${artifactPath}.sig`,
      "--notes", "Fixed the thing",
      "--pub-date", "2026-09-15T10:00:00Z",
    );

    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

    assert.deepEqual(Object.keys(manifest).sort(), ["notes", "platforms", "pub_date", "version"]);
    assert.equal(manifest.version, "1.2.0");
    assert.equal(manifest.pub_date, "2026-09-15T10:00:00Z");
    assert.deepEqual(Object.keys(manifest.platforms["darwin-aarch64"]).sort(), [
      "signature",
      "url",
    ]);

    // The signature field is the .minisig text base64'd, not a URL and not the
    // raw bytes — the plugin base64-decodes it and parses minisign text.
    const decoded = fromManifest(manifest.platforms["darwin-aarch64"].signature);
    assert.ok(decoded.startsWith("untrusted comment: "));

    const checked = verifyAsTheUpdaterWould(
      cli("pubkey", "--public", publicPath),
      manifest.platforms["darwin-aarch64"].signature,
      artifact,
    );
    assert.equal(checked.artifactMatches, true);
    assert.equal(checked.commentMatches, true);
  });

  test("a second platform is added rather than replacing the first", () => {
    const manifestPath = join(workdir, "merged.json");
    const secretPath = join(workdir, "merge.key");
    const publicPath = join(workdir, "merge.pub");

    cli("generate", "--secret", secretPath, "--public", publicPath, "--password", "");

    for (const [target, name] of [
      ["darwin-aarch64", "mac.app.tar.gz"],
      ["linux-x86_64", "linux.AppImage.tar.gz"],
    ]) {
      const path = join(workdir, name);
      writeFileSync(path, randomBytes(512));
      cli("sign", "--key", secretPath, "--artifact", path, "--password", "");
      cli(
        "manifest",
        "--manifest", manifestPath,
        "--version", "2.0.0",
        "--target", target,
        "--url", `https://example.com/${name}`,
        "--sig", `${path}.sig`,
      );
    }

    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    assert.deepEqual(Object.keys(manifest.platforms).sort(), ["darwin-aarch64", "linux-x86_64"]);
    assert.notEqual(
      manifest.platforms["darwin-aarch64"].signature,
      manifest.platforms["linux-x86_64"].signature,
    );
  });

  test("mixing versions into one manifest is refused", () => {
    const manifestPath = join(workdir, "mixed.json");
    const artifactPath = join(workdir, "mixed.tar.gz");
    const secretPath = join(workdir, "mixed.key");
    const publicPath = join(workdir, "mixed.pub");

    writeFileSync(artifactPath, randomBytes(256));
    cli("generate", "--secret", secretPath, "--public", publicPath, "--password", "");
    cli("sign", "--key", secretPath, "--artifact", artifactPath, "--password", "");

    const add = (version, target) =>
      cli(
        "manifest",
        "--manifest", manifestPath,
        "--version", version,
        "--target", target,
        "--url", "https://example.com/x",
        "--sig", `${artifactPath}.sig`,
      );

    add("3.0.0", "darwin-aarch64");
    assert.throws(() => add("3.0.1", "linux-x86_64"), /refusing to add/);
  });
});

describe("the shell reads its updater settings from the app config", () => {
  const read = (...parts) => readFileSync(join(PACKAGE_ROOT, ...parts), "utf-8");

  // One generic shell binary serves every app in this fork, so anything baked
  // into tauri.conf.json at compile time cannot be app-specific. These two
  // tests exist because putting a key there would appear to work — right up to
  // the point where a second app is built from the same binary.
  test("tauri.conf.json carries no app-specific updater settings", () => {
    const updater = JSON.parse(read("src-tauri", "tauri.conf.json")).plugins.updater;

    assert.equal(updater.pubkey, "", "the signing key belongs to the app, not the shell");
    assert.deepEqual(updater.endpoints, [], "endpoints belong to the app, not the shell");
  });

  test("the bridge builds its updater from desktop-rails.config.json", () => {
    const source = read("src-tauri", "src", "updater_bridge.rs");

    assert.match(source, /DesktopRailsConfig/, "the updater must read the app's own config");
    assert.match(source, /\.pubkey\(/, "the public key must be applied at runtime");
    assert.match(source, /\.endpoints\(/, "the endpoints must be applied at runtime");
  });

  test("an app with no updater block is not an error", () => {
    const source = read("src-tauri", "src", "window.rs");

    assert.match(
      source,
      /pub struct UpdaterConfig/,
      "desktop-rails.config.json needs an updater section",
    );
    assert.match(
      source,
      /pub updater: UpdaterConfig/,
      "the updater section must hang off the app config",
    );
    assert.match(
      source,
      /#\[serde\(default\)\]\s*\n\s*pub updater: UpdaterConfig/,
      "the updater section must be optional — most apps do not self-update",
    );
  });
});
