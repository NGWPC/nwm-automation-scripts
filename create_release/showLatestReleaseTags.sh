#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG="createReleaseConfig.json"
DEFAULT_RELEASE_TYPE="RC"

# Track latest tag across all scanned repos
LATEST_TAG_DATE=""
LATEST_TAG_REPO=""
LATEST_TAG_NAME=""

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [config.json] [release_type]

Description:
  Scans git repositories listed in a JSON config file and prints either the
  release tag or the highest release candidate tag (-rcX), along with
  the tag creation date and associated commit hash.

  Also prints (at the end) the latest tag date found across all scanned repos.

Arguments:
  config.json     Optional. Path to JSON config file.
                  Default: ${DEFAULT_CONFIG}
  release_type    Optional. "RC" (default) or "Official".
                  RC       → use the release tag if skip is true otherwise the highest release candidate tag (-rcX)
                  Official → get the highest official release/hotfix tag that matches the configured release prefix

Options:
  -h, --help      Show this help message and exit.

Tag behavior:
  RC:
    skip = true    → use <release> tag
    skip = false   → use highest <release>-rc<number> tag

  Official:
    Uses the configured release as the base release and finds the highest
    matching final/hotfix tag by the last numeric component.

    Example:
      release = 3.1.2.0.0
      tags    = 3.1.2.0.0, 3.1.2.0.1, 3.1.2.0.2
      result  = 3.1.2.0.2

Minimal example JSON config:

[
    {
        "repo_directory": "~/ngwpc/repositories/noah-owp-modular",
        "release": "3.1.2.0.0"
    }
]

Notes:
- 'repo_directory' supports '~' for the home directory.
- 'skip' is optional. Defaults to false when release_type is RC.
EOF
}

# Help option
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

CONFIG_FILE="${1:-$DEFAULT_CONFIG}"
RELEASE_TYPE="${2:-$DEFAULT_RELEASE_TYPE}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    echo
    usage
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq is required but not installed."
    exit 1
fi

# Table header
printf "\n%-25s | %-25s | %-20s | %-40s\n" \
       "Repository" "Tag" "Tag Date" "Commit"
printf "%-25s-+-%-25s-+-%-20s-+-%-40s\n" \
       "-------------------------" \
       "-------------------------" \
       "--------------------" \
       "----------------------------------------"

# IMPORTANT: Use process substitution to avoid subshell so we can print summary at the end
while IFS= read -r entry; do
    repo_dir=$(echo "$entry" | jq -r '.repo_directory')
    release=$(echo "$entry" | jq -r '.release')
    skip=$(echo "$entry" | jq -r '.skip // false')

    repo_dir="${repo_dir/#\~/$HOME}"
    repo_name=$(basename "$repo_dir")

    if [[ ! -d "$repo_dir/.git" ]]; then
        printf "%-25s | %-25s | %-20s | %-40s\n" \
               "$repo_name" "NOT A GIT REPO" "-" "-"
        continue
    fi

    pushd "$repo_dir" >/dev/null

    # Update remote refs and tags
    git fetch --all --tags --prune --quiet

    # --- NEW: Track latest tag in this repo (any tag), for end-of-run summary ---
    # iso-strict compares cleanly as a string (YYYY-MM-DDTHH:MM:SS±HH:MM)
    latest_tag_line="$(
        git for-each-ref \
            --sort=-creatordate \
            --format='%(creatordate:iso-strict)|%(refname:short)' \
            refs/tags 2>/dev/null | head -n 1 || true
    )"

    if [[ -n "$latest_tag_line" ]]; then
        repo_latest_date="${latest_tag_line%%|*}"
        repo_latest_tag="${latest_tag_line#*|}"

        if [[ -z "$LATEST_TAG_DATE" || "$repo_latest_date" > "$LATEST_TAG_DATE" ]]; then
            LATEST_TAG_DATE="$repo_latest_date"
            LATEST_TAG_REPO="$repo_name"
            LATEST_TAG_NAME="$repo_latest_tag"
        fi
    fi
    # --------------------------------------------------------------------------

    tag=""
    tag_date="-"
    commit_hash="-"

    if [[ "$RELEASE_TYPE" == "Official" ]]; then
        # Official release behavior:
        # Treat the configured release as the base release and find the highest
        # matching final/hotfix tag by the last numeric component.
        #
        # Example:
        #   release = 3.1.2.0.0
        #   tags    = 3.1.2.0.0, 3.1.2.0.1, 3.1.2.0.2
        #   result  = 3.1.2.0.2
        release_prefix="${release%.*}"

        latest_official="$(
            git tag --list "${release_prefix}.*"               | awk -F. -v prefix="$release_prefix" '
                    BEGIN {
                        prefix_count = split(prefix, prefix_parts, ".")
                    }
                    NF == prefix_count + 1 {
                        matches_prefix = 1
                        for (i = 1; i <= prefix_count; i++) {
                            if ($i != prefix_parts[i]) {
                                matches_prefix = 0
                                break
                            }
                        }

                        patch = $(prefix_count + 1)
                        if (matches_prefix && patch ~ /^[0-9]+$/) {
                            printf "%d|%s\n", patch, $0
                        }
                    }
                '               | sort -t'|' -k1,1n               | tail -1               | cut -d'|' -f2-               || true
        )"

        if [[ -n "$latest_official" ]]; then
            tag="$latest_official"
        else
            tag="(not found)"
        fi
    else
        # RC behavior
        if [[ "$skip" == "true" ]]; then
            # Final release tag
            if git rev-parse -q --verify "refs/tags/${release}" >/dev/null; then
                tag="$release"
            else
                tag="(not found)"
            fi
        else
            # Highest RC tag
            highest_rc=$(
                git tag \
                  | grep "^${release}-rc[0-9]\+$" \
                  | sed "s/^${release}-rc//" \
                  | sort -n \
                  | tail -1 \
                  || true
            )

            if [[ -n "$highest_rc" ]]; then
                tag="${release}-rc${highest_rc}"
            else
                tag="(none)"
            fi
        fi
    fi

    if [[ "$tag" != "(none)" && "$tag" != "(not found)" ]]; then
        # Annotated tag date
        tag_date="$(git for-each-ref --format='%(taggerdate:iso8601-strict)' "refs/tags/${tag}" || true)"

        # Fallback for lightweight tags → commit date
        if [[ -z "$tag_date" ]]; then
            tag_date="$(git show -s --format=%cd --date=format:'%Y-%m-%d %H:%M:%S' "$tag" || true)"
        else
            # Strip timezone from annotated tag date (keep behavior you had)
            tag_date="${tag_date%+*}"
            tag_date="${tag_date%Z}"
        fi

        commit_hash="$(git rev-list -n 1 "$tag" || true)"
        [[ -n "$commit_hash" ]] || commit_hash="-"
    fi

    printf "%-25s | %-25s | %-20s | %-40s\n" \
           "$repo_name" "$tag" "$tag_date" "$commit_hash"

    popd >/dev/null
done < <(jq -c '.[]' "$CONFIG_FILE")

# --- NEW: Print latest tag date across all scanned repos ---
printf "\nLatest tag date (across scanned repos)\n"
printf "=============================================================\n"
if [[ -n "$LATEST_TAG_DATE" ]]; then
    printf "  %s | %s | %s\n" "$LATEST_TAG_DATE" "$LATEST_TAG_REPO" "$LATEST_TAG_NAME"
else
    printf "  (no tags found in scanned repositories)\n"
fi
