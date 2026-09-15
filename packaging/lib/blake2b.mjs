// BLAKE2b (RFC 7693), enough of it to produce the 32-byte digest minisign uses
// as the secret key's checksum.
//
// Node's crypto only exposes BLAKE2b at its full 64-byte output ("blake2b512"),
// and BLAKE2b does not truncate: the requested digest length goes into the
// parameter block, so a 32-byte digest is a different function rather than the
// first half of the 64-byte one. Signing itself still uses Node's native
// implementation — this is only reached for the 32-byte checksum, which covers
// 74 bytes, so the 64-bit BigInt arithmetic below costs nothing measurable and
// is far easier to check against the spec than a 32-bit port.
//
// `blake2b(data, 64)` is deliberately kept working so a test can hold it against
// Node's own blake2b512 — the same compression function produces both, so that
// comparison is what says this implementation is right.

const MASK64 = (1n << 64n) - 1n;

const IV = [
  0x6a09e667f3bcc908n,
  0xbb67ae8584caa73bn,
  0x3c6ef372fe94f82bn,
  0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n,
  0x9b05688c2b3e6c1fn,
  0x1f83d9abfb41bd6bn,
  0x5be0cd19137e2179n,
];

const SIGMA = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
];

const rotr = (x, n) => ((x >> n) | (x << (64n - n))) & MASK64;

function mix(v, a, b, c, d, x, y) {
  v[a] = (v[a] + v[b] + x) & MASK64;
  v[d] = rotr(v[d] ^ v[a], 32n);
  v[c] = (v[c] + v[d]) & MASK64;
  v[b] = rotr(v[b] ^ v[c], 24n);
  v[a] = (v[a] + v[b] + y) & MASK64;
  v[d] = rotr(v[d] ^ v[a], 16n);
  v[c] = (v[c] + v[d]) & MASK64;
  v[b] = rotr(v[b] ^ v[c], 63n);
}

/** One compression of a 128-byte block. `counter` counts bytes fed in so far. */
function compress(h, block, counter, last) {
  const v = [...h, ...IV];
  v[12] ^= counter & MASK64;
  v[13] ^= (counter >> 64n) & MASK64;
  if (last) v[14] ^= MASK64;

  const m = [];
  for (let i = 0; i < 16; i++) m.push(block.readBigUInt64LE(i * 8));

  for (const s of SIGMA) {
    mix(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
    mix(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
    mix(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
    mix(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
    mix(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
    mix(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
    mix(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
    mix(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
  }

  for (let i = 0; i < 8; i++) h[i] = h[i] ^ v[i] ^ v[i + 8];
}

/**
 * Unkeyed BLAKE2b.
 *
 * @param {Buffer|Uint8Array} data
 * @param {number} digestLength bytes, 1..64
 * @returns {Buffer}
 */
export function blake2b(data, digestLength = 64) {
  if (!Number.isInteger(digestLength) || digestLength < 1 || digestLength > 64) {
    throw new RangeError(`BLAKE2b digest length must be 1..64, got ${digestLength}`);
  }

  const input = Buffer.from(data);
  const h = [...IV];
  h[0] ^= 0x01010000n ^ BigInt(digestLength);

  // Every full block but the last is compressed as a non-final block; the last
  // is zero-padded, yet the counter still reports the real byte count.
  let offset = 0;
  while (input.length - offset > 128) {
    compress(h, input.subarray(offset, offset + 128), BigInt(offset + 128), false);
    offset += 128;
  }

  const tail = Buffer.alloc(128);
  input.copy(tail, 0, offset);
  compress(h, tail, BigInt(input.length), true);

  const out = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) out.writeBigUInt64LE(h[i], i * 8);
  return out.subarray(0, digestLength);
}
