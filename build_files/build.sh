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
# "Branding" below); f<ver>-backgrounds-gnome supplies the current stock
# Fedora default wallpaper (see "Wallpaper" below), versioned off this
# build's own Fedora release so it never goes stale on a Fedora bump the
# way a hardcoded package name would; zstd is the compressor the
# initramfs regeneration below asks dracut to use, listed explicitly
# rather than assumed present.
# powertop provides the --auto-tune power-saving profile applied at boot
# by powertop-autotune.service (see below).
# thermald is Intel's own thermal daemon; on 12th-gen ("Alder Lake") hybrid
# P-core/E-core laptop hardware — this image's primary target, see
# CLAUDE.md — it reads the platform's Intel DPTF thermal tables and
# proactively throttles before the kernel's own emergency thermal shutdown
# has to step in, which otherwise tends to show up as abrupt, coarse
# frequency cliffs under sustained load rather than the smoother ramp
# thermald manages.
# intel-media-driver is the "iHD" VA-API backend for Intel's Gen9+ (which
# includes Alder Lake's Xe-LP) integrated graphics, giving hardware video
# encode/decode instead of a software fallback — see the LIBVA_DRIVER_NAME
# default and enable_guc=3/HuC note below for why both pieces are needed
# together.
# acl provides setfacl/getfacl, used by homebrew-install.sh's first-boot
# Homebrew install to set a default ACL on the shared Homebrew prefix -
# needed so newly created Cellar/etc. entries stay group-writable for
# every 'brew' group member regardless of that user's umask (plain
# chmod/setgid alone isn't enough - see homebrew-install.sh).
# --allowerasing is required for fedora-logos, which conflicts with
# generic-logos (the Bluefin base image's replacement for it) — it only
# erases packages that actually conflict, so it's safe to apply to the
# whole transaction rather than isolating it to just that one package.
_fedora_ver="$(rpm -E %fedora)"
dnf5 install -y --allowerasing \
    freeipa-client \
    oddjob \
    oddjob-mkhomedir \
    policycoreutils-python-utils \
    acl \
    alsa-sof-firmware \
    alsa-ucm \
    fedora-logos \
    "f${_fedora_ver}-backgrounds-gnome" \
    powertop \
    thermald \
    intel-media-driver \
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

# sssd's own runtime/cache directories under /var, plus certmonger's
# (already-existing, RPM-owned) state directories, are declared via
# systemd-tmpfiles rather than created directly here — see var-state.conf
# for why (bootc container lint's var-tmpfiles check, and avoiding baking
# content into /var at build time that a real first boot can create itself).
install -Dm644 /ctx/var-state.conf \
    /usr/lib/tmpfiles.d/var-state.conf

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

### Register a "Chromebook" keyboard input source, selectable in GNOME Settings
#
# On Chromebooks converted to run this image via MrChromebox coreboot
# firmware, every Chromebook-specific key (Search/Launcher -> Super, the
# action-key top row, the Overview key) is already remapped to its correct
# evdev keycode by firmware/kernel defaults and picked up generically by
# /usr/share/X11/xkb/symbols/inet, which every XKB layout includes
# regardless of which one is active - the same firmware-dependency pattern
# documented for SOF audio above (see README's "No Sound on Chromebook
# Hardware" section). Plain "English (US)" therefore already behaves
# correctly on this hardware, and GNOME's Input Sources picker only ever
# lists XKB layouts/variants (symbols-level config), never the XKB *model*
# (set separately, per-machine, via `localectl set-x11-keymap ... chromebook`
# for keyboard-geometry purposes) - so there is nothing actually broken to
# fix here.
#
# This variant therefore changes no key bindings; it exists purely so
# "Chromebook" is a real, selectable, unambiguous entry in the picker
# instead of requiring users to trust that "English (US)" already does the
# right thing on this hardware.

# Idempotent: guards against a duplicate section if a future
# xkeyboard-config version ever ships one of this name upstream.
if ! grep -q 'xkb_symbols "chromebook"' /usr/share/X11/xkb/symbols/us; then
    cat >> /usr/share/X11/xkb/symbols/us << 'XKBEOF'

