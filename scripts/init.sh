#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
README_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

if [[ -d "$README_REPO_ROOT/../NetworthJWT" ]]; then
  WORKSPACE_ROOT="$(cd "$README_REPO_ROOT/.." && pwd -P)"
else
  WORKSPACE_ROOT="$README_REPO_ROOT"
fi

declare -A REPO_DIRS=(
  [jwt]="NetworthJWT"
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [db]="NetworthDB"
  [dom]="NetworthDOM"
)

declare -A REPO_LABELS=(
  [jwt]="NetworthJWT"
  [csv]="NetworthCSV"
  [sync]="NetworthSync"
  [db]="NetworthDB"
  [dom]="NetworthDOM"
)

REPO_KEY=""
REPO_PATH=""
DEV_MODE=false
DEV_COMPOSE="$README_REPO_ROOT/deploy/docker-compose.dev.yml"
KVSTORE_URL="${KVSTORE_URL:-redis://127.0.0.1:6379/0}"

usage() {
  cat <<'EOF'
Ensure local env files, dev dependencies, and Docker infra for one financial-footprints repo.

Copies example env/config files when missing, starts required Docker services
(Postgres, Valkey, pgAdmin), creates Postgres databases from `.env` / `.env.test`
when missing, then runs the repo's install target (make install or
make dev-install).

Usage:
  init.sh --repo KEY
  init.sh --cwd /path/to/NetworthDB

Options:
  --repo KEY   jwt | csv | sync | db | dom
  --cwd PATH   Repo directory (--repo inferred from the folder name when omitted)
  --dev        Start full dev Docker stack (Postgres + Valkey + pgAdmin where applicable)
  -h, --help   Print this help and exit
EOF
}

copy_if_missing() {
  local example="$1"
  local target="$2"
  local label="$3"

  if [[ -f "$target" ]]; then
    return 0
  fi
  if [[ ! -f "$example" ]]; then
    return 0
  fi
  cp "$example" "$target"
  echo "[$label] created $(basename "$target") from $(basename "$example")"
}

dotenv_var() {
  local file="$1"
  local key="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  local value="${line#*=}"
  value="${value%%#*}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#"${value%%[![:space:]]*}"}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

ensure_postgres_database() {
  local env_file="$1"
  local label="${2:-$(basename "$env_file")}"

  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  local pg_user pg_database
  pg_user="$(dotenv_var "$env_file" POSTGRES_USER || true)"
  pg_database="$(dotenv_var "$env_file" POSTGRES_DATABASE || true)"

  if [[ -z "$pg_user" || -z "$pg_database" ]]; then
    echo "[$REPO_KEY] skipping database ensure: POSTGRES_USER or POSTGRES_DATABASE missing in $env_file" >&2
    return 0
  fi

  local exists
  exists="$(
    docker compose -f "$DEV_COMPOSE" exec -T postgres \
      psql -U "$pg_user" -d postgres -tc \
      "SELECT 1 FROM pg_database WHERE datname = '${pg_database}'" 2>/dev/null \
      | tr -d '[:space:]'
  )"
  if [[ "$exists" == "1" ]]; then
    return 0
  fi

  echo "[$REPO_KEY] creating database $pg_database ($label)"
  docker compose -f "$DEV_COMPOSE" exec -T postgres \
    psql -U "$pg_user" -d postgres -c "CREATE DATABASE ${pg_database}"
}

ensure_repo_postgres_databases() {
  local key="$1"
  local repo_path="$2"

  case "$key" in
    jwt | sync | db)
      ensure_postgres_database "$repo_path/.env" "dev"
      if [[ -f "$repo_path/.env.test" ]]; then
        ensure_postgres_database "$repo_path/.env.test" "test"
      fi
      ;;
  esac
}

detect_repo_key_from_path() {
  local dir_name
  dir_name="$(basename "$(cd "$1" && pwd -P)")"
  case "$dir_name" in
    NetworthJWT) printf '%s\n' jwt ;;
    NetworthCSV) printf '%s\n' csv ;;
    NetworthSync) printf '%s\n' sync ;;
    NetworthDB) printf '%s\n' db ;;
    NetworthDOM) printf '%s\n' dom ;;
    *) return 1 ;;
  esac
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required for $REPO_KEY (shared dev infra)" >&2
    exit 1
  fi
}

