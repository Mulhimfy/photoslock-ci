// Test vectors for the notes cipher, sealed by the JS library the app used
// before (and still uses on Android): run inside the app checkout, after npm ci.
const { gcm } = require('@noble/ciphers/aes');
const { randomBytes } = require('crypto');
const b64 = (u) => Buffer.from(u).toString('base64');
const out = [];
for (let i = 0; i < 40; i++) {
  const key = randomBytes(32), nonce = randomBytes(12);
  const plain = Buffer.from(JSON.stringify({ t: 'note ' + i, b: 'x'.repeat(i * 53) + ' ✓ مرحبا', p: i % 2 === 0 }));
  const aad = Buffer.from('note-id-' + i);
  out.push({ key: b64(key), nonce: b64(nonce), plain: b64(plain), aad: b64(aad), sealed: b64(gcm(key, nonce, aad).encrypt(plain)) });
}
process.stdout.write(JSON.stringify(out));
