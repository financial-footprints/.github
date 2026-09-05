const RFC5054_GROUP14_N = BigInt(
  '0xFFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF',
);

const GROUP_G = 2n;

export function encodeBase64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/u, '');
}

export function decodeBase64url(value: string): Uint8Array {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  let value = 0n;
  for (const byte of bytes) {
    value = (value << 8n) + BigInt(byte);
  }
  return value;
}

function bigIntToBytes(n: bigint): Uint8Array {
  if (n <= 0n) {
    throw new Error('integer must be positive');
  }
  let hex = n.toString(16);
  if (hex.length % 2 !== 0) {
    hex = `0${hex}`;
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function bitLength(n: bigint): number {
  if (n <= 0n) {
    return 0;
  }
  let bits = 0;
  let value = n;
  while (value > 0n) {
    bits += 1;
    value >>= 1n;
  }
  return bits;
}

function pad(n: bigint): Uint8Array {
  if (n <= 0n) {
    throw new Error('integer must be positive');
  }
  const nBytes = Math.ceil(bitLength(n) / 8);
  const raw = bigIntToBytes(n);
  if (raw.length === nBytes) {
    return raw;
  }
  if (raw.length > nBytes) {
    return raw.slice(raw.length - nBytes);
  }
  const out = new Uint8Array(nBytes);
  out.set(raw, nBytes - raw.length);
  return out;
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  let b = base % mod;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) {
      result = (result * b) % mod;
    }
    e >>= 1n;
    b = (b * b) % mod;
  }
  return result;
}

async function sha256(parts: Uint8Array[]): Promise<Uint8Array> {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    merged.set(part, offset);
    offset += part.length;
  }
  return new Uint8Array(await crypto.subtle.digest('SHA-256', merged));
}

async function hashToInt(...parts: Uint8Array[]): Promise<bigint> {
  const digest = await sha256(parts);
  return bytesToBigInt(digest);
}

function normalizePublic(value: bigint): bigint {
  let reduced = value % RFC5054_GROUP14_N;
  if (reduced < 0n) {
    reduced += RFC5054_GROUP14_N;
  }
  if (reduced === 0n) {
    throw new Error('invalid SRP public value');
  }
  return reduced;
}

function encodeInt(n: bigint): string {
  return encodeBase64url(pad(n));
}

function decodeInt(value: string): bigint {
  const bytes = decodeBase64url(value);
  if (bytes.length === 0) {
    throw new Error('empty integer encoding');
  }
  const result = bytesToBigInt(bytes);
  if (result <= 0n) {
    throw new Error('integer must be positive');
  }
  return normalizePublic(result);
}

function encodeBytes(bytes: Uint8Array): string {
  return encodeBase64url(bytes);
}

let groupK: bigint | null = null;

async function getGroupK(): Promise<bigint> {
  if (groupK === null) {
    groupK = await hashToInt(pad(RFC5054_GROUP14_N), pad(GROUP_G));
  }
  return groupK;
}

type ClientEphemeral = {
  secret: bigint;
  public: bigint;
};

function randomPrivate(mod: bigint): bigint {
  const byteLen = (mod.toString(16).length + 1) >> 1;
  while (true) {
    const bytes = crypto.getRandomValues(new Uint8Array(byteLen));
    bytes[0] &= 0x7f;
    const value = bytesToBigInt(bytes) % mod;
    if (value > 0n) {
      return value;
    }
  }
}

async function deriveX(password: string, salt: Uint8Array): Promise<bigint> {
  const { argon2id } = await import('hash-wasm');
  const xBytes = await argon2id({
    password,
    salt,
    parallelism: 1,
    iterations: 2,
    memorySize: 65_536,
    hashLength: 32,
    outputType: 'binary',
  });
  return hashToInt(new Uint8Array(xBytes));
}

async function newClientEphemeral(): Promise<{
  clientPublic: string;
  ephemeral: ClientEphemeral;
}> {
  const secret = randomPrivate(RFC5054_GROUP14_N);
  const publicValue = normalizePublic(modPow(GROUP_G, secret, RFC5054_GROUP14_N));
  return {
    clientPublic: encodeInt(publicValue),
    ephemeral: { secret, public: publicValue },
  };
}

