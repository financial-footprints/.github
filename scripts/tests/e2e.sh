#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/workspace.sh"

if [[ -d "$README_REPO_ROOT/bruno" ]]; then
  README_DIR="$README_REPO_ROOT"
elif [[ -d "$WORKSPACE_ROOT/README/bruno" ]]; then
  README_DIR="$WORKSPACE_ROOT/README"
elif [[ -d "$WORKSPACE_ROOT/bruno" ]]; then
  README_DIR="$WORKSPACE_ROOT"
else
  echo "error: Bruno collection not found (checked $README_REPO_ROOT/bruno, $WORKSPACE_ROOT/README/bruno, $WORKSPACE_ROOT/bruno)" >&2
  exit 1
fi

JWT_DIR="$WORKSPACE_ROOT/NetworthJWT"
DB_DIR="$WORKSPACE_ROOT/NetworthHTTP"
SYNC_DIR="$WORKSPACE_ROOT/NetworthSync"
RUN_DIR="$README_DIR/bruno/.run"
JWT_HEALTH="http://127.0.0.1:18100/api/v1/auth/health"
DB_HEALTH="http://127.0.0.1:18200/api/v1/accounts/health"
SYNC_HEALTH="http://127.0.0.1:18000/api/v1/sync/health"
WAIT_TIMEOUT=120

usage() {
  cat <<'EOF'
Run Bruno API tests against an isolated financial-footprints stack.

Does not touch everyday make dev ports 8100 / 8200 / 8000.

Usage:
  e2e.sh              setup, seed, bru run, then down
  e2e.sh setup        reset test DBs, migrate, start APIs, wait for health
  e2e.sh seed         create users, vault headers, sample account
  e2e.sh run          bru run (stack must already be up)
  e2e.sh down         stop only Bruno-stack PIDs
  e2e.sh --help
EOF
}

require_dir() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    echo "error: missing $label at $path" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: $1 is required" >&2
    exit 1
  fi
}

dotenv_var() {
  local file="$1"
  local key="$2"
  local default="${3:-}"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$default"
    return 0
  fi
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  if [[ -z "$line" ]]; then
    printf '%s' "$default"
    return 0
  fi
  local value="${line#*=}"
  value="${value%%#*}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

require_dotenv_var() {
  local file="$1"
  local key="$2"
  local value
  value="$(dotenv_var "$file" "$key")"
  if [[ -z "$value" ]]; then
    echo "error: $key is required in $file" >&2
    exit 1
  fi
  printf '%s' "$value"
}

resolve_service_path() {
  local base_dir="$1"
  local path="$2"
  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  else
    printf '%s' "$base_dir/$path"
  fi
}

DEV_COMPOSE="${WORKSPACE_ROOT}/README/deploy/docker-compose.dev.yml"
COMPOSE=(docker compose -f "$DEV_COMPOSE")

ensure_e2e_docker_infra() {
  echo "[e2e] starting shared Docker (postgres, valkey)"
  "${COMPOSE[@]}" up -d --wait postgres valkey
}

reset_postgres_bruno_db() {
  local pg_user="$1"
  local db_name="$2"
  "${COMPOSE[@]}" exec -T postgres psql -U "$pg_user" -d postgres -tc "SELECT 1" >/dev/null 2>&1 || {
    echo "error: Postgres role '$pg_user' not found. Reset the Docker volume and retry." >&2
    exit 1
  }
  "${COMPOSE[@]}" exec -T postgres psql -U "$pg_user" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db_name}' AND pid <> pg_backend_pid()" >/dev/null
  "${COMPOSE[@]}" exec -T postgres psql -U "$pg_user" -d postgres -c \
    "DROP DATABASE IF EXISTS ${db_name}"
  "${COMPOSE[@]}" exec -T postgres psql -U "$pg_user" -d postgres -c \
    "CREATE DATABASE ${db_name}"
}

pid_alive() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] || return 1
  local pid
  pid="$(cat "$pidfile")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

