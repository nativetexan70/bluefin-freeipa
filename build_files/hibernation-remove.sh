#!/usr/bin/env bash
# Undo hibernation-setup.sh: deactivate and delete the swapfile, drop the
# fstab entry and SELinux context rule, remove the resume=/resume_offset=
# kernel arguments, and clear any suspend-then-hibernate drop-ins.
# Invoked by `ujust remove-hibernation`.
set -euo pipefail

SWAP_DIR=/var/swap
SWAP_FILE=${SWAP_DIR}/swapfile

if [ "$(id -u)" -ne 0 ]; then
    echo "hibernation-remove: must run as root (use 'ujust remove-hibernation')" >&2
    exit 1
fi

swapoff "${SWAP_FILE}" 2>/dev/null || true
sed -i "\|^${SWAP_FILE}[[:space:]]|d" /etc/fstab
systemctl daemon-reload

if command -v rpm-ostree >/dev/null 2>&1; then
    # Delete whatever resume kargs are actually present (exact-match delete,
    # so read them back rather than recomputing values that may have drifted).
    delete_args=()
    for karg in $(rpm-ostree kargs); do
        case "${karg}" in
        resume=*|resume_offset=*)
            delete_args+=("--delete-if-present=${karg}")
            ;;
        esac
    done
    if [ "${#delete_args[@]}" -gt 0 ]; then
        rpm-ostree kargs "${delete_args[@]}"
    fi
elif command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --remove-args="resume resume_offset"
fi

rm -f "${SWAP_FILE}"
if btrfs subvolume show "${SWAP_DIR}" >/dev/null 2>&1; then
    btrfs subvolume delete "${SWAP_DIR}"
else
    rmdir "${SWAP_DIR}" 2>/dev/null || true
fi

if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -d "${SWAP_FILE}" 2>/dev/null || true
fi

# suspend-then-hibernate is meaningless without a hibernation target.
rm -f /etc/systemd/logind.conf.d/50-suspend-then-hibernate.conf \
      /etc/systemd/sleep.conf.d/50-suspend-then-hibernate.conf

echo "hibernation-remove: done. Reboot to apply the kernel argument removal."
