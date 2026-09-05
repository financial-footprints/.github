import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { api, bearer, unwrap, vaultAuth } from './http.ts';
import { type LoginResult, srpLogin } from './srp.ts';
import { generateTOTP, otpSecretFromUri } from './totp.ts';
import {
  dummyE2eeBlob,
  PRIMARY_DEK,
  SECONDARY_DEK,
  tenantHeaders,
} from './vault_headers.ts';

const jwtUrl = 'http://127.0.0.1:18100';
const dbUrl = 'http://127.0.0.1:18200';
const syncUrl = 'http://127.0.0.1:18000';
const password = 'password123';
const adminPassword = 'adminadmin';

const here = dirname(fileURLToPath(import.meta.url));
const brunoDir = join(here, '..');

type Envelope<T> = { data: T; errors?: unknown[] };

function requireTokens(login: LoginResult, label: string): LoginResult {
  if (login.status === 'mfa_required' || login.status === 'mfa_enrollment_required') {
    throw new Error(`${label} returned MFA challenge`);
  }
  if (!login.access_token || !login.refresh_token) {
    throw new Error(`${label} missing tokens`);
  }
  return login;
}

async function register(
  adminToken: string,
  username: string,
  role: string,
): Promise<{ id: string; username: string; role: string }> {
  const result = await api<Envelope<{ id: string; username: string; role: string }>>(
    `${jwtUrl}/api/v1/auth/register`,
    {
      method: 'POST',
      headers: bearer(adminToken),
      body: JSON.stringify({ username, password, role }),
    },
  );
  return unwrap(result.status, result.json, result.raw, 201);
}

function bruEnv(vars: Record<string, string>): string {
  const lines = Object.entries(vars).map(([key, value]) => `  ${key}: ${value}`);
  return `vars {\n${lines.join('\n')}\n}\n`;
}

function dotenvFile(vars: Record<string, string>): string {
  return `${Object.entries(vars)
    .map(([key, value]) => `${key}=${value}`)
    .join('\n')}\n`;
}

