#!/bin/bash

# ==============================================================================
# cleanup_cluster.sh
# ==============================================================================
#
# IMPORTANT: Run this script ONLY from the PW login node (the machine you land
# on when opening a fresh terminal on Parallel Works). NEVER run it from inside
# a cluster node.
#
# SUBCOMMANDS
# -----------
#
# --docker <repo:tag>
#   Delete a specific Docker image and its containers, then prune.
#
# --docker all
#   Delete all Docker images and associated data.
#
# --files --path <dir> --cutoff <YYYY-MM-DD> [--exclude <name,...>] [--dry-run]
#   Delete files in <dir> that are OLDER than <cutoff>.
#   "nginx-unprivileged.sif" is always excluded regardless of --exclude.
#   --exclude accepts a comma-separated list of filenames (no paths).
#   --dry-run prints what would be deleted without removing anything.
#   Without --dry-run, shows the file list and asks for confirmation before deleting.
#
#   Example:
#     cleanup_cluster.sh --files \
#       --path /ngencerf-app/singularity \
#       --cutoff 2026-02-04 \
#       --exclude "nginx-unprivileged.sif" \
#       --dry-run
#
# --dirs --path <dir> --targets <name,...> [--dry-run]
#   Delete specific subdirectories inside <dir>.
#   NEVER deletes directories that are currently active PW job sessions.
#   --targets accepts a comma-separated list of directory names (not full paths).
#   --dry-run prints what would be deleted without removing anything.
#   Without --dry-run, shows the directory list and asks for confirmation before deleting.
#
#   Example:
#     cleanup_cluster.sh --dirs \
#       --path /home/ngen-pw-user/pw/jobs/ngencerf \
#       --targets "00100,00101" \
#       --dry-run
#
# ==============================================================================

# Filename that must never be deleted under any circumstances
readonly ALWAYS_EXCLUDE="nginx-unprivileged.sif"

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

delete_docker_image() {
    local repo="$1"
    local tag="$2"
    local image="${repo}:${tag}"

    if [[ -z "$repo" || -z "$tag" ]]; then
        echo "Usage: delete_docker_image <repository> <tag>"
        return 1
    fi

    echo "Looking for containers using image: $image"

    local containers
    containers=$(docker ps -a --filter ancestor="$image" -q)

    if [[ -n "$containers" ]]; then
        echo "Stopping and removing containers:"
        echo "$containers"
        docker rm -f $containers
    else
        echo "No containers found using image"
    fi

    echo "Deleting image: $image"
    docker rmi "$image"

    echo "Cleaning up dangling images, volumes, and networks..."
    docker system prune -f --volumes

    echo "Done."
}

delete_all_docker_data() {
    echo "Stopping and removing all containers..."
    docker rm -f $(docker ps -aq) 2>/dev/null

    echo "Deleting all Docker images..."
    docker rmi -f $(docker images -q) 2>/dev/null

    echo "Pruning all unused data..."
    docker system prune -a -f --volumes

    echo "Done."
}

# ---------------------------------------------------------------------------
# --files subcommand
# ---------------------------------------------------------------------------

cmd_files() {
    local path="" cutoff="" exclude_arg="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)    path="$2";    shift 2 ;;
            --cutoff)  cutoff="$2";  shift 2 ;;
            --exclude) exclude_arg="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) echo "Unknown --files option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$path" || -z "$cutoff" ]]; then
        echo "Error: --files requires --path and --cutoff"
        echo "Usage: cleanup_cluster.sh --files --path <dir> --cutoff <YYYY-MM-DD> [--exclude <name,...>] [--dry-run]"
        exit 1
    fi

    if [[ ! -d "$path" ]]; then
        echo "Error: path does not exist: $path"
        exit 1
    fi

    # Validate cutoff format
    if ! date -d "$cutoff" &>/dev/null; then
        echo "Error: invalid cutoff date '$cutoff'. Use YYYY-MM-DD format."
        exit 1
    fi

    # Build exclusion set (always include the hard-coded guard)
    declare -A exclude_set
    exclude_set["$ALWAYS_EXCLUDE"]=1
    if [[ -n "$exclude_arg" ]]; then
        IFS=',' read -ra parts <<< "$exclude_arg"
        for part in "${parts[@]}"; do
            part="${part// /}"   # strip any accidental spaces
            [[ -n "$part" ]] && exclude_set["$part"]=1
        done
    fi

    echo "=== File cleanup ==="
    echo "  Path    : $path"
    echo "  Cutoff  : files older than $cutoff will be deleted"
    echo "  Excluded: ${!exclude_set[*]}"
    if $dry_run; then
        echo "  Mode    : DRY RUN — nothing will be deleted"
    else
        echo "  Mode    : LIVE — will prompt for confirmation before deleting"
    fi
    echo ""

    # Collect eligible files (separated from skipped ones)
    local -a to_delete=()
    while IFS= read -r -d '' file; do
        local name
        name="$(basename "$file")"
        if [[ -n "${exclude_set[$name]:-}" ]]; then
            echo "  [SKIP]   $file  (excluded)"
        else
            to_delete+=("$file")
        fi
    done < <(find "$path" -maxdepth 1 -type f ! -newermt "$cutoff" -print0)

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        echo "  No eligible files found."
        echo ""
        echo "Nothing to delete."
        return 0
    fi

    echo ""
    echo "  Files to be deleted (${#to_delete[@]}):"
    for file in "${to_delete[@]}"; do
        echo "    $file"
    done
    echo ""

    if $dry_run; then
        echo "Dry run complete. No files were deleted."
        return 0
    fi

    read -r -p "Proceed with deleting the ${#to_delete[@]} file(s) listed above? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted. No files were deleted."
        return 0
    fi

    echo ""
    for file in "${to_delete[@]}"; do
        echo "  [DELETE]  $file"
        rm -f "$file"
    done
    echo ""
    echo "File cleanup complete."
}

