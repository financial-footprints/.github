#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

run_tab() {
  local script_path="${BASH_SOURCE[0]}"

  if [[ $- != *i* ]]; then
    exec bash -i "$script_path" --tab "$@"
  fi

  local repo_dir="${1:-}"
  local run_clean=false
  local status

  if [[ -z "$repo_dir" ]]; then
    echo "usage: dev.sh --tab REPO_DIR [--clean]" >&2
    exec bash -i
  fi
  shift

  if [[ "${1:-}" == "--clean" ]]; then
    run_clean=true
  fi

  if ! cd "$repo_dir"; then
    echo "error: could not cd to $repo_dir" >&2
    exec bash -i
  fi

  shopt -u extdebug 2>/dev/null || true
  set +o debug 2>/dev/null || true
  unset BASH_ENV 2>/dev/null || true

  if [[ "$run_clean" == true ]]; then
    make clean
    status=$?
    if [[ "$status" -ne 0 ]]; then
      echo "make clean failed with exit status $status" >&2
      exec bash -i
    fi
  fi

  make dev
  status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "make dev failed with exit status $status" >&2
  fi

  exec bash -i
}

if [[ "${1:-}" == "--tab" ]]; then
  shift
  run_tab "$@"
fi

set -euo pipefail

source "$SCRIPT_DIR/lib/workspace.sh"

DB_DIR="$WORKSPACE_ROOT/NetworthDB"
SYNC_DIR="$WORKSPACE_ROOT/NetworthSync"
DOM_DIR="$WORKSPACE_ROOT/NetworthDOM"

RUN_CLEAN=false
RUN_DOWN=false
KVSTORE_URL="${KVSTORE_URL:-redis://127.0.0.1:6379/0}"

usage() {
  cat <<'EOF'
Initialize the local stack (Docker, env files, dependencies), then open one
xfce4-terminal window with four tabs that each run `make dev`.

Init runs once in the parent process (JWT, DB, Sync, DOM in order) so shared
Docker infra (Postgres, Valkey, pgAdmin) starts without container name conflicts.

Services (everyday dev ports):
  NetworthJWT     http://127.0.0.1:8100
  NetworthDB      http://127.0.0.1:8200
  NetworthSync    http://127.0.0.1:8000
  NetworthDOM     http://127.0.0.1:3000
  Postgres        localhost:5450
  Valkey          localhost:6379  (KVSTORE_URL=$KVSTORE_URL)
  pgAdmin         http://127.0.0.1:8300

Tabs open in dependency order: JWT, DB, Sync, DOM.
Each tab runs `make dev` only (dependencies were installed during init).

Usage:
  dev.sh [--clean] [--down] [--help]

Options:
  --clean   Run `make clean` before `make dev` in each tab
  --down    Stop shared Docker infra only (same as cleanup.sh --infra), then exit
  --help    Print this help and exit
EOF
}

stop_dev_infra() {
  "$SCRIPT_DIR/cleanup.sh" --infra
}

init_all_dev_repos() {
  local key
  local -a repos=(jwt db sync dom)

  echo "[dev] initializing repos (Docker, env files, dependencies)..."
  for key in "${repos[@]}"; do
    if ! bash "$SCRIPT_DIR/init.sh" --repo "$key" --dev; then
      echo "init failed for $key" >&2
      exit 1
    fi
  done
}

require_dir() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    echo "error: missing $label at $path" >&2
    exit 1
  fi
}

require_terminal() {
  if command -v xfce4-terminal >/dev/null 2>&1; then
    TERMINAL=(xfce4-terminal)
    return 0
  fi
  if command -v xfce-terminal >/dev/null 2>&1; then
    TERMINAL=(xfce-terminal)
    return 0
  fi
  echo "error: xfce4-terminal (or xfce-terminal) is required" >&2
  exit 1
}

tab_command() {
  local dir="$1"
  local -a cmd=(bash "$SCRIPT_DIR/dev.sh" --tab "$dir")
  if [[ "$RUN_CLEAN" == true ]]; then
    cmd+=(--clean)
  fi
  printf '%q ' "${cmd[@]}"
}

launch_dev_window() {
  "${TERMINAL[@]}" \
    --window \
    --title="NetworthJWT :8100" \
    --working-directory="$JWT_DIR" \
    -e "$(tab_command "$JWT_DIR")" \
    --tab \
    --title="NetworthDB :8200" \
    --working-directory="$DB_DIR" \
    -e "$(tab_command "$DB_DIR")" \
    --tab \
    --title="NetworthSync :8000" \
    --working-directory="$SYNC_DIR" \
    -e "$(tab_command "$SYNC_DIR")" \
    --tab \
    --title="NetworthDOM :3000" \
    --working-directory="$DOM_DIR" \
    -e "$(tab_command "$DOM_DIR")" \
    --fullscreen
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean)
        RUN_CLEAN=true
        shift
        ;;
      --down)
        RUN_DOWN=true
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

  if [[ "$RUN_DOWN" == true ]]; then
    stop_dev_infra
    exit 0
  fi

  require_terminal
  require_dir "$JWT_DIR" "NetworthJWT"
  require_dir "$DB_DIR" "NetworthDB"
  require_dir "$SYNC_DIR" "NetworthSync"
  require_dir "$DOM_DIR" "NetworthDOM"

  init_all_dev_repos

  echo "[dev] opening one terminal window (JWT, DB, Sync, DOM tabs)"
  launch_dev_window

  echo "[dev] launched dev tabs under $WORKSPACE_ROOT"
  if [[ "$RUN_CLEAN" == true ]]; then
    echo "[dev] each tab runs: make clean && make dev"
  else
    echo "[dev] each tab runs: make dev"
  fi
}

main "$@"
