// Minisign keys and signatures, in the exact shape tauri-plugin-updater reads.
//
// Why this exists rather than shelling out to `minisign` or `tauri signer`:
// neither is installed on a machine that can already build this project, and
// `cargo install tauri-cli` is a long build to get one subcommand. Node has
// Ed25519 and BLAKE2b-512 natively, and the minisign container format is a few
// hundred bytes of framing, so the whole thing fits here with no dependency.
//
// The formats below were read out of the code that has to accept them, not
// from memory:
//
//   * tauri-plugin-updater 2.10.0 src/updater.rs — `verify_signature` does
//     `base64_to_string(pubkey)` then `PublicKey::decode`, and the same for the
//     signature. So the manifest's `signature` and the configured `pubkey` are
//     base64 of the *whole text file*, not of the raw key bytes.
//   * minisign-verify 0.2.5 src/lib.rs — the byte layout of both, and the fact
//     that the plugin calls `verify(.., allow_legacy = true)`.
//   * rust-minisign 0.7.9 (the crate behind `tauri signer`) — the secret key
//     box, its scrypt parameters and its checksum, so a key made here can be
//     used by `minisign`/`tauri signer` later and vice versa.
//
// Signatures are written pre-hashed ("ED"), which is minisign's modern default
// and what `tauri signer sign` emits.

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  randomBytes,
  scryptSync,
  sign as edSign,
  timingSafeEqual,
  verify as edVerify,
} from "node:crypto";

import { blake2b } from "./blake2b.mjs";

const SIGALG = Buffer.from("Ed", "latin1"); // Ed25519 over the raw message
const SIGALG_PREHASHED = Buffer.from("ED", "latin1"); // Ed25519 over BLAKE2b-512
const KDF_ALG = Buffer.from("Sc", "latin1"); // scrypt
const CHK_ALG = Buffer.from("B2", "latin1"); // BLAKE2b

const KEYNUM_BYTES = 8;
const PUBLICKEY_BYTES = 32;
const SECRETKEY_BYTES = 64; // seed || public key
const CHK_BYTES = 32;
const KDF_SALTBYTES = 32;
const SIGNATURE_BYTES = 64;

// rust-minisign's defaults; carried in the file so a key made elsewhere with
// other limits still loads.
const DEFAULT_OPSLIMIT = 1048576n;
const DEFAULT_MEMLIMIT = 33554432n;
const N_LOG2_MAX = 20;

const COMMENT_PREFIX = "untrusted comment: ";
const TRUSTED_COMMENT_PREFIX = "trusted comment: ";
const DEFAULT_SIGNATURE_COMMENT = "signature from turbo-desktop secret key";
const DEFAULT_SECRET_KEY_COMMENT = "turbo-desktop encrypted secret key";

// Ed25519 keys reach Node's crypto as DER. Both wrappers are fixed-length and
// fixed-shape for this curve, so the raw 32 bytes can simply be appended.
const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

const privateKeyFromSeed = (seed) =>
  createPrivateKey({
    key: Buffer.concat([PKCS8_ED25519_PREFIX, Buffer.from(seed)]),
    format: "der",
    type: "pkcs8",
  });

const publicKeyFromRaw = (raw) =>
  createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(raw)]),
    format: "der",
    type: "spki",
  });

const rawPublicKeyOf = (privateKey) =>
  createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-PUBLICKEY_BYTES);

const u64le = (value) => {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64LE(BigInt(value));
  return buf;
};

/** The 16 hex digits minisign shows as a key's identity. */
export function keyIdHex(keynum) {
  return Buffer.from(keynum).readBigUInt64LE(0).toString(16).toUpperCase().padStart(16, "0");
}

/**
 * scrypt parameters from minisign's opslimit/memlimit, ported from
 * rust-minisign's `raw_scrypt_params` so the same password derives the same
 * key stream here and there.
 */