// Added by bluefin-freeipa: a labeled GNOME input source for Chromebook
// hardware. See build.sh for why the Search key and action row aren't
// touched here (already correct at the firmware/keycode level for every
// layout) - the overrides below are for the one thing that generic
// defaults can't provide: a Home/End/PageUp/PageDown/Delete cluster,
// which this hardware has no dedicated physical keys for at all (ChromeOS
// only ever reaches them via Search+arrow/Backspace combos). The Search
// key is already this image's Super key system-wide, so Right Alt stands
// in as the Search-combo modifier instead: hold it with an arrow key or
// Backspace for the level-3 symbol below. us(basic) alone does NOT wire
// Right Alt to ISO_Level3_Shift - that binding lives in the separate
// level3(ralt_switch) option and only applies if a machine's XKB options
// string happens to request it - so it's included explicitly here to
// make this variant self-contained. Shift still combines normally on top
// (e.g. RightAlt+Shift+Left still reports Shift in the event state
// alongside the Home keysym, so "select to start of line" keeps working
// in apps that check for it).
xkb_symbols "chromebook" {
    include "us(basic)"
    include "level3(ralt_switch)"
    name[Group1] = "English (Chromebook)";

    key <LEFT> { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ Left,      Left,      Home,   Home   ] };
    key <RGHT> { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ Right,     Right,     End,    End    ] };
    key <UP>   { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ Up,        Up,        Prior,  Prior  ] };
    key <DOWN> { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ Down,      Down,      Next,   Next   ] };
    key <BKSP> { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ BackSpace, BackSpace, Delete, Delete ] };

    // Search+Esc opens ChromeOS's task manager. Lock screen (Search+L)
    // and numbered app launch (Search+1..9) need nothing here at all -
    // Search is already Super on this hardware, and GNOME's own defaults
    // for <Super>l (lock) and <Super>1..9 (switch-to-application-N)
    // already cover those exactly. There's no stock GNOME equivalent for
    // Search+Esc, so it's routed through a dedicated keysym (XF86TaskPane,
    // not otherwise bound to anything by default) that a custom
    // media-keys keybinding below launches gnome-system-monitor from -
    // same input-source-scoping trick as the nav cluster: under
    // English (US) this key is still plain Escape, since the override
    // only exists in this variant.
    key <ESC> { type[Group1] = "FOUR_LEVEL", symbols[Group1] = [ Escape, Escape, XF86TaskPane, XF86TaskPane ] };
};
XKBEOF
fi

# Bind XF86TaskPane (Search+Esc under the Chromebook input source, see
# above) to gnome-system-monitor as GNOME's nearest equivalent to
# ChromeOS's task manager. Shipped as a system-wide dconf default, the
# same mechanism already used for the Logo Menu icon override below -
# custom-keybindings is a list-valued key, so if a future addition here
# or elsewhere also needs one, they must be combined into a single list
# rather than each overwriting the other's entry.
install -dm755 /etc/dconf/db/distro.d
cat > /etc/dconf/db/distro.d/07-chromebook-task-manager << 'DCONFEOF'
[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/chromebook-task-manager/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/chromebook-task-manager]
name='Task Manager (Chromebook)'
command='gnome-system-monitor'
binding='XF86TaskPane'
DCONFEOF
dconf update

