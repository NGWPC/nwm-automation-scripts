#!/usr/bin/env bash
set -euo pipefail

# Updates the build ref lines in the ngencerf-server .env-override file on a
# PW cluster controller. These refs control which branches the on-cluster
# server build clones for its source dependencies.
#
# The update is atomic: all changes are written to a temp file in the same
# directory and swapped in with a single rename, so a concurrent reader or a
# second run of this script never sees a half-written file.

DEFAULT_ENV_FILE="/ngencerf-app/ngencerf-server/cerfServer/.env-override"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [-f FILE] [--all REF] [--data-assimilation REF] [--ewts REF] [--msw-mgr REF] [--ngen REF] [--ngen-forcing REF]

Updates the build ref lines in the ngencerf-server .env-override file:
  DATA_ASSIMILATION_REF, EWTS_REF, MSW_MGR_REF, NGEN_REF, NGEN_FORCING_REF

A ref can be a git branch, a git tag, or a full commit SHA (never a short SHA).

Options:
  -f, --file FILE             file to edit (default: $DEFAULT_ENV_FILE)
      --all REF               set all five refs to REF
      --data-assimilation REF set DATA_ASSIMILATION_REF
      --ewts REF              set EWTS_REF
      --msw-mgr REF           set MSW_MGR_REF
      --ngen REF              set NGEN_REF
      --ngen-forcing REF      set NGEN_FORCING_REF
  -h, --help                  show this help

Examples:
  $(basename "$0") --all development-pw
  $(basename "$0") --ngen 3.1.2.2.0 --ngen-forcing 3.1.2.2.0
USAGE
}

ENV_FILE="$DEFAULT_ENV_FILE"
DATA_ASSIMILATION=""
EWTS=""
MSW_MGR=""
NGEN=""
NGEN_FORCING=""

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) ENV_FILE="${2:?missing value for $1}"; shift 2 ;;
    --all)
      DATA_ASSIMILATION="${2:?missing value for $1}"
      EWTS="$2"
      MSW_MGR="$2"
      NGEN="$2"
      NGEN_FORCING="$2"
      shift 2 ;;
    --data-assimilation) DATA_ASSIMILATION="${2:?missing value for $1}"; shift 2 ;;
    --ewts) EWTS="${2:?missing value for $1}"; shift 2 ;;
    --msw-mgr) MSW_MGR="${2:?missing value for $1}"; shift 2 ;;
    --ngen) NGEN="${2:?missing value for $1}"; shift 2 ;;
    --ngen-forcing) NGEN_FORCING="${2:?missing value for $1}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

if [ -z "${DATA_ASSIMILATION}${EWTS}${MSW_MGR}${NGEN}${NGEN_FORCING}" ]; then
  echo "error: no refs given" >&2
  usage
  exit 1
fi

# Build the fully updated content in a temp file next to the target, then swap
# it in with one atomic rename. Requested vars missing from the file are
# appended at the end (with a warning on stderr).
tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

awk \
  -v da="$DATA_ASSIMILATION" \
  -v ewts="$EWTS" \
  -v msw="$MSW_MGR" \
  -v ngen="$NGEN" \
  -v forcing="$NGEN_FORCING" \
  '
  index($0, "DATA_ASSIMILATION_REF=") == 1 && da != ""      { print "DATA_ASSIMILATION_REF=" da; seen_da = 1; next }
  index($0, "EWTS_REF=") == 1 && ewts != ""                 { print "EWTS_REF=" ewts; seen_ewts = 1; next }
  index($0, "MSW_MGR_REF=") == 1 && msw != ""               { print "MSW_MGR_REF=" msw; seen_msw = 1; next }
  index($0, "NGEN_REF=") == 1 && ngen != ""                 { print "NGEN_REF=" ngen; seen_ngen = 1; next }
  index($0, "NGEN_FORCING_REF=") == 1 && forcing != ""      { print "NGEN_FORCING_REF=" forcing; seen_forcing = 1; next }
  { print }
  END {
    if (da != "" && !seen_da)           { print "DATA_ASSIMILATION_REF=" da; missing = missing " DATA_ASSIMILATION_REF" }
    if (ewts != "" && !seen_ewts)       { print "EWTS_REF=" ewts; missing = missing " EWTS_REF" }
    if (msw != "" && !seen_msw)         { print "MSW_MGR_REF=" msw; missing = missing " MSW_MGR_REF" }
    if (ngen != "" && !seen_ngen)       { print "NGEN_REF=" ngen; missing = missing " NGEN_REF" }
    if (forcing != "" && !seen_forcing) { print "NGEN_FORCING_REF=" forcing; missing = missing " NGEN_FORCING_REF" }
    if (missing != "") print "warning: not found in file, appended:" missing > "/dev/stderr"
  }' "$ENV_FILE" > "$tmp"

# keep the target file permissions on the replacement
if ! chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null; then
  chmod "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo 644)" "$tmp"
fi

mv -f "$tmp" "$ENV_FILE"
trap - EXIT

echo "current build refs in $ENV_FILE:"
grep -E '^(DATA_ASSIMILATION|EWTS|MSW_MGR|NGEN|NGEN_FORCING)_REF=' "$ENV_FILE"
