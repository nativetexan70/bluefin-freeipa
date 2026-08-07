#!/bin/bash

set -ouex pipefail

### Install packages

# freeipa-client pulls in sssd, krb5-workstation, certmonger, and other
# required dependencies automatically.
#
# policycoreutils-python-utils provides semanage, used by
# `ujust setup-hibernation` to persistently label the hibernation swapfile
# swapfile_t (systemd's boot-time swapon is denied by SELinux on the
# default var_t label).
dnf5 install -y \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir \
    policycoreutils-python-utils

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

### Install fleetd (Fleet's agent) — https://fleetdm.com/docs/configuration/agent-configuration
#
# fleetd bundles Orbit (an osquery runtime + autoupdater) and osqueryd.
# Fleet does not publish a generic distro package: `fleetctl package`
# builds one per deployment, normally baking a specific --fleet-url and
# --enroll-secret into the resulting package. This image is not tied to
# one Fleet server, so those flags are omitted entirely when packaging.
# (--use-system-configuration would express this same intent, but it's
# only accepted for --type=pkg/msi installers, not deb/rpm.) The
# resulting RPM's systemd unit still reads ORBIT_FLEET_URL/
# ORBIT_ENROLL_SECRET from /etc/default/orbit at runtime via
# EnvironmentFile, so Orbit picks up whatever config ends up there. That
# mirrors ipa-client-install — enrollment happens post-deployment, on the
# actual host, against whatever Fleet server that host is meant to join.
#
# fleetctl (the packaging CLI) is only needed here to build the RPM; it
# is not installed into the final image.

case "$(uname -m)" in
    x86_64) _fleet_arch="amd64" ;;
    aarch64) _fleet_arch="arm64" ;;
    *)
        echo "Unsupported architecture for fleetd: $(uname -m)" >&2
        exit 1
        ;;
esac

_fleetctl_workdir="$(mktemp -d)"

# Resolve the latest Fleet release tag (e.g. "fleet-v4.85.0") rather than
# pinning a version, so the agent stays current automatically as this
# image is rebuilt.
#
# Buffer the API response into a variable and match it with bash's
# built-in regex instead of piping through `grep -m1`: a pipe reader that
# stops after its first match (as -m1 does) closes the pipe while curl is
# still writing, so curl gets SIGPIPE and exits non-zero — which, under
# `pipefail`, fails this whole step even though the tag was already
# parsed correctly.
_fleet_releases="$(curl -fsSL https://api.github.com/repos/fleetdm/fleet/releases)"
if [[ "${_fleet_releases}" =~ \"tag_name\":\ *\"(fleet-v[0-9.]+)\" ]]; then
    _fleet_tag="${BASH_REMATCH[1]}"
else
    echo "Could not determine the latest fleetd release tag" >&2
    exit 1
fi
_fleet_version="${_fleet_tag#fleet-v}"

curl -fsSL \
    "https://github.com/fleetdm/fleet/releases/download/${_fleet_tag}/fleetctl_v${_fleet_version}_linux_${_fleet_arch}.tar.gz" \
    -o "${_fleetctl_workdir}/fleetctl.tar.gz"
tar -xzf "${_fleetctl_workdir}/fleetctl.tar.gz" -C "${_fleetctl_workdir}"

# fleetctl unconditionally tries to open a REPL history file at
# <home>/.goquery/history on startup, even for non-interactive
# subcommands like `package`, but doesn't create the parent directory
# itself — it fails with "no such file or directory" if that directory
# is missing. It resolves root's home directory via the system user
# database (getpwuid), not $HOME, so overriding $HOME for the invocation
# doesn't help. /root is a symlink to /var/roothome in this ostree-based
# image (like /home -> /var/home), and /var is only a build-time cache
# mount here, so the symlink target doesn't exist yet and following it
# to create /root/.goquery fails. Create the real target directory first
# so the symlink resolves to a writable directory.
mkdir -p /var/roothome
mkdir -p /root/.goquery

"${_fleetctl_workdir}/fleetctl_v${_fleet_version}_linux_${_fleet_arch}/fleetctl" package \
    --type=rpm \
    --outfile="${_fleetctl_workdir}/fleetd.rpm"

dnf5 install -y "${_fleetctl_workdir}/fleetd.rpm"

rm -rf "${_fleetctl_workdir}"
unset _fleetctl_workdir _fleet_releases _fleet_tag _fleet_version _fleet_arch

### Preserve fleetd enrollment across bootc updates
#
# Orbit's systemd unit (installed by the RPM above) reads its Fleet URL
# and enroll secret from /etc/default/orbit via EnvironmentFile, instead
# of from values baked into the package. This image never passes a real
# --fleet-url or --enroll-secret to `fleetctl package`, so nothing
# meaningful ends up in that file at build time — truncate it to
# guarantee it ships empty, matching the /etc/ipa and /etc/sssd/conf.d
# skeletons above. Whatever an admin writes into it after deployment is
# therefore a local addition
# that bootc's three-way /etc merge will never overwrite.
install -m 0644 /dev/null /etc/default/orbit

# Orbit's runtime state (enroll secret cache, osqueryd DB, logs) lives
# under /opt/orbit. Bluefin's base image already symlinks /opt to
# /var/opt (see the /opt note near the top of the Containerfile), so this
# is mutable and preserved across updates the same way /var/lib/sss is,
# with no extra setup required here.

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
systemctl enable orbit

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

### Universal Blue branding — replace Bluefin logos throughout
#
# Bluefin ships logo files in three places that are visible to users:
#
#   1. Plymouth boot watermark (/usr/share/plymouth/themes/spinner/watermark.png)
#   2. GDM login screen logo  (/usr/share/pixmaps/fedora-gdm-logo.png)
#      and related pixmap files
#   3. GNOME Shell Logo Menu  (/usr/share/icons/hicolor/scalable/actions/
#                               ublue-logo-symbolic.svg)
#
# The bgrt Plymouth theme only shows bgrt-fallback.png when no UEFI firmware
# logo is present. Switching to the spinner theme ensures the watermark is
# always displayed regardless of hardware.

# Plymouth — spinner theme watermark (shown on all hardware)
# Plymouth renders watermark.png at native pixel size. Bluefin's original
# watermark is 288x43px; the horizontal wordmark is rendered at 300x76 to
# match the original scale while showing the icon+text wordmark.
install -Dm644 /ctx/ublue-logo-watermark.png \
    /usr/share/plymouth/themes/spinner/watermark.png
install -Dm644 /ctx/ublue-logo-watermark.png \
    /usr/share/plymouth/themes/spinner/bgrt-fallback.png
install -Dm644 /ctx/ublue-logo-watermark.png \
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
# --no-hostonly avoids hardware-specific probing that fails in a container.
# --regenerate-all rebuilds for every installed kernel version.
dracut --no-hostonly --regenerate-all --force

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