# Register the variant so GNOME's Input Sources picker (and any other
# libxkbregistry consumer) can find it. xkeyboard-config's *.extras.xml
# files list "less common" variants merged in alongside the main *.xml
# rules at query time - this is the standard mechanism the project itself
# uses for exactly this kind of addition (22 other extra "us" variants
# already live in the same <layout> block this edits). evdev.xml is what
# GNOME/Wayland actually query; base.xml/base.extras.xml are kept in sync
# too since they are byte-identical siblings shipped by the same
# xkeyboard-config package and some legacy X11-only tools read them
# instead.
#
# popularity="standard" (not "exotic", unlike the other 22 variants in
# this same file) is deliberate: gnome-control-center's Input Sources
# "Add an Input Source" dialog only lists exotic-popularity entries once
# the user opts in via GNOME Tweaks' "Additional Layouts"/extended-sources
# toggle - confirmed live, the variant was otherwise invisible in the
# default picker and only appeared after flipping that switch. This
# variant is a first-class feature of this image, not a legacy/rare
# layout, so it needs to show up in the default list with no extra
# per-machine toggle required.
# Plain text insertion (not an XML-tree parse/rewrite) is deliberate: it's
# the only way to add one <variant> without reserializing - and thereby
# reformatting, or silently dropping the DOCTYPE from - the rest of a
# 250KB+ file neither of us owns.
python3 - << 'PYEOF'
for path in (
    "/usr/share/X11/xkb/rules/evdev.extras.xml",
    "/usr/share/X11/xkb/rules/base.extras.xml",
):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    if "English (Chromebook)" in content:
        continue  # already registered

    anchor = "<description>English (US)</description>"
    us_idx = content.index(anchor)
    close_idx = content.index("</variantList>", us_idx)
    # Insert at the start of the </variantList> line, not right before the
    # tag itself, so that line's own pre-existing indentation stays where
    # it is instead of prefixing the inserted block.
    line_start = content.rfind("\n", 0, close_idx) + 1

    insertion = (
        "        <variant>\n"
        '          <configItem popularity="standard">\n'
        "            <name>chromebook</name>\n"
        "            <description>English (Chromebook)</description>\n"
        "          </configItem>\n"
        "        </variant>\n"
    )
    content = content[:line_start] + insertion + content[line_start:]

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
PYEOF

### Exclude local sudo accounts from the GDM login screen
#
# On a FreeIPA-joined machine, the accounts worth showing on the login
# screen are domain accounts, not this image's one local (sudo/wheel)
# fallback account. GDM's clickable user list is driven by
# AccountsService, which populates it for BOTH local and domain
# accounts the same way - lazily, as each account actually logs in once
# (not via sssd's enumerate, which stays at its secure/performant
# default of false) - so domain accounts need nothing extra here to
# eventually appear; only the local admin account needs to be kept out.
#
# AccountsService has no supported way to do that after the fact: its
# SystemAccount property is read-only over D-Bus (confirmed live -
# `busctl --system set-property ... SystemAccount b true` fails with
# "Property is not writable"), so this can't be flipped once an account
# already exists. The one mechanism accounts-daemon does honor for this
# is the classic [greeter] Exclude= list in /etc/gdm/custom.conf -
# confirmed by the literal path string "/etc/gdm/custom.conf" present
# in the installed accounts-daemon binary itself, alongside
# "user %s %ld excluded" tracing exactly this check.
#
# The account's username isn't known at image-build time either - it's
# created after this build, by Anaconda kickstart or gnome-initial-setup
# depending on which ISO variant is used, with a name the user picks -
# so the actual exclusion has to happen on the deployed machine, not
# here. This just ships the script and unit that do it at every boot;
# see hide-local-admins-gdm.py for the discovery logic (any local
# /etc/passwd entry, UID >= 1000, in the wheel group) and
# hide-local-admins-gdm.service for why it has to run before GDM starts
# and why every boot rather than first-boot-only.
install -Dm755 /ctx/hide-local-admins-gdm.py \
    /usr/libexec/hide-local-admins-gdm.py
install -Dm644 /ctx/hide-local-admins-gdm.service \
    /usr/lib/systemd/system/hide-local-admins-gdm.service
systemctl enable hide-local-admins-gdm.service

### Let every user run Tailscale/trayscale without a manual sudo step
#
# By default only root can control tailscaled, so trayscale (which has no
# privilege-escalation UI of its own) does nothing for a normal user until
# someone runs `sudo tailscale set --operator=$USER` for them - and that
# only ever grants operator status to whichever one user last ran it, since
# it's a single value in tailscaled's own state. On a shared/domain-joined
# machine where any user might log in, that means it has to be re-applied
# per user rather than once at setup time.
#
# tailscale-set-operator (shipped to /usr/libexec) sets *only the invoking
# user* as operator, reading who that is from SUDO_USER rather than an
# argument - so the sudoers rule granting it NOPASSWD access can match its
# exact path with no wildcard, and a user can never make anyone but
# themselves the operator. tailscale-set-operator.service runs it via sudo
# at every graphical login (WantedBy=graphical-session.target, a per-user
# unit), so whichever user is currently logged in becomes the operator
# automatically, with no manual step and no password prompt.
install -Dm755 /ctx/tailscale-set-operator.sh \
    /usr/libexec/tailscale-set-operator.sh