wait_for_health() {
  local url="$1"
  local label="$2"
  local pidfile="${3:-}"
  local logfile="${4:-}"
  local i
  echo "[e2e] waiting for $label at $url (up to ${WAIT_TIMEOUT}s, log: ${logfile:-none})"
  for i in $(seq 1 "$WAIT_TIMEOUT"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "[e2e] $label is up"
      return 0
    fi
    if [[ -n "$pidfile" ]] && ! pid_alive "$pidfile"; then
      echo "error: $label process exited before health check passed" >&2
      if [[ -n "$logfile" && -f "$logfile" ]]; then
        tail -30 "$logfile" >&2
      fi
      return 1
    fi
    if (( i % 10 == 0 )); then
      echo "[e2e] still waiting for $label (${i}s)..."
    fi
    sleep 1
  done
  echo "error: timed out waiting for $label at $url" >&2
  if [[ -n "$logfile" && -f "$logfile" ]]; then
    tail -30 "$logfile" >&2
  fi
  return 1
}

stop_pidfile() {
  local pidfile="$1"
  if [[ ! -f "$pidfile" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pidfile"
}

free_port() {
  local port="$1"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null || true
    fi
    return 0
  fi
  echo "warning: neither fuser nor lsof found; cannot free port $port" >&2
}

free_bruno_ports() {
  free_port 18100
  free_port 18200
  free_port 18000
  sleep 0.5
}

cmd_down() {
  mkdir -p "$RUN_DIR"
  stop_pidfile "$RUN_DIR/jwt.pid"
  stop_pidfile "$RUN_DIR/db.pid"
  stop_pidfile "$RUN_DIR/sync.pid"
  free_bruno_ports
  echo "[e2e] stopped Bruno-stack processes"
}

require_bruno_env() {
  local dir="$1"
  local label="$2"
  if [[ ! -f "$dir/.env.bruno" ]]; then
    echo "error: missing $label/.env.bruno (copy from .env.bruno.example)" >&2
    exit 1
  fi
}

cmd_setup() {
  require_dir "$JWT_DIR" "NetworthJWT"
  require_dir "$DB_DIR" "NetworthDB"
  require_dir "$SYNC_DIR" "NetworthSync"
  require_cmd curl
  require_cmd bun
  require_cmd make
  require_cmd docker

  require_bruno_env "$JWT_DIR" "NetworthJWT"
  require_bruno_env "$DB_DIR" "NetworthDB"
  require_bruno_env "$SYNC_DIR" "NetworthSync"

  jwt_env="$JWT_DIR/.env.bruno"
  bruno_private="$(dotenv_var "$jwt_env" ED25519_PRIVATE_KEY_PATH ./data/ed25519_private.pem)"
  bruno_public="$(dotenv_var "$jwt_env" ED25519_PUBLIC_KEY_PATH ./data/ed25519_public.pem)"
  bruno_private="$(resolve_service_path "$JWT_DIR" "$bruno_private")"
  bruno_public="$(resolve_service_path "$JWT_DIR" "$bruno_public")"

  if [[ ! -f "$bruno_private" || ! -f "$bruno_public" ]]; then
    echo "error: Ed25519 keys not found for Bruno e2e" >&2
    echo "  set ED25519_PRIVATE_KEY_PATH and ED25519_PUBLIC_KEY_PATH in $jwt_env" >&2
    echo "  openssl genpkey -algorithm Ed25519 -out $bruno_private" >&2
    echo "  openssl pkey -in $bruno_private -pubout -out $bruno_public" >&2
    exit 1
  fi

  if [[ ! -d "$README_DIR/node_modules" ]]; then
    echo "[e2e] installing Bruno CLI dependencies"
    (cd "$README_DIR" && bun install)
  fi

  cmd_down
  mkdir -p "$RUN_DIR"

  jwt_bruno_env="$JWT_DIR/.env.bruno"
  jwt_pg_user="$(require_dotenv_var "$jwt_bruno_env" POSTGRES_USER)"
  jwt_pg_db="$(require_dotenv_var "$jwt_bruno_env" POSTGRES_DATABASE)"
  sync_bruno_env="$SYNC_DIR/.env.bruno"
  sync_pg_user="$(require_dotenv_var "$sync_bruno_env" POSTGRES_USER)"
  sync_pg_db="$(require_dotenv_var "$sync_bruno_env" POSTGRES_DATABASE)"
  db_bruno_env="$DB_DIR/.env.bruno"
  db_pg_user="$(require_dotenv_var "$db_bruno_env" POSTGRES_USER)"
  db_pg_db="$(require_dotenv_var "$db_bruno_env" POSTGRES_DATABASE)"
  sync_download="$(resolve_service_path "$SYNC_DIR" "$(dotenv_var "$sync_bruno_env" DOWNLOAD_PATH ./data/statements-test)")"

  ensure_e2e_docker_infra

  echo "[e2e] resetting JWT Postgres ($jwt_pg_db)"
  reset_postgres_bruno_db "$jwt_pg_user" "$jwt_pg_db"

  echo "[e2e] resetting NetworthDB Postgres ($db_pg_db)"
  reset_postgres_bruno_db "$db_pg_user" "$db_pg_db"

  echo "[e2e] resetting Sync Postgres and statement vault"
  reset_postgres_bruno_db "$sync_pg_user" "$sync_pg_db"
  rm -rf "$sync_download"
  mkdir -p "$sync_download"

  echo "[e2e] starting NetworthJWT (migrate, createuser, dev)"
  (cd "$JWT_DIR" && make e2e) >"$RUN_DIR/jwt.log" 2>&1 &
  echo $! >"$RUN_DIR/jwt.pid"

  echo "[e2e] starting NetworthDB (migrate, dev)"
  (cd "$DB_DIR" && make e2e) >"$RUN_DIR/db.log" 2>&1 &
  echo $! >"$RUN_DIR/db.pid"

  echo "[e2e] starting NetworthSync (migrate, dev)"
  (cd "$SYNC_DIR" && make e2e) >"$RUN_DIR/sync.log" 2>&1 &
  echo $! >"$RUN_DIR/sync.pid"

  wait_for_health "$JWT_HEALTH" "NetworthJWT" "$RUN_DIR/jwt.pid" "$RUN_DIR/jwt.log"
  wait_for_health "$DB_HEALTH" "NetworthDB" "$RUN_DIR/db.pid" "$RUN_DIR/db.log"
  wait_for_health "$SYNC_HEALTH" "NetworthSync" "$RUN_DIR/sync.pid" "$RUN_DIR/sync.log"
}

cmd_seed() {
  require_cmd bun
  if ! (cd "$README_DIR" && bun bruno/scripts/seed.ts); then
    if [[ -f "$RUN_DIR/sync.log" ]]; then
      echo "[e2e] NetworthSync log (last 40 lines):" >&2
      tail -40 "$RUN_DIR/sync.log" >&2
    fi
    if [[ -f "$RUN_DIR/db.log" ]]; then
      echo "[e2e] NetworthDB log (last 20 lines):" >&2
      tail -20 "$RUN_DIR/db.log" >&2
    fi
    return 1
  fi
}

cmd_run() {
  require_cmd bun
  if [[ ! -d "$README_DIR/node_modules" ]]; then
    (cd "$README_DIR" && bun install)
  fi
  (cd "$README_DIR/bruno" && bunx bru run --env generated)
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    -h | --help)
      usage
      exit 0
      ;;
    setup)
      cmd_setup
      ;;
    seed)
      cmd_seed
      ;;
    run)
      cmd_run
      ;;
    down)
      cmd_down
      ;;
    all)
      cmd_setup
      cmd_seed
      set +e
      cmd_run
      local status=$?
      set -e
      cmd_down
      exit "$status"
      ;;
    *)
      echo "error: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
