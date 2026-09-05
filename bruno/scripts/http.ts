type Envelope<T> = {
  data: T;
  errors?: unknown[];
};

export async function api<T>(
  url: string,
  init: RequestInit = {},
): Promise<{ status: number; json: T; raw: string; headers: Headers }> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has('Content-Type') && !(init.body instanceof FormData)) {
    headers.set('Content-Type', 'application/json');
  }
  const response = await fetch(url, { ...init, headers });
  const raw = await response.text();
  let json = {} as T;
  if (raw) {
    try {
      json = JSON.parse(raw) as T;
    } catch {
      json = {} as T;
    }
  }
  return { status: response.status, json, raw, headers: response.headers };
}

export function unwrap<T>(status: number, json: Envelope<T>, raw: string, expected: number): T {
  if (status !== expected) {
    throw new Error(`expected ${expected}, got ${status}: ${raw}`);
  }
  return json.data;
}

export function bearer(token: string, extra: Record<string, string> = {}): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    ...extra,
  };
}

export function vaultAuth(
  token: string,
  userId: string,
  vaultVerification: string,
): HeadersInit {
  return bearer(token, {
    'X-User-Id': userId,
    'X-Vault-Verification': vaultVerification,
  });
}
