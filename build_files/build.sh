#!/bin/bash

set -ouex pipefail

### Install packages

# All packages this image needs are installed in a single transaction
# rather than spread across several `dnf5 install` calls, each of which
# pays its own repo-metadata-load/depsolve/transaction-check overhead.
# Nothing between here and where these packages are used depends on a
# partially-installed state, so there's no ordering reason to split them.
#
# freeipa-client pulls in sssd, krb5-workstation, certmonger, and other
# required dependencies automatically.
#
# policycoreutils-python-utils provides semanage, used by
# `ujust setup-hibernation` to persistently label the hibernation swapfile
# swapfile_t (systemd's boot-time swapon is denied by SELinux on the
# default var_t label).
#
# alsa-sof-firmware/alsa-ucm are for Chromebook SoundWire/SOF audio
# support (see below); fedora-logos restores stock Fedora branding (see
# "Branding" below); zstd is the compressor the initramfs regeneration
# below asks dracut to use, listed explicitly rather than assumed present.
# --allowerasing is required for fedora-logos, which conflicts with
# generic-logos (the Bluefin base image's replacement for it) — it only
# erases packages that actually conflict, so it's safe to apply to the
# whole transaction rather than isolating it to just that one package.
dnf5 install -y --allowerasing \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir \
    policycoreutils-python-utils \
    alsa-sof-firmware \
    alsa-ucm \
    fedora-logos \
    zstd

### Preserve FreeIPA join state across bootc updates
#
# bootc performs a three-way /etc merge on update: it diffs old-image /etc
# vs new-image /etc and applies that delta to local /etc. Files that
# ipa-client-install creates and that are NOT shipped in this image are
# treated as local additions and are never touched by updates.
#
# Strategy: create the directory skeleton here so the paths exist at first
# boot, but deliberately ship NO config file content. ipa-client-install
# then owns those files entirely, and bootc will never overwrite them.

install -d -m 0755 /etc/ipa
install -d -m 0750 /etc/sssd/conf.d

# Ensure sssd runtime and cache directories survive across updates.
# These already live under /var which is mutable and preserved by bootc.
install -d -m 0711 /var/lib/sss/db
install -d -m 0755 /var/lib/sss/pipes/private
install -d -m 0755 /var/log/sssd

### Chromebook SoundWire/SOF audio support (e.g. Tiger Lake "Volteer" boards)
#
# Many recent Chromebooks — including Tiger Lake models such as Google's
# Volteer family (e.g. "Lindar"/"Lillipup") — drive audio entirely through
# Intel's SOF (Sound Open Firmware) DSP over SoundWire, with no
# conventional HD-Audio codec. Two separate things are required for the
# built-in speakers to work, or the desktop shows only a routeless "Dummy
# Output" sink:
#
#   1. The kernel must let SOF (dsp_driver=3) or auto-detection
#      (dsp_driver=0) claim the audio controller. Some distro images/
#      installers ship a modprobe.d override forcing the legacy HD-Audio
#      driver (dsp_driver=1), which prevents the SoundWire codec/amps from
#      ever being set up — no sound card is registered at all in that case
#      (not even at the kernel level). This image never ships such an
#      override, but remove one defensively in case a future base-image
#      layer introduces one.
rm -f /etc/modprobe.d/alsa-legacy.conf

#   2. Even once the card exists, WirePlumber/PipeWire import ALSA cards
#      through the ALSA UCM (Use Case Manager) database — a card with no
#      matching UCM profile only gets a routeless stereo-fallback node
#      ("Dummy Output"). Upstream alsa-ucm-conf does not cover every
#      Chromebook SOF card name (e.g. "sof-rt5682", used by Volteer boards
#      with an RT5682 headset codec and RT1011 speaker amps over
#      SoundWire). alsa-ucm-conf-cros is a community-maintained overlay of
#      UCM profiles for Chromebook SOF boards — it probes DMI
#      product_family and i2c modalias at runtime, so this one overlay
#      covers many Chromebook boards, not just Tiger Lake. alsa-sof-firmware
#      (the DSP firmware) and alsa-ucm (the Fedora package providing
#      /usr/share/alsa/ucm2 — not "alsa-ucm-conf") are installed in the
#      single combined transaction above; the overlay layers on top of the
#      upstream UCM2 tree that alsa-ucm installs.

