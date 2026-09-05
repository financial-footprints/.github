import { createHmac, hkdfSync } from 'node:crypto';

import { encodeBase64url } from './srp.ts';

const USER_ID_INFO = Buffer.from('networth-user-id-v1');
const VERIFICATION_MESSAGE = Buffer.from('networth-vault-verification-v1');

export const PRIMARY_DEK = Buffer.alloc(32, 0x11);
export const SECONDARY_DEK = Buffer.alloc(32, 0x22);

export function deriveUserId(dek: Buffer = PRIMARY_DEK): string {
  const derived = hkdfSync('sha256', dek, Buffer.alloc(0), USER_ID_INFO, 32);
  return encodeBase64url(new Uint8Array(derived));
}

export function deriveVaultVerification(dek: Buffer = PRIMARY_DEK): string {
  const mac = createHmac('sha256', dek).update(VERIFICATION_MESSAGE).digest();
  return encodeBase64url(new Uint8Array(mac));
}

export function tenantHeaders(dek: Buffer = PRIMARY_DEK): {
  userId: string;
  vaultVerification: string;
} {
  return {
    userId: deriveUserId(dek),
    vaultVerification: deriveVaultVerification(dek),
  };
}

export function dummyE2eeBlob(): string {
  return `${encodeBase64url(new TextEncoder().encode('test-nonce-bytes'))}.${encodeBase64url(new TextEncoder().encode('test-ciphertext'))}`;
}
