#!/usr/bin/env bash
# Set up hibernation on this machine: create a dedicated swapfile large
# enough to hold a hibernation image, label it for SELinux, register it in
# /etc/fstab, and point the kernel at it via resume=/resume_offset= kargs.
# Invoked by `ujust setup-hibernation`; takes an optional size in GiB
# (defaults to total RAM so a fully-dirty memory image always fits).
#
# This has to happen on the deployed machine, not at image build time: the
# swapfile lives under /var (per-machine, excluded from the bootc /etc
# merge), and the resume offset + filesystem UUID are unknowable until the
# file exists on this machine's disk.
set -euo pipefail

SWAP_DIR=/var/swap
SWAP_FILE=${SWAP_DIR}/swapfile

if [ "$(id -u)" -ne 0 ]; then
    echo "hibernation-setup: must run as root (use 'ujust setup-hibernation')" >&2
    exit 1
fi

if [ -f "${SWAP_FILE}" ]; then
    echo "hibernation-setup: ${SWAP_FILE} already exists - nothing to do."
    echo "Run 'ujust remove-hibernation' first to start over (e.g. with a different size)."
    exit 0
fi

# With Secure Boot enabled, the kernel's lockdown mode blocks hibernation
# outright (the resume image isn't signed, so restoring it would defeat
# boot verification). Warn but continue - the on-disk setup is still valid
# and starts working as soon as Secure Boot is turned off in firmware.
if grep -qE '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown 2>/dev/null; then
    echo "hibernation-setup: WARNING: kernel lockdown is active (Secure Boot?)." >&2
    echo "hibernation-setup: the kernel will refuse to hibernate until Secure Boot" >&2
    echo "hibernation-setup: is disabled in firmware. Setting up anyway." >&2
fi

# Default to total RAM, rounded up to a whole MiB.
mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
size_mib=$(( (mem_kib + 1023) / 1024 ))
if [ -n "${1:-}" ]; then
    if ! printf '%s' "$1" | grep -qE '^[0-9]+$'; then
        echo "hibernation-setup: size must be a whole number of GiB, got '$1'" >&2
        exit 1
    fi
    size_mib=$(( $1 * 1024 ))
fi

fstype=$(findmnt -no FSTYPE --target /var)
case "${fstype}" in
btrfs)
    # A btrfs swapfile must be NOCOW and must never be snapshotted, so it
    # gets its own subvolume (snapshots of /var won't descend into it).
    # `btrfs filesystem mkswapfile` handles NOCOW, permissions, and mkswap.
    if ! btrfs subvolume show "${SWAP_DIR}" >/dev/null 2>&1; then
        btrfs subvolume create "${SWAP_DIR}"
    fi
    btrfs filesystem mkswapfile --size "${size_mib}M" "${SWAP_FILE}"
    resume_offset=$(btrfs inspect-internal map-swapfile -r "${SWAP_FILE}")
    ;;
ext4|xfs)
    mkdir -p "${SWAP_DIR}"
    fallocate -l "${size_mib}M" "${SWAP_FILE}"
    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    # Physical offset of the file's first extent, in filesystem blocks -
    # what the kernel needs to find the hibernation image inside the fs.
    resume_offset=$(filefrag -v "${SWAP_FILE}" \
        | awk '$1 == "0:" { gsub(/\.+$/, "", $4); print $4; exit }')
    ;;
*)
    echo "hibernation-setup: unsupported filesystem '${fstype}' on /var" >&2
    echo "hibernation-setup: only btrfs, ext4, and xfs are handled" >&2
    exit 1
    ;;
esac

if ! printf '%s' "${resume_offset}" | grep -qE '^[0-9]+$'; then
    echo "hibernation-setup: could not determine resume offset (got '${resume_offset}')" >&2
    exit 1
fi

# A freshly created btrfs subvolume carries no SELinux label (unlabeled_t),
# and SELinux denies systemd-logind search on unlabeled_t directories - so
# logind can't stat the swapfile and reports CanHibernate=no even though
# everything else is configured (observed live: avc denied { search }
# comm="systemd-logind" name="swap" tcontext=unlabeled_t). Relabel the
# directory before dealing with the file.
restorecon -R "${SWAP_DIR}"

# systemd activates fstab swap entries as init_t at boot, which SELinux only
# permits on files labeled swapfile_t (the default label under /var is
# var_t). Record the context persistently so a filesystem relabel keeps it.
if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t swapfile_t "${SWAP_FILE}" 2>/dev/null \
        || semanage fcontext -m -t swapfile_t "${SWAP_FILE}"
    restorecon "${SWAP_FILE}"
else
    chcon -t swapfile_t "${SWAP_FILE}" || true
fi

if ! grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
    # Default (negative) priority keeps the zram device preferred for
    # everyday swapping; this file exists to receive the hibernation image.
    echo "${SWAP_FILE} none swap defaults 0 0" >> /etc/fstab
fi
systemctl daemon-reload
swapon "${SWAP_FILE}"

# Tell the kernel where to look for a hibernation image at boot. Applies to
# the next deployment, hence the reboot requirement below.
fs_uuid=$(findmnt -no UUID --target /var)
if command -v rpm-ostree >/dev/null 2>&1; then
    rpm-ostree kargs \
        --append-if-missing="resume=UUID=${fs_uuid}" \
        --append-if-missing="resume_offset=${resume_offset}"
elif command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL \
        --remove-args="resume resume_offset" \
        --args="resume=UUID=${fs_uuid} resume_offset=${resume_offset}"
else
    echo "hibernation-setup: neither rpm-ostree nor grubby found;" >&2
    echo "hibernation-setup: set resume=UUID=${fs_uuid} resume_offset=${resume_offset} manually." >&2
    exit 1
fi

echo
echo "hibernation-setup: done."
echo "  swapfile:      ${SWAP_FILE} ($(( size_mib / 1024 )) GiB, ${fstype})"
echo "  resume device: UUID=${fs_uuid}"
echo "  resume offset: ${resume_offset}"
echo
echo "Reboot to apply the new kernel arguments, then hibernate with"
echo "'systemctl hibernate' (or enable 'ujust toggle-suspend-then-hibernate')."
