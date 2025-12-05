#!/usr/bin/env bash
set -euo pipefail

# install dnf-plugins-core
sudo dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
sudo dnf config-manager --set-disabled cuda-rhel8-x86_64 || true
sudo dnf clean all && sudo dnf makecache

# install gh cli
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | sudo tee /etc/yum.repos.d/github-cli.repo
    sudo dnf -y install gh
fi

# install Docker
if ! command -v docker >/dev/null 2>&1; then
    if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# enable Docker on boot
sudo systemctl enable --now docker

# install mountpoint-s3
if ! command -v mount-s3 >/dev/null 2>&1; then
    sudo dnf -y install https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm
fi

# # call mount_s3_buckets.sh to mount S3 buckets
# SRC_MOUNT_SCRIPT="$(dirname "$0")/mount_s3_buckets.sh"
# if [ -r "$SRC_MOUNT_SCRIPT" ]; then
#     sudo "$SRC_MOUNT_SCRIPT"
# else
#     echo "warn: $SRC_MOUNT_SCRIPT not found or unreadable; skipping S3 bucket mounting" >&2
# fi

# install openmpi
sudo dnf -y install openmpi \
 && sudo dnf clean all \
 && sudo rm -rf /var/cache/dnf

# make bin visible for new shells (optional but convenient)
echo 'export PATH="/usr/lib64/openmpi/bin:$PATH"' | sudo tee /etc/profile.d/openmpi.sh >/dev/null
sudo chmod +x /etc/profile.d/openmpi.sh

# ensure libs are cached
echo "/usr/lib64/openmpi/lib" | sudo tee /etc/ld.so.conf.d/openmpi.conf >/dev/null
sudo ldconfig

# install python packages
if [ -n "${PY_PIP_PKGS:-}" ]; then
    sudo dnf -y install python3-pip
    sudo python3 -m pip install --upgrade pip
    sudo python3 -m pip install ${PY_PIP_PKGS}
fi

# ensure a sudoers drop-in exists that grants passwordless sudo to all users in the wheel group
if [ ! -f /etc/sudoers.d/99-wheel-nopw ]; then
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-wheel-nopw >/dev/null
    sudo chmod 440 /etc/sudoers.d/99-wheel-nopw
fi

# add users to docker and wheel groups
if [ -n "${ADD_USERS:-}" ]; then
    if getent group docker >/dev/null 2>&1; then
        for u in ${ADD_USERS}; do
            id -u "$u" >/dev/null 2>&1 && sudo usermod -aG docker "$u" || echo "warn: user $u not found"
        done
    else
        echo "warn: docker group not found; skipping docker memberships"
    fi
    for u in ${ADD_USERS}; do
        id -u "$u" >/dev/null 2>&1 && sudo usermod -aG wheel "$u" || echo "warn: user $u not found"
    done
fi

# add /ngencerf-app/ngencerf-server/cli/bin to all user's PATH
echo 'export PATH="/ngencerf-app/ngencerf-server/cli/bin:$PATH"' | sudo tee /etc/profile.d/ngencerf-cli.sh
sudo chmod +x /etc/profile.d/ngencerf-cli.sh

# add ngen CLI wrapper to /usr/local/bin/ngen from extract_ngen_cli.sh
SRC_NGEN_SCRIPT="$(dirname "$0")/extract_ngen_cli.sh"
if [ -r "$SRC_NGEN_SCRIPT" ]; then
    sudo install -m 0755 "$SRC_NGEN_SCRIPT" /usr/local/bin/ngen
else
    echo "warn: $SRC_NGEN_SCRIPT not found or unreadable; skipping /usr/local/bin/ngen installation" >&2
fi

# add ngencerf-server logrotate job to /etc/cron.d
# note: added root before the command, which is required for /etc/cron.d files
LOGROTATE_CONF="/ngencerf-app/ngencerf-server/logrotate-ngencerf.prod.conf"
CRON_FILE='/etc/cron.d/ngencerf-logrotate'
CRON_JOB="0 10,22 * * * root [ -f $LOGROTATE_CONF ] && /usr/sbin/logrotate -f $LOGROTATE_CONF"

echo "$CRON_JOB" | sudo tee "$CRON_FILE" > /dev/null
sudo chmod 0644 "$CRON_FILE"

# set permissions on the logrotate config if it exists
if [ -f "$LOGROTATE_CONF" ]; then
    sudo chown root:root "$LOGROTATE_CONF"
    sudo chmod 0644 "$LOGROTATE_CONF"
else
    echo "warn: $LOGROTATE_CONF not found; skipping permission fix."
fi

echo "cluster startup complete"
