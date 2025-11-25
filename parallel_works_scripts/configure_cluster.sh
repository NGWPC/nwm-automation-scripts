#!/bin/bash

NGENCERF_APP=/ngencerf-app
REPOS=(
    "ngencerf-ui"
    "ngencerf-server"
    "ngencerf-docker"
    "ngen"
    "nwm-cal-mgr"
    "ngen-forcing"
    "nwm-fcst-mgr"
    "nwm-verf"
)

# ------------------------------------------------------------------------------
# Help Function
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

This script automates the setup and configuration of an NGENCERF cluster environment.
It performs the following tasks:
  1. Clones required repositories from GitHub (NGWPC organization)
  2. Sets up configuration files for ngencerf-server
  3. Loads static data from AWS S3
  4. Builds Singularity containers for all services
  5. Sets up nginx container

This is an interactive script that will prompt you to:
  - Edit configuration files (database credentials, paths, tags)
  - Provide temporary AWS credentials for data download

Prerequisites:
  - Git installed and configured
  - AWS CLI installed
  - Docker and Singularity/Apptainer installed
  - Access to NGWPC GitHub repositories
  - AWS credentials with access to ngwpc-dev S3 bucket
  - Sudo privileges for directory creation

Options:
  -h, --help    Display this help message and exit

Repositories cloned:
EOF
    for repo in "${REPOS[@]}"; do
        echo "  - $repo"
    done

    cat << EOF

Target directory: $NGENCERF_APP

Examples:
  $(basename "$0")          Run the full cluster configuration
  $(basename "$0") -h       Display this help message

EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Helper: Prompt user with a message, then open the file in an editor
# ------------------------------------------------------------------------------
edit_file_with_message() {
    local file="$1"
    local message="$2"

    echo
    echo "================================================================================"
    echo "$message"
    echo
    echo "When you're done, save and exit your editor (e.g., :wq in vim)."
    echo "================================================================================"
    echo

    read -p "Press ENTER to open $file..." _

    # Fallback chain: $EDITOR -> vim -> vi
    if [[ -n "$EDITOR" ]]; then
        "$EDITOR" "$file"
    elif command -v vim >/dev/null 2>&1; then
        vim "$file"
    else
        vi "$file"
    fi
}

# ------------------------------------------------------------------------------
# Parse Command Line Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Use -h or --help for usage information."
            exit 1
            ;;
    esac
    shift
done

cd $NGENCERF_APP

# ------------------------------------------------------------------------------
# Clone Repositories
# ------------------------------------------------------------------------------
echo "Cloning repos..."
echo
for repo in "${REPOS[@]}"; do
    if [[ ! -d "$repo" ]]; then
        if [[ "$repo" == "ngen" ]]; then
            git clone -b development --recurse-submodules https://github.com/NGWPC/$repo.git
            # initialize and update submodules to correct commit
            git submodule update --init --recursive
        else
            git clone -b development https://github.com/NGWPC/$repo.git
        fi
    else
        echo "$repo already exists, skipping clone."
    fi
    echo
done

# ------------------------------------------------------------------------------
# Configure ngencerf-server
# ------------------------------------------------------------------------------
cd ngencerf-server

# Only copy if override file doesn't exist
if [[ ! -f ngencerf_services.override.env ]]; then
    echo "Creating ngencerf_services.override.env from template..."
    cp ngencerf_services.env ngencerf_services.override.env
else
    echo "Override file already exists: ngencerf_services.override.env"
fi
echo

edit_file_with_message "ngencerf_services.override.env" \
    "Update database user, password, host and EDFS URL in this file."

edit_file_with_message ".env" \
    "Update paths and tags in this file."

# ------------------------------------------------------------------------------
# Load static data
# ------------------------------------------------------------------------------
echo "Loading static data directory..."

STATIC_DIR="$NGENCERF_APP/data/ngen-cal-data/ngen-static-files"
SOURCE_DIR="$NGENCERF_APP/nwm-cal-mgr/module_parameter_files"

if [[ -d "$STATIC_DIR" ]]; then
    echo "Static data directory already exists at $STATIC_DIR"
    echo "Skipping module_parameter_files copy and S3 sync."
else
    echo "Creating static data directory..."
    sudo mkdir -p "$STATIC_DIR"
    sudo chown -R $(whoami):pwuser $NGENCERF_APP/data/ngen-cal-data
    sudo chmod -R g+rwx $NGENCERF_APP/data/ngen-cal-data

    if [[ ! -d "$STATIC_DIR/module_parameter_files" ]]; then
        echo "Copying module_parameter_files directory from nwm-cal-mgr repo..."
        cp --archive "$SOURCE_DIR" "$STATIC_DIR/"
    else
        echo "Skipping copy: module_parameter_files already exists in $STATIC_DIR"
    fi

    edit_file_with_message "/tmp/aws.credentials" \
        "Paste export statements for your AWS credentials in this file.  These are temporary credentials to copy the static files"

    source /tmp/aws.credentials

    echo
    echo "Copying data from NGWPC data bucket..."
    aws s3 sync s3://ngwpc-dev/ngen-static-files "$STATIC_DIR/"
    rm -f /tmp/aws.credentials
fi

# ------------------------------------------------------------------------------
# Pull/build Docker images and build Singularity containers
# ------------------------------------------------------------------------------
echo
echo "Building Singularity containers..."
$NGENCERF_APP/nwm-automation-scripts/parallel_works_scripts/build_cluster.sh --build-type=development all

# ------------------------------------------------------------------------------
# Copy nginx-unprivileged.sif to singularity directory
# ------------------------------------------------------------------------------
echo
echo "Building nginx Singularity container if it doesn't exist..."
if [[ ! -f "$NGENCERF_APP/singularity/nginx-unprivileged.sif" ]]; then
    cd $NGENCERF_APP
    mkdir -p singularity
    git clone https://github.com/parallelworks/interactive_session.git
    cp interactive_session/downloads/jupyter/nginx-unprivileged.sif singularity/
    rm -rf interactive_session
else
    echo "nginx-unprivileged.sif already exists in $NGENCERF_APP/singularity/"
fi