# The repo's only/default branch is "standalone", not "main".
_ucm_cros_workdir="$(mktemp -d)"
curl -fsSL \
    https://github.com/WeirdTreeThing/alsa-ucm-conf-cros/archive/refs/heads/standalone.tar.gz \
    -o "${_ucm_cros_workdir}/alsa-ucm-conf-cros.tar.gz"
tar -xzf "${_ucm_cros_workdir}/alsa-ucm-conf-cros.tar.gz" \
    -C "${_ucm_cros_workdir}" --strip-components=1

# ucm2/ adds new card profiles (e.g. conf.d/sof-rt5682, codecs/rt1011,
# platforms/intel-sof) that don't exist upstream; overrides/ replaces
# upstream conf.d/<card> profiles that exist but are missing features, so
# both are installed under alsa-ucm's conf.d.
cp -a "${_ucm_cros_workdir}/ucm2/." /usr/share/alsa/ucm2/
cp -a "${_ucm_cros_workdir}/overrides/." /usr/share/alsa/ucm2/conf.d/

rm -rf "${_ucm_cros_workdir}"
unset _ucm_cros_workdir

### Ship custom ujust recipes
#
# Files placed at /usr/share/ublue-os/just/*.just are auto-imported by the
# base Bluefin image's top-level Justfile, exposing these recipes via
# `ujust <recipe>` on the deployed system.

install -Dm644 /ctx/60-custom.just \
    /usr/share/ublue-os/just/60-custom.just

### Hibernation setup/removal helper scripts
#
# The swapfile, resume offset, and filesystem UUID are all per-machine and
# unknowable at build time (the swapfile lives under /var, which is not part
# of the image), so the actual setup runs on the deployed machine via
# `ujust setup-hibernation` / `ujust remove-hibernation`. This just ships the
# scripts those recipes call.

install -Dm755 /ctx/hibernation-setup.sh \
    /usr/libexec/hibernation-setup.sh
install -Dm755 /ctx/hibernation-remove.sh \
    /usr/libexec/hibernation-remove.sh

# Keeps resume-from-hibernation support in any locally regenerated initramfs
# (the shipped initramfs is generic and already has it via dracut --regenerate-all
# below; this only matters if `rpm-ostree initramfs --enable` is used later).
install -Dm644 /ctx/95-hibernation-resume.conf \
    /usr/lib/dracut/dracut.conf.d/95-hibernation-resume.conf

# Ensures eMMC/SD host controller drivers are present in the initramfs so
# GRUB can boot the kernel on hardware whose root/boot filesystem lives on
# an mmcblk* device. See 96-mmc-storage.conf for details.
install -Dm644 /ctx/96-mmc-storage.conf \
    /usr/lib/dracut/dracut.conf.d/96-mmc-storage.conf

### Enable required system units

systemctl enable sssd
systemctl enable oddjobd
systemctl enable podman.socket

### Configure cosign image verification for bootc upgrades
#
# Without this, bootc pull shows "ostree-unverified-registry" because it has
# no policy telling it to verify signatures. Installing the public key and a
# sigstore policy turns every subsequent "bootc upgrade" into a verified pull
# against the cosign signature attached to the GHCR image.

install -Dm644 /ctx/cosign.pub \
    /etc/pki/containers/bluefin-freeipa.pub
install -Dm644 /ctx/policy.json \
    /etc/containers/policy.json
install -Dm644 /ctx/registries.d-personalcyber.yaml \
    /etc/containers/registries.d/ghcr.io-personalcyber.yaml

### Branding — replace Bluefin logos throughout
#
# Bluefin ships logo files in three places that are visible to users:
#
#   1. Plymouth boot watermark (/usr/share/plymouth/themes/spinner/watermark.png)
#      Restored to stock Fedora artwork (see below) rather than Universal
#      Blue branding, since it's the first graphic users see when booting.
#   2. GDM login screen logo  (/usr/share/pixmaps/fedora-gdm-logo.png)
#      and related pixmap files — Universal Blue branding
#   3. GNOME Shell Logo Menu  (/usr/share/icons/hicolor/scalable/actions/
#                               ublue-logo-symbolic.svg) — Universal Blue
#      branding
#
# The bgrt Plymouth theme only shows bgrt-fallback.png when no UEFI firmware
# logo is present. Switching to the spinner theme ensures the watermark is
# always displayed regardless of hardware.