export function scryptParams(memlimit, opslimit) {
  const ops = opslimit < 32768n ? 32768n : opslimit;
  const mem = BigInt(memlimit);
  const r = 8;
  let nLog2 = 1;
  let p;

  if (ops < mem / 32n) {
    p = 1;
    const maxn = ops / (BigInt(r) * 4n);
    while (nLog2 < 63 && !(1n << BigInt(nLog2) > maxn / 2n)) nLog2 += 1;
  } else {
    const maxn = mem / (BigInt(r) * 128n);
    while (nLog2 < 63 && !(1n << BigInt(nLog2) > maxn / 2n)) nLog2 += 1;
    const rp = (ops / 4n) / (1n << BigInt(nLog2));
    const maxrp = rp < 0x3fffffffn ? rp : 0x3fffffffn;
    p = Number(maxrp / BigInt(r));
  }

  if (nLog2 > N_LOG2_MAX) throw new Error("scrypt parameters too high");

  return { N: 2 ** nLog2, r, p };
}

/**
 * The key stream that hides `keynum || secret key || checksum` in the secret
 * key file. An empty password is allowed and is what minisign itself does when
 * you press enter at its prompt — it still runs the KDF.
 */
function keyStream(password, salt, memlimit, opslimit) {
  const { N, r, p } = scryptParams(memlimit, opslimit);
  const length = KEYNUM_BYTES + SECRETKEY_BYTES + CHK_BYTES;

  // Node's default maxmem is 32 MiB, exactly the memlimit minisign asks for, so
  // the allocation for N=2^15 lands just over it and throws without this.
  return scryptSync(Buffer.from(password, "utf8"), Buffer.from(salt), length, {
    N,
    r,
    p,
    maxmem: 256 * 1024 * 1024,
  });
}

const xorInto = (data, stream) => {
  const out = Buffer.from(data);
  for (let i = 0; i < out.length; i++) out[i] ^= stream[i];
  return out;
};

/** BLAKE2b-256 over sig_alg || keynum || secret key — minisign's password check. */
const checksum = (keynum, secretKey) =>
  blake2b(Buffer.concat([SIGALG, Buffer.from(keynum), Buffer.from(secretKey)]), CHK_BYTES);

/**
 * Generate a keypair and return both halves as the text minisign writes.
 *
 * @param {{password?: string, comment?: string}} options
 * @returns {{publicKeyFile: string, secretKeyFile: string, publicKeyLine: string, keyId: string}}
 */
export function generateKeyPair({ password = "", comment = DEFAULT_SECRET_KEY_COMMENT } = {}) {
  const seed = randomBytes(32);
  const privateKey = privateKeyFromSeed(seed);
  const publicKeyRaw = rawPublicKeyOf(privateKey);

  // minisign's "secret key" is the libsodium layout: seed then public key.
  const secretKey = Buffer.concat([seed, publicKeyRaw]);
  const keynum = randomBytes(KEYNUM_BYTES);
  const salt = randomBytes(KDF_SALTBYTES);

  const plaintext = Buffer.concat([keynum, secretKey, checksum(keynum, secretKey)]);
  const encrypted = xorInto(
    plaintext,
    keyStream(password, salt, DEFAULT_MEMLIMIT, DEFAULT_OPSLIMIT),
  );

  const secretKeyBytes = Buffer.concat([
    SIGALG,
    KDF_ALG,
    CHK_ALG,
    salt,
    u64le(DEFAULT_OPSLIMIT),
    u64le(DEFAULT_MEMLIMIT),
    encrypted,
  ]);

  const publicKeyBytes = Buffer.concat([SIGALG, keynum, publicKeyRaw]);
  const publicKeyLine = publicKeyBytes.toString("base64");
  const keyId = keyIdHex(keynum);

  return {
    keyId,
    publicKeyLine,
    publicKeyFile: `${COMMENT_PREFIX}minisign public key: ${keyId}\n${publicKeyLine}\n`,
    secretKeyFile: `${COMMENT_PREFIX}${comment}\n${secretKeyBytes.toString("base64")}\n`,
  };
}

