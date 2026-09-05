import { createHmac } from 'node:crypto';

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function decodeBase32(secret: string): Uint8Array {
  const cleaned = secret.replace(/=+$/u, '').toUpperCase();
  let bits = '';
  for (const char of cleaned) {
    const value = BASE32.indexOf(char);
    if (value === -1) {
      continue;
    }
    bits += value.toString(2).padStart(5, '0');
  }
  const bytes = new Uint8Array(Math.floor(bits.length / 8));
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  }
  return bytes;
}

function dynamicTruncate(hmac: Buffer): number {
  const offset = hmac[hmac.length - 1] & 0x0f;
  return (
    ((hmac[offset] & 0x7f) << 24) |
    ((hmac[offset + 1] & 0xff) << 16) |
    ((hmac[offset + 2] & 0xff) << 8) |
    (hmac[offset + 3] & 0xff)
  );
}

export function generateTOTP(secret: string, at = Date.now(), period = 30, digits = 6): string {
  const counter = Math.floor(at / 1000 / period);
  const buffer = Buffer.alloc(8);
  buffer.writeUInt32BE(Math.floor(counter / 0x100000000), 0);
  buffer.writeUInt32BE(counter >>> 0, 4);
  const hmac = createHmac('sha1', Buffer.from(decodeBase32(secret))).update(buffer).digest();
  const code = dynamicTruncate(hmac) % 10 ** digits;
  return code.toString().padStart(digits, '0');
}

export function otpSecretFromUri(uri: string): string {
  const parsed = new URL(uri);
  const secret = parsed.searchParams.get('secret');
  if (!secret) {
    throw new Error(`otpauth URI missing secret: ${uri}`);
  }
  return secret;
}