# Plymouth — spinner theme watermark (shown on all hardware)
# Bluefin's base image installs generic-logos instead of fedora-logos for
# its own bird-branded packages/files. generic-logos Conflicts: fedora-logos
# (they both own the same paths), so it was erased in favor of fedora-logos
# by the combined --allowerasing install above, restoring the real Fedora
# artwork at that path, which is then copied onto the other two watermark
# targets so the same Fedora graphic is shown regardless of firmware BGRT
# logo presence or plymouth theme variant.
install -Dm644 /usr/share/plymouth/themes/spinner/watermark.png \
    /usr/share/plymouth/themes/spinner/bgrt-fallback.png
install -Dm644 /usr/share/plymouth/themes/spinner/watermark.png \
    /usr/share/plymouth/themes/spinner/silverblue-watermark.png
plymouth-set-default-theme spinner

# GDM login screen and system pixmaps (400x101 horizontal wordmark)
for _pixmap in fedora-gdm-logo.png fedora-logo.png fedora-logo-icon.png \
               fedora-logo-small.png fedora-logo-sprite.png \
               fedora_logo_med.png fedora_whitelogo_med.png \
               system-logo-white.png; do
    install -Dm644 /ctx/ublue-logo-gdm.png "/usr/share/pixmaps/${_pixmap}"
done
unset _pixmap

# GNOME Shell icon (Logo Menu extension + custom-command-list panel button)
install -Dm644 /ctx/ublue-logo-symbolic.svg \
    /usr/share/icons/hicolor/scalable/actions/ublue-logo-symbolic.svg
gtk-update-icon-cache --force /usr/share/icons/hicolor

# Logo Menu dconf override — use our SVG as the panel button icon.
# The Logo Menu extension reads icons from its own bundled Resources/ dir via
# menu-button-icon-image (integer index). Setting use-custom-icon=true with a
# custom-icon-path bypasses the index lookup and uses our file directly.
install -dm755 /etc/dconf/db/distro.d
cat > /etc/dconf/db/distro.d/06-ublue-logo-menu << 'DCONFEOF'
[org/gnome/shell/extensions/Logo-menu]
use-custom-icon=true
custom-icon-path='/usr/share/icons/hicolor/scalable/actions/ublue-logo-symbolic.svg'
symbolic-icon=true
DCONFEOF
dconf update

# Fastfetch terminal logo — replace Bluefin mascot with UBlue logo.
# Fastfetch uses bluefin.png as the primary image source on terminal open.
# The sixel and symbol variants require tooling unavailable at build time;
# remove them so fastfetch falls back to the PNG without errors.
install -Dm644 /ctx/ublue-logo.png \
    /usr/share/ublue-os/bluefin-logos/bluefin.png
rm -f /usr/share/ublue-os/bluefin-logos/sixels/bluefin
rm -f /usr/share/ublue-os/bluefin-logos/symbols/bluefin

# Anaconda installer sidebar logo — shown during ISO installs built via BIB.
# install -D creates the destination directory tree if it does not exist.
install -Dm644 /ctx/ublue-logo-gdm.png \
    /usr/share/anaconda/pixmaps/silverblue/sidebar-logo.png

# Bluefin help desktop entry — update name (entry is NoDisplay=true;
# only visible in default-app pickers for help:// URI schemes).
if [[ -f /usr/share/applications/bluefin-help.desktop ]]; then
    sed -i 's/^Name=.*/Name=Universal Blue Help/' \
        /usr/share/applications/bluefin-help.desktop
fi

