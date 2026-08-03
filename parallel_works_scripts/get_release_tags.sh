#!/usr/bin/env bash

# Loads the PW release deploy tags into the CURRENT shell session.
#
# Runs get_release_tags.py (same flags: --rc N, --pw, --json FILE, --suffix,
# --no-verify) and evals its "export VAR=TAG" output here, so the
# <REPO>_RELEASE_TAG environment variables land in the terminal session this
# file is sourced from. Prints what was set so it can be verified.
#
# Must be sourced, not executed (a normal run sets the variables in a
# throwaway subshell and they vanish when it exits):
#   source parallel_works_scripts/get_release_tags.sh
#   source parallel_works_scripts/get_release_tags.sh --rc 4
#
# No set -euo pipefail here: this file runs inside the operator's own shell,
# and those options would stick to their session.

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo "ERROR: no variables were set. Run this with source so they land in your current shell:" >&2
  echo "  source $0 $*" >&2
  exit 1
fi

_grt_exports="$(python3 "$(dirname "${BASH_SOURCE[0]}")/get_release_tags.py" "$@")" || {
  echo "ERROR: get_release_tags.py failed, no variables were set" >&2
  unset _grt_exports
  return 1
}

eval "${_grt_exports}"
echo "" >&2
echo "release tag variables set in this shell session:" >&2
echo "${_grt_exports}" | sed 's/^export /  /' >&2
unset _grt_exports
