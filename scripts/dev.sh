#!/usr/bin/env bash

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

  init_dev
  status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "init_dev failed with exit status $status" >&2
    exec bash -i
  fi

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

JWT_DIR="$WORKSPACE_ROOT/NetworthJWT"
DB_DIR="$WORKSPACE_ROOT/NetworthDB"
SYNC_DIR="$WORKSPACE_ROOT/NetworthSync"
DOM_DIR="$WORKSPACE_ROOT/NetworthDOM"

RUN_CLEAN=false

usage() {
  cat <<'EOF'
Open one xfce4-terminal window with four tabs, run `init_dev`, then `make dev`
for the local stack.

Services (everyday dev ports):
  NetworthJWT   http://127.0.0.1:8100
  NetworthDB    http://127.0.0.1:8200  (+ Postgres on localhost:5450)
  NetworthSync  http://127.0.0.1:8000
  NetworthDOM   http://127.0.0.1:3000

Tabs start in dependency order: JWT, DB, Sync, DOM.
Each repo's `make dev` installs dependencies first (install or dev-install).

Usage:
  dev.sh [--clean] [--help]

Options:
  --clean   Run `make clean` before `make dev` in each tab
  --help    Print this help and exit
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

  require_terminal
  require_dir "$JWT_DIR" "NetworthJWT"
  require_dir "$DB_DIR" "NetworthDB"
  require_dir "$SYNC_DIR" "NetworthSync"
  require_dir "$DOM_DIR" "NetworthDOM"

  echo "[dev] opening one terminal window (JWT, DB, Sync, DOM tabs)"
  launch_dev_window

  echo "[dev] launched dev tabs under $WORKSPACE_ROOT"
  if [[ "$RUN_CLEAN" == true ]]; then
    echo "[dev] each tab runs: init_dev && make clean && make dev"
  else
    echo "[dev] each tab runs: init_dev && make dev"
  fi
}

main "$@"
