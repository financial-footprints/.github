# Local API stack (Docker Compose)

Optional compose file to run **NetworthJWT, NetworthDB, and NetworthSync** together with
a bundled Postgres for integration testing on a dev machine.

**Production deployment is documented in homelab:**
`/invar/homelab/services/active/networthdb/README.md`

Each service image is built from its own repository Dockerfile — not from this folder.

## Prerequisites

- Docker with Compose v2
- Sibling repos: `NetworthJWT/`, `NetworthDB/`, `NetworthSync/`, `NetworthDOM/`

## Start the API stack

```bash
cd README/deploy
cp .env.example .env
# Set JWT_MFA_ENCRYPTION_KEY, DB_STORAGE_MASTER_KEY, SYNC_STORAGE_MASTER_KEY

mkdir -p .local/jwt
openssl genpkey -algorithm Ed25519 -out .local/jwt/ed25519_private.pem
openssl pkey -in .local/jwt/ed25519_private.pem -pubout -out .local/jwt/ed25519_public.pem

docker compose --profile local up -d --build
docker exec -it networthjwt createuser -username admin -password 'your-password'
```

APIs are published on `localhost:8100`, `8200`, and `8000`.

## UI (local dev)

Run NetworthDOM on the host — not in this compose file:

```bash
cd NetworthDOM
NETWORTHJWT_API=http://127.0.0.1:8100 \
NETWORTHSYNC_API=http://127.0.0.1:8000 \
NETWORTHDB_API=http://127.0.0.1:8200 \
make dev
```

Or leave those empty to use the Rsbuild dev proxy (same ports).

## Build and publish API images

```bash
docker build -t docker.io/atb00ker/networth-jwt:latest NetworthJWT
docker build -t docker.io/atb00ker/networth-db:latest NetworthDB
docker build -t docker.io/atb00ker/networth-sync:latest NetworthSync
```

NetworthDOM has no Docker image. For homelab, build with empty API env vars and rsync
`dist/` to `/opt/nginx/static/networthdb/` (see homelab NetworthDB README).

Push API images, then deploy via homelab ansible.

## Health checks

| Service | Endpoint                      |
| ------- | ----------------------------- |
| JWT     | `GET /api/v1/auth/health`     |
| DB      | `GET /api/v1/accounts/health` |
| Sync    | `GET /api/v1/sync/health`     |