async function sessionKey(s: bigint): Promise<Uint8Array> {
  return sha256([pad(s)]);
}

async function computeM1(
  username: string,
  saltB64: string,
  a: bigint,
  b: bigint,
  key: Uint8Array,
): Promise<Uint8Array> {
  const hn = await sha256([pad(RFC5054_GROUP14_N)]);
  const hg = await sha256([pad(GROUP_G)]);
  const xor = new Uint8Array(hn.length);
  for (let i = 0; i < xor.length; i += 1) {
    xor[i] = hn[i] ^ hg[i];
  }
  const usernameBytes = new TextEncoder().encode(username);
  const usernameHash = await sha256([usernameBytes]);
  const salt = decodeBase64url(saltB64);
  return sha256([xor, usernameHash, salt, pad(a), pad(b), key]);
}

async function srpSession(
  password: string,
  saltB64: string,
  serverPublicB64: string,
  ephemeral: ClientEphemeral,
): Promise<{ b: bigint; key: Uint8Array }> {
  const k = await getGroupK();
  const b = decodeInt(serverPublicB64);
  const x = await deriveX(password, decodeBase64url(saltB64));
  const u = await hashToInt(pad(ephemeral.public), pad(b));
  const gx = modPow(GROUP_G, x, RFC5054_GROUP14_N);
  const kgx = (k * gx) % RFC5054_GROUP14_N;
  const base = (b - kgx + RFC5054_GROUP14_N) % RFC5054_GROUP14_N;
  const exp = ephemeral.secret + u * x;
  const s = modPow(base, exp, RFC5054_GROUP14_N);
  const key = await sessionKey(s);
  return { b, key };
}

async function clientProof(
  username: string,
  password: string,
  saltB64: string,
  serverPublicB64: string,
  ephemeral: ClientEphemeral,
): Promise<string> {
  const { b, key } = await srpSession(password, saltB64, serverPublicB64, ephemeral);
  const m1 = await computeM1(username, saltB64, ephemeral.public, b, key);
  return encodeBytes(m1);
}

export type TokenPair = {
  access_token: string;
  refresh_token: string;
  token_type?: string;
  expires_in?: number;
};

export type LoginResult = TokenPair & {
  status?: string;
  mfa_token?: string;
  methods?: string[];
};

type ApiEnvelope<T> = {
  data: T;
  errors: unknown[];
};

async function jsonRequest<T>(
  url: string,
  init?: RequestInit,
): Promise<{ status: number; body: T; raw: string }> {
  const response = await fetch(url, init);
  const raw = await response.text();
  let body = {} as T;
  if (raw) {
    body = JSON.parse(raw) as T;
  }
  return { status: response.status, body, raw };
}

export async function srpLogin(
  jwtUrl: string,
  username: string,
  password: string,
): Promise<LoginResult> {
  const challenge = await jsonRequest<ApiEnvelope<{ challenge_id: string }>>(
    `${jwtUrl}/api/v1/auth/login/challenge`,
  );
  if (challenge.status !== 200) {
    throw new Error(`login challenge failed: ${challenge.status} ${challenge.raw}`);
  }
  const challengeId = challenge.body.data.challenge_id;
  const { clientPublic, ephemeral } = await newClientEphemeral();

  const begin = await jsonRequest<ApiEnvelope<{ srp_salt: string; server_public: string }>>(
    `${jwtUrl}/api/v1/auth/login/begin`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        challenge_id: challengeId,
        username,
        client_public: clientPublic,
      }),
    },
  );
  if (begin.status !== 200) {
    throw new Error(`login begin failed: ${begin.status} ${begin.raw}`);
  }

  const proof = await clientProof(
    username.toLowerCase(),
    password,
    begin.body.data.srp_salt,
    begin.body.data.server_public,
    ephemeral,
  );

  const finish = await jsonRequest<ApiEnvelope<LoginResult>>(
    `${jwtUrl}/api/v1/auth/login/finish`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        challenge_id: challengeId,
        client_public: clientPublic,
        client_proof: proof,
      }),
    },
  );
  if (finish.status !== 200) {
    throw new Error(`login finish failed: ${finish.status} ${finish.raw}`);
  }
  return finish.body.data;
}