# Rebuild the initramfs so the updated Plymouth assets and theme selection
# are baked into the deployed boot image.
#
# bootc requires the kernel and initramfs to live at
# /usr/lib/modules/<kver>/{vmlinuz,initramfs.img} — it synthesizes /boot for
# each deployment from that location and never reads /boot out of the
# container image itself. Plain `dracut --regenerate-all` writes to the
# legacy /boot/initramfs-<kver>.img path instead, which bootc silently
# ignores, so the shipped image ends up carrying the upstream Bluefin
# initramfs (and its bird-branded Plymouth watermark) unchanged even though
# /usr/share/plymouth was updated above. Regenerate explicitly at the path
# bootc actually reads, for every installed kernel.
#
# /root is a symlink to /var/roothome in this ostree-based image (like
# /home -> /var/home), and /var is only a build-time cache mount here, so
# the symlink target doesn't exist yet unless something has created it.
# dracut-install tries to snapshot /root while building the archive and
# fails outright if the symlink dangles ("dracut-install: ERROR:
# installing '/root'"), aborting the dracut run. Create the real target
# directory first so the symlink resolves.
mkdir -p /var/roothome
#
# --no-hostonly avoids hardware-specific probing that fails in a container.
# Each initramfs is built to a sibling temp file and only `mv`'d onto the
# real initramfs.img (atomic within the same filesystem) once it passes a
# sanity check, so a partial/interrupted dracut run can never leave a
# corrupt file at the path bootc boots from. _kver_count tracks how many
# kernels were actually (re)built: if /usr/lib/modules/* matches nothing,
# or matches only entries without a vmlinuz, the loop body never runs, the
# count stays 0, and the explicit check below fails the build instead of
# silently shipping an image with a stale or missing initramfs.
#
# --no-hostonly alone is not enough of a guarantee: it tells dracut not to
# prune modules based on *this build container's* hardware, but the actual
# module set it ends up including still comes from dracut's own defaults,
# which can vary across base-image/dracut-version bumps. A run that quietly
# omits the storage driver a deployed machine actually needs (e.g. nvme,
# ahci, virtio_blk) produces a file that is structurally perfect — non-empty,
# well past the size floor, and parses fine under lsinitrd — while still
# dropping the machine into the dracut emergency shell at boot, because it
# can never find/mount its root filesystem. That happened here: this loop's
# checks were purely structural and let exactly that kind of image through.
# Force the common storage/controller drivers explicitly so the generated
# initramfs's boot-critical coverage can't silently regress, then verify at
# least one of them actually landed in the archive before trusting it.
#
# --compress=zstd: dracut defaults to xz, which optimizes for ratio over
# speed and is the dominant cost of this loop (observed taking tens of
# seconds per kernel in CI). zstd compresses much faster for a modest
# size increase, and since bootc/ostree re-compresses the whole OCI layer
# on top of this anyway, the extra initramfs bytes aren't real waste.
_boot_drivers="nvme ahci sd_mod sr_mod virtio_blk virtio_scsi usb_storage"

# The "ostree" dracut module is what parses the `ostree=` kernel argument
# and runs ostree-prepare-root to bind the actual deployment onto /sysroot
# before switch-root. It is marked hostonly_only by dracut, so it is only
# auto-included when dracut detects it's running on an already-booted
# ostree host — --no-hostonly does NOT pull it in on its own, and this
# build runs inside a plain OCI container with no such host markers.
# Without it, /sysroot ends up as the raw physical filesystem instead of
# the composed deployment, and switch-root fails at boot with "does not
# seem to be an OS tree. os-release file is missing." Force it explicitly,
# the same way 95-hibernation-resume.conf force-adds "resume".
_boot_dracutmodules="ostree"