install -Dm440 /ctx/tailscale-operator.sudoers \
    /etc/sudoers.d/tailscale-operator
visudo -cf /etc/sudoers.d/tailscale-operator
install -Dm644 /ctx/tailscale-set-operator.service \
    /usr/lib/systemd/user/tailscale-set-operator.service
systemctl --global enable tailscale-set-operator.service

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

### Apply PowerTOP's power-saving auto-tune profile at every boot
#
# `powertop --auto-tune` applies powertop's recommended runtime power-saving
# settings (e.g. USB/PCI/audio autosuspend, SATA link power management).
# These settings live in volatile kernel/sysfs state, not on disk, so they
# don't persist across reboots on their own and have to be re-applied every
# boot rather than once at image build time. Type=oneshot + RemainAfterExit
# runs it once per boot and reports the unit as active afterward, the same
# shape used elsewhere in this image for a run-once-at-boot action (see
# hide-local-admins-gdm.service, which instead runs every boot for a
# different reason — no analogous "state resets on reboot" need here).
install -Dm644 /ctx/powertop-autotune.service \
    /usr/lib/systemd/system/powertop-autotune.service
systemctl enable powertop-autotune.service

### 12th-gen Intel ("Alder Lake") laptop power management and graphics
#
# This image's primary target is a 12th-gen Intel Lenovo laptop (see
# CLAUDE.md), so the pieces below are tuned for that hybrid P-core/E-core
# CPU and its Xe-LP integrated GPU specifically, on top of the
# hardware-agnostic PowerTOP auto-tune above.

# thermald: Intel's own thermal daemon, reading DPTF thermal tables to
# throttle proactively rather than relying solely on the kernel's coarser
# emergency thermal cutoffs. See the package comment above for why this
# matters more on Alder Lake's hybrid core layout than on older,
# homogeneous-core Intel CPUs.
systemctl enable thermald.service

# i915 GuC/HuC submission + framebuffer compression: see
# i915-power.conf for the full rationale (including why PSR is
# deliberately left alone).
install -Dm644 /ctx/i915-power.conf \
    /etc/modprobe.d/i915-power.conf

# Default VA-API to intel-media-driver's "iHD" backend rather than relying
# on libva's own runtime auto-detection, which resolves the driver name
# from the bound kernel driver and can land on the legacy i965 backend
# instead of iHD depending on exactly which VA-API packages a given
# Bluefin base image build happens to carry — pinning it here removes that
# ambiguity, the same "force it explicitly rather than trust an
# environment-dependent default" reasoning already applied to enable_guc
# above and to the ostree dracut module elsewhere in this script. iHD is
# what actually exercises the hardware encode/decode path that enable_guc's
# HuC bit (above) loads firmware for; without both pieces together, video
# playback/encode falls back to software and costs far more battery.
install -dm755 /etc/environment.d
cat > /etc/environment.d/10-intel-vaapi.conf << 'ENVEOF'
LIBVA_DRIVER_NAME=iHD
ENVEOF

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
# Bluefin ships logo files in a few places that are visible to users. Boot
# and OS iconography is restored to stock Fedora artwork rather than
# Universal Blue branding, since that's the first (and most systemic)
# graphic set users see:
#
#   1. Plymouth boot watermark (/usr/share/plymouth/themes/spinner/watermark.png)
#   2. GDM login screen logo (/usr/share/pixmaps/fedora-gdm-logo.png and
#      related pixmap files) and the Anaconda installer sidebar logo
#      (/usr/share/anaconda/pixmaps/silverblue/sidebar-logo.png) — both
#      shipped directly by fedora-logos (installed above with
#      --allowerasing over Bluefin's generic-logos), so no override is
#      needed for either.
#
# Two spots keep Universal Blue branding deliberately — they're
# distro-identity touches (a shell extension icon, a terminal banner)
# rather than boot/OS iconography, so they're out of scope for the
# fedora-branding revert above:
#
#   3. GNOME Shell Logo Menu (/usr/share/icons/hicolor/scalable/actions/
#                               ublue-logo-symbolic.svg)
#   4. Fastfetch terminal logo (see below)
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

