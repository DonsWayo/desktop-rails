#!/usr/bin/env node
// The bytes-and-JSON half of packaging/generate-key.sh and
// packaging/sign-update.sh. The shell scripts do the argument checking and the
// talking; everything below only runs once its inputs are known good.
//
// Subcommands:
//   generate --secret <path> --public <path> [--password <pw>] [--comment <c>]
//   sign     --key <path> --artifact <path> [--password <pw>] [--sig <path>]
//            [--comment <trusted comment>]
//   manifest --manifest <path> --version <v> --target <t> --url <u> --sig <path>
//            [--notes <text>] [--notes-file <path>] [--pub-date <rfc3339>]
//   verify   --public <path> --artifact <path> --sig <path>
//   pubkey   --public <path>          # the value for desktop-rails.config.json
//
// Passwords arrive as arguments from the shell scripts, which read them from
// the environment rather than the command line so they stay out of `ps`.

import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

import {
  decodePublicKey,
  decodeSecretKey,
  forManifest,
  generateKeyPair,
  signBytes,
  verifyBytes,
} from "./minisign.mjs";

// Every option here takes a value, so the token after a flag is always that
// value — never inspected to see whether it "looks like" another flag. A
// password beginning with "--" is a perfectly good password, and guessing would
// turn it into a confusing "unexpected argument" instead of a signature.
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const token = argv[i];
    if (!token.startsWith("--")) throw new Error(`Unexpected argument: ${token}`);
    if (i + 1 >= argv.length) throw new Error(`${token} needs a value`);
    args[token.slice(2)] = argv[i + 1];
  }
  return args;
}

const required = (args, name) => {
  const value = args[name];
  if (typeof value !== "string" || value === "") throw new Error(`--${name} is required`);
  return value;
};

function generate(args) {
  const secretPath = required(args, "secret");
  const publicPath = required(args, "public");
  const keys = generateKeyPair({
    password: typeof args.password === "string" ? args.password : "",
    ...(typeof args.comment === "string" ? { comment: args.comment } : {}),
  });

  // 0600 before anything is written, not after: a key that exists world-readable
  // for even a moment has to be treated as leaked.
  writeFileSync(secretPath, keys.secretKeyFile, { mode: 0o600 });
  writeFileSync(publicPath, keys.publicKeyFile, { mode: 0o644 });

  process.stdout.write(`${keys.keyId}\n`);
  process.stdout.write(`${forManifest(keys.publicKeyFile)}\n`);
}

function sign(args) {
  const keyPath = required(args, "key");
  const artifactPath = required(args, "artifact");
  const sigPath = typeof args.sig === "string" ? args.sig : `${artifactPath}.sig`;

  const secretKey = decodeSecretKey(
    readFileSync(keyPath, "utf8"),
    typeof args.password === "string" ? args.password : "",
  );

  const artifact = readFileSync(artifactPath);
  const signature = signBytes(secretKey, artifact, {
    fileName: basename(artifactPath),
    ...(typeof args.comment === "string" ? { trustedComment: args.comment } : {}),
  });

  // What lands in the `.sig` file is base64 of the minisign text, because that
  // is literally what goes into the manifest's `signature` field — the plugin
  // base64-decodes it before parsing. Keeping the file in that form means the
  // manifest step is a copy rather than a re-encode.
  writeFileSync(sigPath, `${forManifest(signature)}\n`);

  process.stdout.write(`${sigPath}\n`);
}

function readManifest(path) {
  try {
    const existing = JSON.parse(readFileSync(path, "utf8"));
    if (existing && typeof existing === "object") return existing;
  } catch {
    // No manifest yet, or one that is not readable JSON — start a fresh one.
  }
  return {};
}

function manifest(args) {
  const path = required(args, "manifest");
  const version = required(args, "version");
  const target = required(args, "target");
  const url = required(args, "url");
  const sigPath = required(args, "sig");

  const signature = readFileSync(sigPath, "utf8").trim();

  // Merged rather than rewritten, so building each platform on its own runner
  // and appending as each finishes produces one manifest covering all of them.
  const existing = readManifest(path);
  const platforms =
    existing.platforms && typeof existing.platforms === "object" ? existing.platforms : {};

  // The version applies to the whole release: a manifest carrying platforms
  // from two different versions would hand some users the wrong build.
  if (existing.version && existing.version !== version) {
    throw new Error(
      `${path} is for version ${existing.version}; refusing to add ${version} to it. ` +
        "Start a new manifest for a new release.",
    );
  }

  const notes =
    typeof args["notes-file"] === "string"
      ? readFileSync(args["notes-file"], "utf8").trim()
      : typeof args.notes === "string"
        ? args.notes
        : existing.notes;

  const merged = {
    version,
    ...(notes ? { notes } : {}),
    pub_date:
      typeof args["pub-date"] === "string"
        ? args["pub-date"]
        : (existing.pub_date ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z")),
    platforms: { ...platforms, [target]: { signature, url } },
  };

  writeFileSync(path, `${JSON.stringify(merged, null, 2)}\n`);
  process.stdout.write(`${Object.keys(merged.platforms).sort().join(" ")}\n`);
}

function verify(args) {
  const publicKeyFile = readFileSync(required(args, "public"), "utf8");
  const artifact = readFileSync(required(args, "artifact"));

  // Accepts either form of the `.sig` file: the base64 this tool writes, or a
  // raw `.minisig` from minisign itself.
  const raw = readFileSync(required(args, "sig"), "utf8").trim();
  const signature = raw.startsWith("untrusted comment:")
    ? raw
    : Buffer.from(raw, "base64").toString("utf8");

  const result = verifyBytes(publicKeyFile, artifact, signature);
  if (!result.ok) {
    process.stderr.write(`signature does not verify: ${result.reason}\n`);
    process.exit(1);
  }

  process.stdout.write(`${result.trustedComment}\n`);
}

function pubkey(args) {
  const publicKeyFile = readFileSync(required(args, "public"), "utf8");
  decodePublicKey(publicKeyFile); // reject a file that is not a public key
  process.stdout.write(`${forManifest(publicKeyFile)}\n`);
}

const COMMANDS = { generate, sign, manifest, verify, pubkey };

const [command, ...rest] = process.argv.slice(2);
const run = COMMANDS[command];

if (!run) {
  process.stderr.write(`usage: updater-cli.mjs <${Object.keys(COMMANDS).join("|")}> [options]\n`);
  process.exit(2);
}

try {
  run(parseArgs(rest));
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