repo_docker_services() {
  local key="$1"
  local -a services=()

  case "$key" in
    jwt | sync | db)
      services+=(postgres)
      if [[ "$DEV_MODE" == true ]]; then
        case "$key" in
          jwt)
            services+=(valkey pgadmin)
            ;;
          sync | db)
            services+=(pgadmin)
            ;;
        esac
      fi
      ;;
  esac

  printf '%s\n' "${services[@]}"
}

ensure_docker_infra() {
  local key="$1"
  local -a services=()
  local service

  while IFS= read -r service; do
    [[ -n "$service" ]] && services+=("$service")
  done < <(repo_docker_services "$key")

  if [[ ${#services[@]} -eq 0 ]]; then
    return 0
  fi

  require_docker
  echo "[$key] starting Docker (${services[*]})"
  docker compose -f "$DEV_COMPOSE" up -d --wait "${services[@]}"

  if [[ "$DEV_MODE" == true ]]; then
    case "$key" in
      jwt)
        echo "[$key] postgres ready on localhost:5450"
        echo "[$key] valkey ready: KVSTORE_URL=$KVSTORE_URL"
        echo "[$key] pgadmin: http://127.0.0.1:8300"
        ;;
      sync | db)
        echo "[$key] postgres ready on localhost:5450"
        echo "[$key] pgadmin: http://127.0.0.1:8300"
        ;;
    esac
  elif [[ "$key" == jwt || "$key" == sync || "$key" == db ]]; then
    echo "[$key] postgres ready on localhost:5450"
  fi
}

init_repo() {
  local key="$1"
  local repo_path="$2"
  local label="${REPO_LABELS[$key]}"

  echo "[$key] preparing $label (env files, Docker, and dependencies)..."
  ensure_docker_infra "$key"
  ensure_repo_postgres_databases "$key" "$repo_path"
  cd "$repo_path"

  case "$key" in
    jwt)
      copy_if_missing .env.example .env "$key"
      copy_if_missing .env.bruno.example .env.bruno "$key"
      make install
      ;;
    csv)
      copy_if_missing .env.example .env "$key"
      copy_if_missing sources.example.json sources.json "$key"
      copy_if_missing accounts.example.json accounts.json "$key"
      make install
      ;;
    sync)
      copy_if_missing .env.example .env "$key"
      copy_if_missing .env.bruno.example .env.bruno "$key"
      make dev-install
      ;;
    db)
      make dev-install
      ;;
    dom)
      copy_if_missing .env.example .env "$key"
      make install
      ;;
    *)
      echo "error: unknown repo key: $key" >&2
      exit 1
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO_KEY="$2"
        shift 2
        ;;
      --cwd)
        REPO_PATH="$2"
        shift 2
        ;;
      --dev)
        DEV_MODE=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  local repo_path=""

  if [[ -n "$REPO_PATH" ]]; then
    repo_path="$(cd "$REPO_PATH" && pwd -P)"
    if [[ -z "$REPO_KEY" ]]; then
      REPO_KEY="$(detect_repo_key_from_path "$repo_path")" || {
        echo "error: could not detect repo from $repo_path" >&2
        exit 1
      }
    fi
  elif [[ -n "$REPO_KEY" ]]; then
    repo_path="$WORKSPACE_ROOT/${REPO_DIRS[$REPO_KEY]}"
  else
    echo "error: pass --repo KEY or --cwd PATH" >&2
    usage >&2
    exit 1
  fi

  if [[ -z "${REPO_DIRS[$REPO_KEY]+x}" ]]; then
    echo "error: unknown repo key: $REPO_KEY" >&2
    exit 1
  fi

  if [[ ! -d "$repo_path" ]]; then
    echo "error: repo directory not found: $repo_path" >&2
    exit 1
  fi

  if [[ ! -f "$repo_path/Makefile" ]]; then
    echo "error: no Makefile in $repo_path" >&2
    exit 1
  fi

  init_repo "$REPO_KEY" "$repo_path"
}

main "$@"