# Bluefin help desktop entry — update name (entry is NoDisplay=true;
# only visible in default-app pickers for help:// URI schemes).
if [[ -f /usr/share/applications/bluefin-help.desktop ]]; then
    sed -i 's/^Name=.*/Name=Universal Blue Help/' \
        /usr/share/applications/bluefin-help.desktop
fi

### Wallpaper — use Fedora's default background instead of Bluefin's
#
# Bluefin ships its own bluefin-wallpapers package and sets it as the
# GNOME default. Rather than tracking down and undoing whatever mechanism
# Bluefin used to make that the default (it isn't a simple Conflicts-based
# package swap the way generic-logos/fedora-logos is), this forces the
# stock Fedora default background via the same /etc/dconf/db/distro.d
# override mechanism already used above for the Logo Menu icon — a dconf
# override is guaranteed to win over whatever set the previous default,
# without needing to know or replicate that mechanism.
#
# f<ver>-backgrounds-gnome (installed above, versioned off this build's own
# Fedora release) ships the current-year default under
# /usr/share/backgrounds/f<ver>/default/ as a day/night pair; the exact
# filenames (extension and numbering) have changed across Fedora releases,
# so they're discovered here instead of hardcoded, the same way the audio
# and initramfs sections above discover driver names rather than pinning
# them.
_bg_dir="/usr/share/backgrounds/f${_fedora_ver}/default"
_bg_day="$(find "${_bg_dir}" -maxdepth 1 -type f -iname '*day*' | sort | head -n1)"
_bg_night="$(find "${_bg_dir}" -maxdepth 1 -type f -iname '*night*' | sort | head -n1)"
# Fail the build rather than silently keeping Bluefin's wallpaper if
# f<ver>-backgrounds-gnome's layout ever changes shape.
[[ -n "${_bg_day}" && -n "${_bg_night}" ]]

install -dm755 /etc/dconf/db/distro.d
cat > /etc/dconf/db/distro.d/07-fedora-wallpaper << DCONFEOF
[org/gnome/desktop/background]
picture-uri='file://${_bg_day}'
picture-uri-dark='file://${_bg_night}'
picture-options='zoom'
DCONFEOF
dconf update
unset _fedora_ver _bg_dir _bg_day _bg_night

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
# directory first so the symlink resolves. Removed again once the loop
# below is done with it (see there) — it's only ever needed as a target
# for dracut-install to snapshot during this build, not as shipped content.
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