# ---------------------------------------------------------------------------
# --dirs subcommand
# ---------------------------------------------------------------------------

cmd_dirs() {
    local path="" targets_arg="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path)    path="$2";    shift 2 ;;
            --targets) targets_arg="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) echo "Unknown --dirs option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$path" || -z "$targets_arg" ]]; then
        echo "Error: --dirs requires --path and --targets"
        echo "Usage: cleanup_cluster.sh --dirs --path <dir> --targets <name,...> [--dry-run]"
        exit 1
    fi

    if [[ ! -d "$path" ]]; then
        echo "Error: path does not exist: $path"
        exit 1
    fi

    IFS=',' read -ra targets <<< "$targets_arg"

    echo "=== Directory cleanup ==="
    echo "  Path     : $path"
    echo "  Targets  : ${targets[*]}"
    if $dry_run; then
        echo "  Mode     : DRY RUN — nothing will be deleted"
    else
        echo "  Mode     : LIVE — will prompt for confirmation before deleting"
    fi
    echo ""
    echo "  !! IMPORTANT: Only delete directories you have verified are NOT active"
    echo "  !! in the PW Sessions tab. Active job directories must not be removed."
    echo ""

    # Collect directories that actually exist
    local -a to_delete=()
    for target in "${targets[@]}"; do
        target="${target// /}"   # strip accidental spaces
        [[ -z "$target" ]] && continue

        local full_path="${path}/${target}"

        if [[ ! -d "$full_path" ]]; then
            echo "  [SKIP]   $full_path  (not found)"
        else
            to_delete+=("$full_path")
        fi
    done

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        echo "  No target directories found."
        echo ""
        echo "Nothing to delete."
        return 0
    fi

    echo ""
    echo "  Directories to be deleted (${#to_delete[@]}):"
    for dir in "${to_delete[@]}"; do
        echo "    $dir"
    done
    echo ""

    if $dry_run; then
        echo "Dry run complete. No directories were deleted."
        return 0
    fi

    echo "  Have you confirmed these directories are NOT active in the PW Sessions tab?"
    read -r -p "  Proceed with deleting the ${#to_delete[@]} director(y/ies) listed above? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted. No directories were deleted."
        return 0
    fi

    echo ""
    for dir in "${to_delete[@]}"; do
        echo "  [DELETE]  $dir"
        rm -rf "$dir"
    done
    echo ""
    echo "Directory cleanup complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage:
  cleanup_cluster.sh --docker <repo:tag>        Delete a specific Docker image
  cleanup_cluster.sh --docker all               Delete all Docker images and data

  cleanup_cluster.sh --files \\
    --path <dir> \\
    --cutoff <YYYY-MM-DD> \\
    [--exclude <name,...>] \\
    [--dry-run]

  cleanup_cluster.sh --dirs \\
    --path <dir> \\
    --targets <name,...> \\
    [--dry-run]

NOTE: Run only from the PW login node, never from inside a cluster.
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    case "$1" in
        --docker)
            shift
            local docker_arg="$1"
            shift
            if [[ "$docker_arg" == "all" ]]; then
                delete_all_docker_data
            else
                local repo="${docker_arg%%:*}"
                local tag="${docker_arg##*:}"
                if [[ "$repo" == "$tag" ]]; then
                    echo "Error: invalid image format. Use repo:tag"
                    exit 1
                fi
                delete_docker_image "$repo" "$tag"
            fi
            ;;
        --files)
            shift
            cmd_files "$@"
            ;;
        --dirs)
            shift
            cmd_dirs "$@"
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown subcommand: $1"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