/**
 * Open a secret key file. A wrong password is reported as such rather than
 * producing a key that silently signs with garbage.
 *
 * @param {string} secretKeyFile contents of the `.key` file
 * @param {string} password
 */
export function decodeSecretKey(secretKeyFile, password = "") {
  const lines = secretKeyFile.split("\n");
  if (lines.length < 2) throw new Error("Secret key file is missing its encoded key line");

  const bytes = Buffer.from(lines[1].trim(), "base64");
  const expected =
    6 + KDF_SALTBYTES + 16 + KEYNUM_BYTES + SECRETKEY_BYTES + CHK_BYTES;
  if (bytes.length !== expected) {
    throw new Error(`Secret key is ${bytes.length} bytes, expected ${expected}`);
  }

  const sigAlg = bytes.subarray(0, 2);
  const kdfAlg = bytes.subarray(2, 4);
  const chkAlg = bytes.subarray(4, 6);
  if (!sigAlg.equals(SIGALG)) throw new Error("Unsupported signature algorithm in secret key");
  if (!chkAlg.equals(CHK_ALG)) throw new Error("Unsupported checksum algorithm in secret key");

  const salt = bytes.subarray(6, 6 + KDF_SALTBYTES);
  const opslimit = bytes.readBigUInt64LE(6 + KDF_SALTBYTES);
  const memlimit = bytes.readBigUInt64LE(6 + KDF_SALTBYTES + 8);
  const body = bytes.subarray(6 + KDF_SALTBYTES + 16);

  // rust-minisign always writes "Sc"; an unencrypted key would not round-trip
  // through the tools this key has to work with, so it is not accepted.
  if (!kdfAlg.equals(KDF_ALG)) throw new Error("Unsupported key derivation in secret key");

  const plaintext = xorInto(body, keyStream(password, salt, memlimit, opslimit));
  const keynum = plaintext.subarray(0, KEYNUM_BYTES);
  const secretKey = plaintext.subarray(KEYNUM_BYTES, KEYNUM_BYTES + SECRETKEY_BYTES);
  const chk = plaintext.subarray(KEYNUM_BYTES + SECRETKEY_BYTES);

  if (!timingSafeEqual(chk, checksum(keynum, secretKey))) {
    throw new Error("Wrong password for this secret key (checksum mismatch)");
  }

  return {
    keynum: Buffer.from(keynum),
    seed: Buffer.from(secretKey.subarray(0, 32)),
    publicKeyRaw: Buffer.from(secretKey.subarray(32)),
    keyId: keyIdHex(keynum),
  };
}

/** Parse a `.pub` file, or the bare base64 line from inside one. */
export function decodePublicKey(publicKeyFile) {
  const lines = publicKeyFile.trim().split("\n");
  const encoded = (lines.length > 1 ? lines[1] : lines[0]).trim();
  const bytes = Buffer.from(encoded, "base64");

  if (bytes.length !== 2 + KEYNUM_BYTES + PUBLICKEY_BYTES) {
    throw new Error(`Public key is ${bytes.length} bytes, expected 42`);
  }

  return {
    keynum: bytes.subarray(2, 2 + KEYNUM_BYTES),
    publicKeyRaw: bytes.subarray(2 + KEYNUM_BYTES),
    keyId: keyIdHex(bytes.subarray(2, 2 + KEYNUM_BYTES)),
  };
}

/**
 * Sign data, returning the four-line `.minisig` text.
 *
 * @param {object} secretKey as returned by {@link decodeSecretKey}
 * @param {Buffer|Uint8Array} data the artifact bytes
 * @param {{trustedComment?: string, untrustedComment?: string, fileName?: string}} options
 */
