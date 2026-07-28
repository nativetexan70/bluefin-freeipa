## Custom ujust recipes shipped by bluefin-freeipa.
##
## Files placed at /usr/share/ublue-os/just/*.just are auto-imported by the
## base Bluefin image's top-level Justfile, making these recipes available
## via `ujust <recipe>` on the deployed system.

# Configure hibernation (creates/reuses a swapfile, sets resume kernel args)
[group('System')]
configure-hibernation size="":
    #!/usr/bin/bash
    set -oue pipefail

    SWAP_DIR="/var/swap"
    SWAP_FILE="${SWAP_DIR}/swapfile"

    if [[ "${UID}" -ne 0 ]]; then
        echo "This recipe needs root privileges; re-running with sudo..."
        exec sudo ujust configure-hibernation "{{ size }}"
    fi

    mkdir -p "${SWAP_DIR}"
    chmod 0700 "${SWAP_DIR}"

    if [[ -f "${SWAP_FILE}" ]]; then
        echo "Existing swapfile found at ${SWAP_FILE}; reusing it."
    else
        SIZE_GB="{{ size }}"
        if [[ -z "${SIZE_GB}" ]]; then
            # Default to the amount of installed RAM, rounded up to the
            # nearest GiB, which is sufficient for hibernation on most systems.
            MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
            SIZE_GB="$(( (MEM_KB + 1024 * 1024 - 1) / (1024 * 1024) ))"
        fi
        echo "Creating a ${SIZE_GB}GiB swapfile at ${SWAP_FILE}..."

        FSTYPE="$(findmnt -no FSTYPE -T "${SWAP_DIR}")"
        if [[ "${FSTYPE}" == "btrfs" ]] && btrfs filesystem mkswapfile --help &>/dev/null; then
            btrfs filesystem mkswapfile --size "${SIZE_GB}g" --uuid clear "${SWAP_FILE}"
        else
            if [[ "${FSTYPE}" == "btrfs" ]]; then
                truncate -s 0 "${SWAP_FILE}"
                chattr +C "${SWAP_FILE}" || true
            fi
            fallocate -l "${SIZE_GB}GiB" "${SWAP_FILE}" || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="$(( SIZE_GB * 1024 ))"
            chmod 0600 "${SWAP_FILE}"
            mkswap "${SWAP_FILE}"
        fi
    fi

    chmod 0600 "${SWAP_FILE}"

    if ! grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap defaults 0 0" >> /etc/fstab
    fi

    swapon "${SWAP_FILE}" 2>/dev/null || swapon --all

    FSTYPE="$(findmnt -no FSTYPE -T "${SWAP_DIR}")"
    if [[ "${FSTYPE}" == "btrfs" ]]; then
        RESUME_OFFSET="$(btrfs inspect-internal map-swapfile -r "${SWAP_FILE}")"
    else
        RESUME_OFFSET="$(filefrag -v "${SWAP_FILE}" | awk '$1=="0:" {n=split($4,a,"\\.\\."); print a[1]; exit}')"
    fi
    RESUME_UUID="$(findmnt -no UUID -T "${SWAP_DIR}")"

    if [[ -z "${RESUME_OFFSET}" || -z "${RESUME_UUID}" ]]; then
        echo "Failed to determine resume_offset/UUID for ${SWAP_FILE}." >&2
        exit 1
    fi

    echo "Setting resume=UUID=${RESUME_UUID} resume_offset=${RESUME_OFFSET} kernel args..."
    if command -v rpm-ostree &>/dev/null; then
        rpm-ostree kargs \
            --delete-if-present="resume=" \
            --delete-if-present="resume_offset=" \
            --append="resume=UUID=${RESUME_UUID}" \
            --append="resume_offset=${RESUME_OFFSET}"
        echo "Kernel arguments staged. Reboot to apply and enable hibernation."
    elif command -v grubby &>/dev/null; then
        grubby --update-kernel=ALL \
            --remove-args="resume resume_offset" \
            --args="resume=UUID=${RESUME_UUID} resume_offset=${RESUME_OFFSET}"
        echo "Kernel arguments updated via grubby. Reboot to apply and enable hibernation."
    else
        echo "Neither rpm-ostree nor grubby found; set resume=UUID=${RESUME_UUID} resume_offset=${RESUME_OFFSET} manually." >&2
        exit 1
    fi
