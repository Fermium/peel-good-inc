#!/usr/bin/env node
// Encrypts a label for one Mac, for a Peel Good source set to "Only accept encrypted labels".
// The format is in docs/REMOTE-SOURCES.md. Needs Node and nothing else.
//
//   node seal.mjs keygen
//   SENDER_KEY=<private key> node seal.mjs seal <Mac's key> label.pdf label.sealed [--name order.pdf] [--copies 2]
import { createCipheriv, createHmac, createPrivateKey, createPublicKey, diffieHellman, generateKeyPairSync } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const MAGIC = Buffer.from("PGSEAL1\n");
const INFO = Buffer.from("peel-good sealed label");
const u16 = (n) => Buffer.from([n >> 8, n & 255]);
const KEM = Buffer.concat([Buffer.from("KEM"), u16(0x20)]);
const HPKE = Buffer.concat([Buffer.from("HPKE"), u16(0x20), u16(1), u16(3)]);
const VERSION = Buffer.from("HPKE-v1");
const b64url = (b) => Buffer.from(b).toString("base64url");
const hmac = (key, data) => createHmac("sha256", key).update(data).digest();

// RFC 9180 section 4. Every output here is at most one SHA-256 block.
const extract = (suite, salt, label, ikm) => hmac(salt, Buffer.concat([VERSION, suite, Buffer.from(label), ikm]));
const expand = (suite, prk, label, info, length) =>
  hmac(prk, Buffer.concat([u16(length), VERSION, suite, Buffer.from(label), info, Buffer.from([1])])).subarray(0, length);

const publicFrom = (raw) => createPublicKey({ key: { kty: "OKP", crv: "X25519", x: b64url(raw) }, format: "jwk" });
const rawPublic = (key) => Buffer.from(key.export({ format: "jwk" }).x, "base64url");
function privateFrom(raw) {
  const x = createPublicKey(createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b656e04220420", "hex"), raw]), format: "der", type: "pkcs8" }));
  return createPrivateKey({ key: { kty: "OKP", crv: "X25519", x: b64url(rawPublic(x)), d: b64url(raw) }, format: "jwk" });
}
function rawKey(text, what) {
  const raw = Buffer.from(text.trim(), "base64");
  if (raw.length !== 32) throw new Error(`${what} isn't a 32-byte base64 key`);
  return raw;
}

// HPKE in auth mode: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305.
function seal(plain, macRaw, senderRaw) {
  const mac = publicFrom(macRaw), sender = privateFrom(senderRaw);
  const eph = generateKeyPairSync("x25519");
  const enc = rawPublic(eph.publicKey);
  const dh = Buffer.concat([diffieHellman({ privateKey: eph.privateKey, publicKey: mac }), diffieHellman({ privateKey: sender, publicKey: mac })]);
  const context = Buffer.concat([enc, macRaw, rawPublic(createPublicKey(sender))]);
  const shared = expand(KEM, extract(KEM, Buffer.alloc(0), "eae_prk", dh), "shared_secret", context, 32);
  const empty = Buffer.alloc(0);
  const schedule = Buffer.concat([Buffer.from([2]), extract(HPKE, empty, "psk_id_hash", empty), extract(HPKE, empty, "info_hash", INFO)]);
  const secret = extract(HPKE, shared, "secret", empty);
  const cipher = createCipheriv("chacha20-poly1305", expand(HPKE, secret, "key", schedule, 32), expand(HPKE, secret, "base_nonce", schedule, 12), { authTagLength: 16 });
  cipher.setAAD(MAGIC);
  return Buffer.concat([MAGIC, enc, cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
}

const [command, ...args] = process.argv.slice(2);
if (command === "keygen") {
  const { privateKey, publicKey } = generateKeyPairSync("x25519");
  console.log(`Sender's key, for Peel Good: ${rawPublic(publicKey).toString("base64")}`);
  console.log(`Private key, for SENDER_KEY:  ${Buffer.from(privateKey.export({ format: "jwk" }).d, "base64url").toString("base64")}`);
} else if (command === "seal" && args.length >= 3) {
  const [macKey, input, output, ...flags] = args;
  const details = {};
  for (let i = 0; i < flags.length; i += 2) {
    if (flags[i] === "--name") details.name = flags[i + 1];
    else if (flags[i] === "--copies") details.copies = Number(flags[i + 1]);
    else throw new Error(`unknown option ${flags[i]}`);
  }
  const json = Buffer.from(JSON.stringify(details));
  const length = Buffer.alloc(4);
  length.writeUInt32BE(json.length);
  const plain = Buffer.concat([length, json, readFileSync(input)]);
  writeFileSync(output, seal(plain, rawKey(macKey, "The Mac's key"), rawKey(process.env.SENDER_KEY ?? "", "SENDER_KEY")));
} else {
  console.error("usage: seal.mjs keygen\n       SENDER_KEY=<private key> seal.mjs seal <Mac's key> <input> <output> [--name <name>] [--copies <n>]");
  process.exit(2);
}
