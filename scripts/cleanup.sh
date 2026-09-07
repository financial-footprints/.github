#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
README_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

if [[ -d "$README_REPO_ROOT/../NetworthJWT" ]]; then
  WORKSPACE_ROOT="$(cd "$README_REPO_ROOT/.." && pwd -P)"
elif [[ -d "$SCRIPT_DIR/../../NetworthJWT" ]]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
elif [[ -d "$SCRIPT_DIR/../NetworthJWT" ]]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
else
  echo "error: NetworthJWT not found next to the workspace root" >&2
  echo "Clone sibling repos under financial-footprints/ and symlink README/scripts." >&2
  exit 1
fi

if [[ -d "$README_REPO_ROOT/bruno" ]]; then
  README_DIR="$README_REPO_ROOT"
elif [[ -d "$WORKSPACE_ROOT/README/bruno" ]]; then
  README_DIR="$WORKSPACE_ROOT/README"
elif [[ -d "$WORKSPACE_ROOT/bruno" ]]; then
  README_DIR="$WORKSPACE_ROOT"
else
  README_DIR="$README_REPO_ROOT"
fi

JWT_DIR="$WORKSPACE_ROOT/NetworthJWT"
CSV_DIR="$WORKSPACE_ROOT/NetworthCSV"
DB_DIR="$WORKSPACE_ROOT/NetworthDB"
SYNC_DIR="$WORKSPACE_ROOT/NetworthSync"
DOM_DIR="$WORKSPACE_ROOT/NetworthDOM"

DEV_COMPOSE="$README_REPO_ROOT/deploy/docker-compose.dev.yml"
INFRA_ONLY=false

usage() {
  cat <<'EOF'
Clean up the local financial-footprints workspace.

Default (full cleanup):
  1. Stop Bruno e2e stack processes (ports 18100 / 18200 / 18000)
  2. Stop everyday dev servers (JWT, DB, Sync, DOM)
  3. Stop shared Docker containers (Postgres, Valkey, DbGate; images kept)
  4. Run `make clean` in each repository

Does not remove downloaded Docker images.

Usage:
  cleanup.sh [--infra] [--help]

Options:
  --infra   Stop only shared Docker containers (Postgres, Valkey, DbGate)
  --help    Print this help and exit
EOF
}

stop_e2e_stack() {
  local e2e_script="$SCRIPT_DIR/tests/e2e.sh"

  if [[ ! -f "$e2e_script" ]]; then
    echo "[cleanup] skipped Bruno e2e: missing $e2e_script"
    return 0
  fi

  echo "[cleanup] stopping Bruno e2e stack"
  "$e2e_script" down
}

stop_repo_process() {
  local dir="$1"
  local label="$2"
  local target="$3"

  if [[ ! -d "$dir" ]]; then
    echo "[cleanup] skipped $label: directory not found at $dir"
    return 0
  fi

  if [[ ! -f "$dir/Makefile" ]]; then
    echo "[cleanup] skipped $label: no Makefile in $dir"
    return 0
  fi

  echo "[cleanup] stopping $label"
  (cd "$dir" && make "$target")
}

stop_dev_apps() {
  stop_repo_process "$JWT_DIR" "NetworthJWT :8100" kill
  stop_repo_process "$DB_DIR" "NetworthDB :8200" kill
  stop_repo_process "$SYNC_DIR" "NetworthSync :8000" kill
  stop_repo_process "$DOM_DIR" "NetworthDOM :3000" stop
}

stop_dev_infra() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[cleanup] skipped Docker: docker not installed"
    return 0
  fi

  echo "[cleanup] stopping shared Postgres, Valkey, and DbGate (containers only; images kept)"
  docker compose -f "$DEV_COMPOSE" down
}

clean_repo() {
  local dir="$1"
  local label="$2"

  if [[ ! -d "$dir" ]]; then
    echo "[cleanup] skipped $label clean: directory not found at $dir"
    return 0
  fi

  if [[ ! -f "$dir/Makefile" ]]; then
    echo "[cleanup] skipped $label clean: no Makefile in $dir"
    return 0
  fi

  echo "[cleanup] cleaning $label"
  (cd "$dir" && make clean)
}

clean_repos() {
  clean_repo "$JWT_DIR" "NetworthJWT"
  clean_repo "$CSV_DIR" "NetworthCSV"
  clean_repo "$SYNC_DIR" "NetworthSync"
  clean_repo "$DB_DIR" "NetworthDB"
  clean_repo "$DOM_DIR" "NetworthDOM"
}

clean_bruno_run_artifacts() {
  local run_dir="$README_DIR/bruno/.run"

  if [[ ! -d "$run_dir" ]]; then
    return 0
  fi

  echo "[cleanup] removing Bruno run logs in $run_dir"
  rm -f "$run_dir"/*.log "$run_dir"/*.pid 2>/dev/null || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --infra)
        INFRA_ONLY=true
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

  if [[ "$INFRA_ONLY" == true ]]; then
    stop_dev_infra
    exit 0
  fi

  stop_e2e_stack
  stop_dev_apps
  stop_dev_infra
  clean_repos
  clean_bruno_run_artifacts

  echo "[cleanup] workspace cleanup finished under $WORKSPACE_ROOT"
}

main "$@"