async function main(): Promise<void> {
  const admin = requireTokens(await srpLogin(jwtUrl, 'admin', adminPassword), 'admin login');
  const adminMe = await api<Envelope<{ id: string; username: string; role: string }>>(
    `${jwtUrl}/api/v1/auth/me`,
    { headers: bearer(admin.access_token) },
  );
  const adminProfile = unwrap(adminMe.status, adminMe.json, adminMe.raw, 200);

  const alice = await register(admin.access_token, 'alice', 'user');
  const manager = await register(admin.access_token, 'manager', 'manager');
  const mfaUser = await register(admin.access_token, 'mfa_user', 'user');
  const doomed = await register(admin.access_token, 'doomed', 'user');

  const aliceLogin = requireTokens(await srpLogin(jwtUrl, 'alice', password), 'alice login');
  const managerLogin = requireTokens(
    await srpLogin(jwtUrl, 'manager', password),
    'manager login',
  );

  const vaultInit = await api(
    `${jwtUrl}/api/v1/auth/me/vault/initialize`,
    {
      method: 'POST',
      headers: bearer(aliceLogin.access_token),
      body: JSON.stringify({
        slots: [
          {
            slot_type: 'password',
            salt: 'AQIDBAUGBwgJCgsMDQ4PEA',
            wrap_blob: 'abc.def',
            password,
          },
        ],
      }),
    },
  );
  unwrap(vaultInit.status, vaultInit.json as Envelope<unknown>, vaultInit.raw, 201);

  const mfaLogin = requireTokens(await srpLogin(jwtUrl, 'mfa_user', password), 'mfa_user login');
  const totpBegin = await api<Envelope<{ uri: string }>>(
    `${jwtUrl}/api/v1/auth/mfa/totp/begin`,
    {
      method: 'POST',
      headers: bearer(mfaLogin.access_token),
      body: JSON.stringify({ password }),
    },
  );
  const begin = unwrap(totpBegin.status, totpBegin.json, totpBegin.raw, 200);
  const totpSecret = otpSecretFromUri(begin.uri);
  const totpConfirm = await api<Envelope<LoginResult>>(
    `${jwtUrl}/api/v1/auth/mfa/totp/confirm`,
    {
      method: 'POST',
      headers: bearer(mfaLogin.access_token),
      body: JSON.stringify({ code: generateTOTP(totpSecret) }),
    },
  );
  const mfaEnrolled = unwrap(totpConfirm.status, totpConfirm.json, totpConfirm.raw, 200);

  const primary = tenantHeaders(PRIMARY_DEK);
  const secondary = tenantHeaders(SECONDARY_DEK);
  const e2eeAccountNumber = dummyE2eeBlob();

  const created = await api<
    Envelope<{
      id: string;
      bank: string;
      variant: string | null;
      account_type: string;
    }>
  >(`${dbUrl}/api/v1/accounts`, {
    method: 'POST',
    headers: vaultAuth(aliceLogin.access_token, primary.userId, primary.vaultVerification),
    body: JSON.stringify({
      bank: 'bob',
      variant: 'easy',
      account_type: 'bank_account',
      opening_date: '2023-04-01',
    }),
  });
  const account = unwrap(created.status, created.json, created.raw, 201);

  const secrets = await api(`${syncUrl}/api/v1/sync/accounts`, {
    method: 'POST',
    headers: vaultAuth(aliceLogin.access_token, primary.userId, primary.vaultVerification),
    body: JSON.stringify({
      id: account.id,
      passwords: ['secret-bob'],
      e2ee_account_number: e2eeAccountNumber,
      statement: { text_contains: ['5678'] },
    }),
  });
  if (secrets.status !== 201) {
    const detail =
      typeof secrets.json === 'object' &&
      secrets.json !== null &&
      'details' in secrets.json
        ? String((secrets.json as { details: unknown }).details)
        : secrets.raw;
    throw new Error(
      `sync secrets create failed: ${secrets.status} ${detail}\n` +
        'Check README/bruno/.run/sync.log for NetworthSync stack traces.',
    );
  }

  const exportRes = await fetch(`${dbUrl}/api/v1/accounts/backup/export`, {
    method: 'POST',
    headers: {
      ...vaultAuth(aliceLogin.access_token, primary.userId, primary.vaultVerification),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      account_numbers: { [account.id]: '5678' },
    }),
  });
  if (!exportRes.ok) {
    throw new Error(`backup export failed: ${exportRes.status} ${await exportRes.text()}`);
  }
  const zip = Buffer.from(await exportRes.arrayBuffer());

  mkdirSync(join(brunoDir, 'environments'), { recursive: true });
  mkdirSync(join(brunoDir, 'fixtures'), { recursive: true });
  mkdirSync(join(brunoDir, '.run'), { recursive: true });
  writeFileSync(join(brunoDir, 'fixtures/generated-backup.zip'), zip);

  const vars: Record<string, string> = {
    jwtUrl,
    dbUrl,
    syncUrl,
    adminUser: 'admin',
    adminPassword,
    adminAccessToken: admin.access_token,
    adminRefreshToken: admin.refresh_token,
    adminId: adminProfile.id,
    aliceUser: 'alice',
    alicePassword: password,
    aliceAccessToken: aliceLogin.access_token,
    aliceRefreshToken: aliceLogin.refresh_token,
    aliceId: alice.id,
    managerUser: 'manager',
    managerAccessToken: managerLogin.access_token,
    managerRefreshToken: managerLogin.refresh_token,
    managerId: manager.id,
    mfaUser: 'mfa_user',
    mfaPassword: password,
    mfaAccessToken: mfaEnrolled.access_token,
    mfaRefreshToken: mfaEnrolled.refresh_token,
    mfaUserId: mfaUser.id,
    totpSecret,
    doomedId: doomed.id,
    userId: primary.userId,
    vaultVerification: primary.vaultVerification,
    secondaryUserId: secondary.userId,
    secondaryVaultVerification: secondary.vaultVerification,
    accountId: account.id,
    e2eeAccountNumber,
    unknownUuid: '00000000-0000-4000-8000-000000000000',
  };

  writeFileSync(join(brunoDir, '.env'), dotenvFile(vars));
  writeFileSync(join(brunoDir, 'environments/generated.bru'), bruEnv(vars));
  console.log(`[e2e] seeded users admin/alice/manager/mfa_user and account ${account.id}`);
}

await main();
