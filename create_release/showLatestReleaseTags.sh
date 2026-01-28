#!/usr/bin/env bash

DEFAULT_CONFIG="createReleaseConfig.json"
DEFAULT_RELEASE_TYPE="RC"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [config.json] [release_type]

Description:
  Scans git repositories listed in a JSON config file and prints either the
  release tag or the highest release candidate tag (-rcX), along with
  the tag creation date and associated commit hash.

Arguments:
  config.json     Optional. Path to JSON config file.
                  Default: ${DEFAULT_CONFIG}
  release_type    Optional. "RC" (default) or "Official".
                  RC       → use the release tag if skip is true otherwise the highest release candidate tag (-rcX)
                  Official → only get release tag, ignore skip

Options:
  -h, --help      Show this help message and exit.

Tag behavior (RC only):
  skip = true      → use <release> tag
  skip = false     → use highest <release>-rc<number> tag
EOF
}

# Help option
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
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

# Table header
printf "\n%-25s | %-25s | %-20s | %-40s\n" \
       "Repository" "Tag" "Tag Date" "Commit"
printf "%-25s-+-%-25s-+-%-20s-+-%-40s\n" \
       "-------------------------" \
       "-------------------------" \
       "--------------------" \
       "----------------------------------------"

jq -c '.[]' "$CONFIG_FILE" | while read -r entry; do
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

    cd "$repo_dir" || continue

    tag=""
    tag_date="-"
    commit_hash="-"

    if [[ "$RELEASE_TYPE" == "Official" ]]; then
        # Always get release tag
        if git rev-parse -q --verify "refs/tags/${release}" >/dev/null; then
            tag="$release"
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
            highest_rc=$(git tag \
                | grep "^${release}-rc[0-9]\+$" \
                | sed "s/^${release}-rc//" \
                | sort -n \
                | tail -1)

            if [[ -n "$highest_rc" ]]; then
                tag="${release}-rc${highest_rc}"
            else
                tag="(none)"
            fi
        fi
    fi

    if [[ "$tag" != "(none)" && "$tag" != "(not found)" ]]; then
        # Annotated tag date (ISO, no timezone)
        tag_date=$(git for-each-ref \
            --format='%(taggerdate:iso8601-strict)' "refs/tags/${tag}")

        # Fallback for lightweight tags → commit date
        if [[ -z "$tag_date" ]]; then
            tag_date=$(git show -s --format=%cd --date=format:'%Y-%m-%d %H:%M:%S' "$tag")
        else
            # Strip timezone from annotated tag date
            tag_date="${tag_date%+*}"
            tag_date="${tag_date%Z}"
        fi

        commit_hash=$(git rev-list -n 1 "$tag")
    fi

    printf "%-25s | %-25s | %-20s | %-40s\n" \
           "$repo_name" "$tag" "$tag_date" "$commit_hash"
done
