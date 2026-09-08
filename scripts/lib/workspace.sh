#!/usr/bin/env bash
# Resolve financial-footprints workspace paths (strict NetworthJWT sibling required).
# Source from scripts/*.sh:     source "$SCRIPT_DIR/lib/workspace.sh"
# Source from scripts/tests/*: source "$SCRIPT_DIR/../lib/workspace.sh"

if [[ -n "${WORKSPACE_ROOT:-}" && -n "${README_REPO_ROOT:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_WORKSPACE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
README_REPO_ROOT="$(cd "$_WORKSPACE_LIB_DIR/../.." && pwd -P)"

if [[ -d "$README_REPO_ROOT/../NetworthJWT" ]]; then
  WORKSPACE_ROOT="$(cd "$README_REPO_ROOT/.." && pwd -P)"
else
  echo "error: NetworthJWT not found next to the workspace root" >&2
  echo "Clone sibling repos under financial-footprints/ and symlink README/scripts." >&2
  return 1 2>/dev/null || exit 1
fi

JWT_DIR="$WORKSPACE_ROOT/NetworthJWT"