_kver_count=0
for _kver_dir in /usr/lib/modules/*; do
    _kver="$(basename "${_kver_dir}")"
    [[ -f "${_kver_dir}/vmlinuz" ]] || continue

    _tmp_initramfs="${_kver_dir}/initramfs.img.new"
    rm -f "${_tmp_initramfs}"
    dracut --no-hostonly --force --compress=zstd \
        --add-drivers "${_boot_drivers}" \
        --add-dracutmodules "${_boot_dracutmodules}" \
        "${_tmp_initramfs}" "${_kver}"

    # Verify before trusting: the file must exist and be non-empty, be
    # large enough that it can't be a truncated stub (a real initramfs
    # runs many MB), parse as a valid dracut archive, and actually contain
    # at least one storage driver capable of finding a root filesystem, plus
    # the ostree module's switch-root helper — structural validity alone
    # doesn't prove the machine can boot it, and a machine can pass every
    # other check here while still failing switch-root because the one
    # module that mounts the actual deployment onto /sysroot got dropped.
    #
    # Buffer lsinitrd's listing into a variable before grepping it, rather
    # than piping straight into grep -q: grep -q exits the instant it
    # finds a match, closing its end of the pipe while lsinitrd (backed by
    # cpio/zcat) is still writing the rest of a multi-hundred-MB listing —
    # the same SIGPIPE-under-pipefail failure documented above for the
    # fleetd release-tag lookup this script used to have. Capturing the
    # full output first means grep never reads from a live pipe.
    test -s "${_tmp_initramfs}"
    _size="$(stat -c%s "${_tmp_initramfs}")"
    ((_size > 1048576))
    _initramfs_listing="$(lsinitrd "${_tmp_initramfs}")"
    grep -qE "/(${_boot_drivers// /|})\.ko" <<<"${_initramfs_listing}"
    grep -q "ostree-prepare-root" <<<"${_initramfs_listing}"

    mv -f "${_tmp_initramfs}" "${_kver_dir}/initramfs.img"
    _kver_count=$((_kver_count + 1))
done
((_kver_count > 0))
unset _kver_dir _kver _tmp_initramfs _size _kver_count _boot_drivers _boot_dracutmodules _initramfs_listing

### Fix bootc-image-builder ISO manifest generation compatibility
#
# Repos inherited from the Bluefin base image may reference
# GPG keys via local file:// paths in /etc/pki/rpm-gpg/. BIB's anaconda-iso
# manifest generation extracts repo configs from the container image and runs
# dnf dependency resolution inside its own container, which has no access to
# those key files. Patching gpgcheck=0 alone is insufficient — dnf also
# enforces repo_gpgcheck (repomd.xml signature verification) and fails with
# "Signing key not found" when the gpgkey reference is absent.
#
# In a bootc image, packages are never updated via dnf; bootc upgrade pulls
# cosign-verified OCI images instead. These repos serve no purpose in the
# deployed system. Truncate any repo file that carries a local file:// gpgkey
# reference so BIB's manifest generation can proceed without error.
#
# Each directory is searched separately so find exits 0 when the directory
# exists, avoiding a pipefail abort if one of the directories is absent.
for _repo_dir in /etc/yum.repos.d /usr/lib/yum.repos.d; do
    [[ -d "$_repo_dir" ]] || continue
    find "$_repo_dir" -name '*.repo' | while IFS= read -r _repo_file; do
        grep -ql 'gpgkey=file://' "$_repo_file" 2>/dev/null || continue
        # Remove local file:// gpgkey lines and disable signature checking.
        # BIB's depsolve runs inside its own container and cannot access
        # file:// paths from the target image. In a bootc image, packages
        # are never updated via dnf; security comes from cosign-verified
        # OCI image pulls, so disabling repo GPG checks is safe here.
        sed -i \
            -e '/^gpgkey=file:/d' \
            -e 's/^gpgcheck=.*/gpgcheck=0/' \
            -e 's/^repo_gpgcheck=.*/repo_gpgcheck=0/' \
            "$_repo_file"
        grep -q '^repo_gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a repo_gpgcheck=0' "$_repo_file"
        grep -q '^gpgcheck=' "$_repo_file" || \
            sed -i '/^\[/a gpgcheck=0' "$_repo_file"
    done
done
unset _repo_dir _repo_file

### Install Homebrew for all users (including FreeIPA domain users)
#
# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home. The /var
# tree is seeded from the OCI image on first install and preserved across
# bootc upgrades, so the brew installation is present from first boot and
# survives image updates independently.
#
# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.

useradd -r -M -d /home/linuxbrew -s /bin/bash linuxbrew
groupadd -r brew
usermod -aG brew linuxbrew

# /home is a symlink to /var/home in Bluefin; create the real directory
# since the symlink target does not exist during the container build.
mkdir -p /var/home/linuxbrew
chown linuxbrew:linuxbrew /var/home/linuxbrew
chmod 0755 /var/home/linuxbrew

curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    -o /tmp/brew-install.sh
# runuser/su both invoke PAM which fails in a container build environment.
# setpriv drops to the target UID/GID without PAM and is safe in containers.
setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
    env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
    bash /tmp/brew-install.sh

chgrp -R brew /home/linuxbrew/.linuxbrew
chmod -R g+rwX /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +

cat > /etc/profile.d/brew.sh << 'BREWEOF'
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod 644 /etc/profile.d/brew.sh