export function signBytes(secretKey, data, options = {}) {
  const privateKey = privateKeyFromSeed(secretKey.seed);

  // Pre-hashed mode: what gets signed is BLAKE2b-512 of the artifact, so a
  // multi-hundred-megabyte bundle never has to be held in one buffer by the
  // verifier. Node's native BLAKE2b is used here — only the 32-byte checksum
  // above needs the hand-rolled one.
  const prehash = createHash("blake2b512").update(data).digest();
  const signature = edSign(null, prehash, privateKey);

  const trustedComment =
    options.trustedComment ??
    `timestamp:${Math.floor(Date.now() / 1000)}${
      options.fileName ? `\tfile:${options.fileName}` : ""
    }\thashed`;

  if (trustedComment.includes("\n")) {
    throw new Error("A trusted comment cannot contain a newline");
  }

  // The global signature is what stops the trusted comment being swapped for
  // another file's: it covers the signature and the comment together.
  const globalSignature = edSign(
    null,
    Buffer.concat([signature, Buffer.from(trustedComment, "utf8")]),
    privateKey,
  );

  const untrustedComment = options.untrustedComment ?? DEFAULT_SIGNATURE_COMMENT;
  const body = Buffer.concat([SIGALG_PREHASHED, secretKey.keynum, signature]);

  return [
    `${COMMENT_PREFIX}${untrustedComment}`,
    body.toString("base64"),
    `${TRUSTED_COMMENT_PREFIX}${trustedComment}`,
    globalSignature.toString("base64"),
    "",
  ].join("\n");
}

/**
 * Verify a `.minisig` against data, the same way minisign-verify does for the
 * updater plugin.
 *
 * Returns `{ ok: true, trustedComment }` or `{ ok: false, reason }` — a caller
 * deciding whether to publish a release wants to know which check failed.
 */
export function verifyBytes(publicKeyFile, data, signatureFile) {
  let publicKey;
  try {
    publicKey = decodePublicKey(publicKeyFile);
  } catch (error) {
    return { ok: false, reason: `public key: ${error.message}` };
  }

  const lines = signatureFile.split("\n");
  if (lines.length < 4) return { ok: false, reason: "signature is not four lines" };

  const body = Buffer.from(lines[1].trim(), "base64");
  if (body.length !== 2 + KEYNUM_BYTES + SIGNATURE_BYTES) {
    return { ok: false, reason: `signature body is ${body.length} bytes, expected 74` };
  }
  if (!lines[2].startsWith(TRUSTED_COMMENT_PREFIX)) {
    return { ok: false, reason: "signature is missing its trusted comment" };
  }

  const sigAlg = body.subarray(0, 2);
  const isPrehashed = sigAlg.equals(SIGALG_PREHASHED);
  if (!isPrehashed && !sigAlg.equals(SIGALG)) {
    return { ok: false, reason: "unsupported signature algorithm" };
  }

  const keynum = body.subarray(2, 2 + KEYNUM_BYTES);
  if (!keynum.equals(Buffer.from(publicKey.keynum))) {
    return {
      ok: false,
      reason: `signed by key ${keyIdHex(keynum)}, not ${publicKey.keyId}`,
    };
  }

  const signature = body.subarray(2 + KEYNUM_BYTES);
  const globalSignature = Buffer.from(lines[3].trim(), "base64");
  const trustedComment = lines[2].slice(TRUSTED_COMMENT_PREFIX.length);
  const key = publicKeyFromRaw(publicKey.publicKeyRaw);

  const message = isPrehashed
    ? createHash("blake2b512").update(data).digest()
    : Buffer.from(data);

  if (!edVerify(null, message, key, signature)) {
    return { ok: false, reason: "the artifact does not match its signature" };
  }

  if (
    !edVerify(
      null,
      Buffer.concat([signature, Buffer.from(trustedComment, "utf8")]),
      key,
      globalSignature,
    )
  ) {
    return { ok: false, reason: "the trusted comment does not match its signature" };
  }

  return { ok: true, trustedComment };
}

/**
 * What goes in the updater manifest, and in the `pubkey` field of
 * turbo-desktop.config.json: base64 of the whole file, because the plugin
 * base64-decodes both before parsing them as minisign text.
 */
export const forManifest = (fileContents) => Buffer.from(fileContents, "utf8").toString("base64");

/** The inverse, for reading a signature back out of a manifest. */
export const fromManifest = (encoded) => Buffer.from(encoded, "base64").toString("utf8");