# Regenerating this initramfs (see above) switched it from dracut's
# hostonly filtering to "generic" (--no-hostonly) mode, and generic mode's
# documented behavior is to bundle every driver dracut can find under the
# kernel's module tree, not just boot-critical ones — that's why this loop
# takes tens of seconds per kernel and produces a multi-MB file even before
# --add-drivers runs. For sound/ that's actively harmful, not just wasteful:
# it pulls in both this image's SOF/SoundWire stack (see "Chromebook
# SoundWire/SOF audio support" above) *and* the legacy snd_hda_intel
# HD-Audio driver, and initramfs's udev coldplug autoloads matching
# drivers for every PCI device it sees — including the audio controller —
# before switch-root, while the real root's SOF firmware
# (/lib/firmware/intel/sof*, from alsa-sof-firmware) and UCM profiles
# aren't mounted yet. A driver that binds the controller that early can
# leave it stuck on the wrong (or firmware-less, non-functional) driver
# for the rest of boot, since kernel driver bindings aren't undone across
# switch-root. No audio driver is ever needed pre-switch-root, so the
# fix is to exclude the entire sound/ driver tree from this initramfs,
# leaving driver selection to happen exactly once, on the real root, where
# snd_intel_dspcfg's dsp_driver=auto logic and the UCM profiles are both
# present. Built from the running kernel's own module tree (rather than a
# hardcoded name list) so it tracks whichever sound drivers that kernel
# actually ships.
_kver_count=0
for _kver_dir in /usr/lib/modules/*; do
    _kver="$(basename "${_kver_dir}")"
    [[ -f "${_kver_dir}/vmlinuz" ]] || continue

    _sound_drivers="$(find "${_kver_dir}/kernel/sound" -name '*.ko*' \
        -printf '%f\n' 2>/dev/null \
        | sed -E 's/\.ko(\.zst|\.xz|\.gz)?$//' | sort -u | tr '\n' ' ' || true)"

    _tmp_initramfs="${_kver_dir}/initramfs.img.new"
    rm -f "${_tmp_initramfs}"
    dracut --no-hostonly --force --compress=zstd \
        --add-drivers "${_boot_drivers}" \
        --add "${_boot_dracutmodules}" \
        --omit-drivers "${_sound_drivers}" \
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
    # Negative check: catch a --omit-drivers regression (e.g. a future
    # dracut/base-image change reintroducing sound modules some other way)
    # before it ships, the same way the positive checks above catch a
    # missing storage driver or dracut module.
    if [[ -n "${_sound_drivers// /}" ]]; then
        ! grep -qE "/sound/.*\.ko" <<<"${_initramfs_listing}"
    fi

    mv -f "${_tmp_initramfs}" "${_kver_dir}/initramfs.img"
    _kver_count=$((_kver_count + 1))
done
((_kver_count > 0))
unset _kver_dir _kver _tmp_initramfs _size _kver_count _boot_drivers _boot_dracutmodules _initramfs_listing _sound_drivers

# Done with the dracut-install workaround above — /var/roothome was only
# ever needed as a snapshot target for /root -> /var/roothome to resolve
# during this build, not as shipped content. Remove it so it doesn't show
# up as unexplained /var content in bootc container lint's var-tmpfiles
# check; a deployed system creates its own real /var/roothome independently
# of anything shipped here (the same way /var/home is populated).
rmdir /var/roothome

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

### Set up Homebrew for all users (including FreeIPA domain users)
#
# Homebrew is installed to /home/linuxbrew/.linuxbrew (the standard Linux
# prefix). In a bootc deployment, /home is a symlink to /var/home.
#
# The account is created here, at build time, so /etc/passwd/group ship
# with it on every image. The actual Homebrew installation, though, is
# deferred to a first-boot systemd unit (homebrew-install.service) instead
# of running here: ostree only seeds /var from the image on a machine's
# very first deployment, and leaves an already-provisioned machine's /var
# alone on every later bootc upgrade. Installing the (thousands of files)
# Homebrew tree into /var at build time meant CI rebuilt it from scratch
# every day for no benefit to any already-deployed machine, and even a
# brand-new machine's baked-in copy is immediately superseded by
# Homebrew's own `brew update` anyway. See homebrew-install.sh/.service
# for the actual install logic.
#
# The 'brew' group grants write access to the installation. Local users and
# FreeIPA domain users added to this group can run 'brew install'. Users not
# in the group can still run any package that is already installed.
#
# The linuxbrew user/brew group are declared via systemd-sysusers rather
# than useradd/groupadd, with pinned UID/GID (950/951), instead of letting
# useradd/groupadd allocate whatever system ID happens to be free that day.
# bootc container lint flags plain useradd/groupadd here ("sysusers" check)
# for a real reason: /etc/passwd and /etc/group ARE part of bootc's
# three-way /etc merge on upgrade (unlike /var — see below), so if two
# builds of this image allocate a different UID for the same username (a
# real risk across daily rebuilds, since the free-ID choice depends on
# whatever other system accounts exist in that day's build), the merge
# applies that UID change to already-deployed machines. The on-disk files
# under /var/home/linuxbrew (seeded once, at first install, with the
# numeric UID baked into their inodes) don't get renumbered to match, so
# the account silently stops owning its own files. A fixed UID/GID makes
# every build produce byte-identical passwd/group entries for this
# account, so there's never a diff for the merge to apply.
install -Dm644 /ctx/homebrew-sysusers.conf /usr/lib/sysusers.d/homebrew.conf
systemd-sysusers /usr/lib/sysusers.d/homebrew.conf

install -Dm755 /ctx/homebrew-install.sh \
    /usr/libexec/homebrew-install.sh
install -Dm644 /ctx/homebrew-install.service \
    /usr/lib/systemd/system/homebrew-install.service
systemctl enable homebrew-install.service

cat > /etc/profile.d/brew.sh << 'BREWEOF'
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
BREWEOF
chmod 644 /etc/profile.d/brew.sh
