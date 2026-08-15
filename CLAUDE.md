# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OCI image layered on top of `ghcr.io/ublue-os/bluefin:stable` (a Universal Blue image), adding FreeIPA client support. Images are built via GitHub Actions and published to `ghcr.io/personalcyber/bluefin-freeipa`. The image is designed so that a FreeIPA domain join survives `bootc` updates via bootc's three-way `/etc` merge.

## Common Commands

All local build tasks use [just](https://just.systems/):

```bash
just build                  # Build container image with podman
just lint                   # Run shellcheck on all .sh files
just format                 # Run shfmt on all .sh files
just check                  # Validate Justfile syntax
just fix                    # Auto-fix Justfile syntax
just build-qcow2            # Build QCOW2 VM image via bootc-image-builder
just build-iso-gnome        # Build GNOME installer ISO
just build-iso-kde          # Build KDE installer ISO
just run-vm-qcow2           # Run QCOW2 VM (builds if needed, opens browser at port 8006+)
just run-vm-iso-gnome       # Run GNOME ISO in a VM
just run-vm-iso-kde         # Run KDE ISO in a VM
just spawn-vm               # Run VM using systemd-vmspawn
just clean                  # Remove build artifacts from output/
```

## Architecture

### Build Pipeline

1. **`Containerfile`** — Two-stage build: a scratch `ctx` stage copies `build_files/` (making scripts available without embedding them in the final layer). The base image is `ghcr.io/ublue-os/bluefin:stable`. The main `RUN` step tmpfs-mounts `/tmp` and `/run` and cache-mounts `/var/cache`, `/var/log`, and `/var/lib/dnf` (see `bootc container lint` below), then runs `build.sh`. After that, a `COPY` instruction ships an empty `/etc/hostname` (see Hostname Preservation below). Ends with `bootc container lint`.
2. **`build_files/build.sh`** — Executed during the container build (`RUN /ctx/build.sh`). Installs `freeipa-client`, `oddjob`, `oddjob-mkhomedir`; creates `/etc/ipa/` and `/etc/sssd/conf.d/` directory skeletons; installs `var-state.conf` (see `bootc container lint` below) declaring sssd/certmonger/ipa-client's `/var` state directories; sets up Homebrew's account and first-boot install unit (see Homebrew below); enables `sssd`, `oddjobd`, and `podman.socket`. Runs with `set -ouex pipefail`.
3. **`build_files/hostname`** — Empty file copied to `/etc/hostname` in the image via `COPY`. Must remain empty.
4. **GitHub Actions (`build.yml`)** — Triggers on push to `main`, PRs, and daily schedule. Builds by invoking `buildah bud` directly (see "CI Container Storage Driver" below for why, not `redhat-actions/buildah-build`), pushes to GHCR only on non-PR pushes to the default branch, signs with Cosign using `SIGNING_SECRET`.
5. **GitHub Actions (`build-disk.yml`)** — Manually triggered workflow producing `qcow2`, `anaconda-iso-gnome`, and `anaconda-iso-kde` disk images from the published OCI image using `bootc-image-builder`. Can optionally upload to S3.

### `bootc container lint`

The `Containerfile`'s final `RUN bootc container lint` must pass with zero warnings (`Checks passed: 13, Checks skipped: 1`, no `Warnings:` line — the one skipped check, `buildah-injected`, only applies when linting an externally-supplied `--root`, not this in-place `RUN` invocation). Two build-time mechanisms exist specifically to keep it that way:

- **`/tmp` and `/run` are tmpfs-mounted** in the `Containerfile`'s `RUN` step (`nonempty-run-tmp` check). Package scriptlets (certmonger, dnf, selinux-policy) drop runtime-only scratch files under `/run` as a side effect of installing; without a dedicated mount that content has nowhere to go but the image layer, since there's no running init in a `buildah` step to treat `/run` as ephemeral. Nothing in `build_files/` reads `/run` afterward, so nothing depends on that content surviving.
- **`var-state.conf` declares `/var` state via `systemd-tmpfiles`** instead of `build.sh` creating those directories imperatively (`var-tmpfiles` check). It covers two different kinds of path: sssd's own runtime/cache dirs (`/var/lib/sss/db`, `/var/lib/sss/pipes/private`, `/var/lib/sss/keytabs`, `/var/log/sssd`) — genuinely not shipped in the image at all now; `systemd-tmpfiles-setup.service` creates them fresh on first real boot, before sssd starts — and certmonger/freeipa-client's RPM-owned state dirs (`/var/lib/certmonger/{cas,local,requests}`, `/var/lib/ipa-client/{pki,sysrestore}`), which *are* baked in regardless (their packages create them via plain `%install mkdir -p`, no upstream tmpfiles.d) but are declared here anyway so lint recognizes them as intentional. `/var/lib/dnf` (repo metadata cache, lock file, countme markers) gets a build-time-only cache mount in the `Containerfile` instead, since it has no purpose on a deployed bootc system at all.

### Key Files to Modify

- **Add packages or system configuration**: Edit `build_files/build.sh`
- **Change base image**: Edit the `FROM` line in `Containerfile`
- **Change disk image layout**: Edit `disk_config/disk.toml` (qcow2/raw) or `disk_config/iso-gnome.toml` / `disk_config/iso-kde.toml` (ISOs)
- **Change CI behavior or image metadata**: Edit `.github/workflows/build.yml`
- **Add/change declarative `/var` state directories**: Edit `build_files/var-state.conf`
- **Change Homebrew's first-boot install logic**: Edit `build_files/homebrew-install.sh` (install logic) or `.service` (unit/conditions); account UID/GID pinning lives in `build_files/homebrew-sysusers.conf`

### FreeIPA Join Persistence

bootc performs a three-way `/etc` merge on update: it diffs old-image `/etc` vs new-image `/etc` and applies that delta to local `/etc`. Files written by `ipa-client-install` (`sssd.conf`, `krb5.conf`, `/etc/ipa/default.conf`, etc.) are never shipped in this image, so bootc treats them as local additions and never overwrites them. The `/etc/ipa/` and `/etc/sssd/conf.d/` directories are present in the image as empty skeletons — no config content is shipped inside them.

### GDM Login Screen — No Local-Account Picker

`build.sh` sets `org.gnome.login-screen disable-user-list=true`, so GDM shows a plain username prompt instead of a clickable account list. This isn't cosmetic preference — GDM's list is populated from AccountsService/local `passwd` entries (UID ≥ 1000) only; it has no path to domain accounts at all, since sssd's `enumerate = false` default (deliberate, for performance/security — full-directory enumeration isn't something FreeIPA supports doing for a login screen) means there's nothing to list them from. Showing a list would mean showing only this image's local accounts on a machine meant to be domain-joined, which is the opposite of what's wanted. Disabling the list is the standard, documented fix for this exact scenario; both local and domain accounts still authenticate the same way afterward, by typing their username.

The override goes in `/etc/dconf/db/gdm.d/`, **not** the `distro.d` directory the Logo Menu/Task Manager overrides below use — those are two different databases read by two different processes. GDM's greeter runs under its own dconf profile (`/usr/share/dconf/profile/gdm`, shipped by the `gdm` package), whose db chain lists `gdm` ahead of `distro`; a key only meaningful to the greeter belongs in the db that profile actually names for it.

### Chromebook SoundWire/SOF Audio Support

Many recent Chromebooks — including Tiger Lake models in Google's Volteer family (e.g. Lindar/"Lillipup") — drive audio entirely through Intel's SOF DSP over SoundWire (an RT5682 headset codec plus RT1011 speaker amps, in the Volteer case), not a conventional HD-Audio codec. Without extra setup, the desktop shows only a routeless "Dummy Output" sink and the speakers are silent. Three independent fixes are needed, and `build.sh` applies all three:

- **Kernel driver claim.** `snd-intel-dspcfg`'s `dsp_driver` option must stay at auto (`0`) or SOF (`3`); a `dsp_driver=1` (legacy HD-Audio) override — e.g. an `/etc/modprobe.d/alsa-legacy.conf` — stops SOF from ever claiming the controller, so no ASoC sound card is registered at all (not even at the kernel level). This image ships no such override, but `build.sh` removes one defensively (`rm -f /etc/modprobe.d/alsa-legacy.conf`) in case a future base-image layer adds it.
- **ALSA UCM profile.** Once the card exists, WirePlumber/PipeWire still need an ALSA UCM (Use Case Manager) profile to build real routes — a card with no matching profile only gets the routeless stereo-fallback node. Upstream `alsa-ucm-conf` doesn't cover every Chromebook SOF card name (e.g. `sof-rt5682`). `build.sh` installs `alsa-sof-firmware` and `alsa-ucm` (the Fedora package providing `/usr/share/alsa/ucm2`), then layers the community-maintained [alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros) overlay (`ucm2/` for new profiles, `overrides/` replacing incomplete upstream ones) on top of `/usr/share/alsa/ucm2/`, fetched from its `standalone` branch (its only/default branch) at build time so it stays current as the image is rebuilt. Its profiles detect the board/codec at runtime via DMI `product_family` and i2c modalias probing, so this one overlay covers many Chromebook SOF boards, not just Tiger Lake/Volteer.
- **No early driver claim in the initramfs.** The initramfs regenerated at build time (see below, under Hostname/Plymouth) runs in dracut's "generic" (`--no-hostonly`) mode, which bundles every driver dracut finds under the kernel's module tree — including the whole `sound/` tree, legacy `snd_hda_intel` alongside the SOF stack. initramfs's udev coldplug autoloads matching drivers for every PCI device it sees, including the audio controller, before switch-root — while the real root's SOF firmware and UCM profiles aren't mounted yet. A driver bound that early can leave the controller stuck on the wrong (or non-functional) driver for the rest of boot, since driver bindings don't get undone across switch-root. No audio driver is ever needed pre-switch-root, so `build.sh` passes `--omit-drivers` with every module name found under that kernel's own `kernel/sound/` tree, excluding the whole category from the initramfs and leaving driver selection to happen exactly once, on the real root.

**Known hardware/firmware limitation — Intel ME/CSE must be enabled.** Even with every OS-side piece above correctly in place, SOF audio still cannot initialize if the Intel Management Engine (ME) is disabled in firmware. On Tiger Lake-class silicon (Volteer/"Lindar" included), the DSP ROM authenticates its firmware image through a handshake with CSE (Converged Security Engine — the same subsystem as ME), not a plain load; with ME disabled, CSE never boots, so that handshake times out (`journalctl -k` shows `CSE_IPC_RESET_PHASE_1, waiting for: CSE_CSR, running` then `dsp init failed after 3 attempts with err: -110`) and no card is ever registered. This is specifically relevant on MrChromebox-converted Chromebooks, whose firmware utility exposes ME on/off as a user-facing flash-time option. Nothing in `build.sh` can work around it — confirmed by testing IPC3 vs IPC4 SOF firmware (no difference, both firmware types boot through the same CSE-gated ROM stage) and by forcing the legacy AVS driver (`dsp_driver=4`), which does get past the CSE handshake — proving CSE is the actual blocker — but has no Fedora-packaged firmware blob for Tiger Lake, so isn't a usable substitute. The fix lives entirely outside this repo: re-enable ME in the MrChromebox firmware utility and reflash. See the README's "No Sound on Chromebook Hardware" troubleshooting section for the user-facing version of this.

**Chromebook keyboard input source.** `build.sh` also registers a "Chromebook" XKB variant of `us` (`English (Chromebook)`), selectable in GNOME Settings' Input Sources picker, by appending an `xkb_symbols "chromebook"` section to the RPM-owned `/usr/share/X11/xkb/symbols/us` and a matching `<variant>` entry to `xkeyboard-config`'s `evdev.extras.xml`/`base.extras.xml` (via a plain-text insertion, not an XML-tree rewrite, to avoid reformatting or dropping the DOCTYPE from files this repo doesn't own). Selecting it is what activates everything below; plain `English (US)` stays a completely standard layout. Don't confuse this input source with the XKB *model* (`localectl set-x11-keymap ... chromebook`, keyboard-geometry only, set per-machine rather than baked into the image) — the two are unrelated.

The Search key, action row, and Overview key need no overrides — they're already correct on this hardware at the firmware/generic-keycode level, independent of which layout is active (see the README's "Chromebook Keyboard Input Source" section). What the variant does add is the ChromeOS Search-key nav combos, which this hardware has no dedicated physical keys for at all (Home/End/PageUp/PageDown/Delete, normally reached only via `Search` held with another key). Since `Search` is already this image's `Super` key, `Right Alt` stands in as the combo modifier instead — it's already wired as `ISO_Level3_Shift`/AltGr by the included `us(basic)`, so this is a `FOUR_LEVEL` type override on `<LEFT>`/`<RGHT>`/`<UP>`/`<DOWN>`/`<BKSP>` producing `Home`/`End`/`Prior`/`Next`/`Delete` as the level-3 symbol (works in every application directly, no GNOME keybinding involved; `Shift` still layers on top normally). `<ESC>` gets the same treatment but targets `XF86TaskPane` instead of a nav keysym, since ChromeOS's `Search+Esc` (task manager) has no GNOME equivalent to fall back on — a system-wide dconf default (`/etc/dconf/db/distro.d/07-chromebook-task-manager`, same mechanism as the Logo Menu override above) binds that keysym to launch `gnome-system-monitor`. The other two ChromeOS Search-combos (`Search+L` lock, `Search+1`-`9` numbered app launch) need nothing built for them at all: since `Search` is already `Super`, GNOME's own stock `Super+L` and `Super+1`-`9` (`switch-to-application-N`) already do the same thing.

All of this was verified before landing in `build.sh`, not assumed: the XKB syntax was compiled with `xkbcomp` against a full mirror of the installed `/usr/share/X11/xkb` tree (only `symbols/us` swapped for the patched copy) to confirm a clean exit and no new warnings; the `XF86TaskPane` keysym name was confirmed recognized the same way; and the dconf custom-keybinding shape was round-tripped live via `gsettings set`/`get` (then reverted) before being written into the image build.

### Homebrew

Homebrew is installed to `/home/linuxbrew/.linuxbrew` for all users (local and FreeIPA domain), but the actual installation happens on **first real boot**, not at build time:

- `build.sh` creates the `linuxbrew` user and `brew` group via a pinned `systemd-sysusers.d` file (`build_files/homebrew-sysusers.conf`, UID/GID 950/951) rather than `useradd`/`groupadd`, so every build produces byte-identical `passwd`/`group` entries for the account — `useradd -r`'s dynamic ID allocation would otherwise drift across this image's daily rebuilds, and since `/etc/passwd`/`/etc/group` are part of bootc's three-way `/etc` merge, a drifted UID gets applied to already-deployed machines whose on-disk files still have the old UID baked into their inodes.
- `build.sh` ships and enables `homebrew-install.service` (`build_files/homebrew-install.sh`/`.service`), a first-boot-only `systemd` oneshot gated on `ConditionPathExists=!/var/home/linuxbrew/.linuxbrew/bin/brew`. No Homebrew content is written into the image's `/var` at build time at all.

This split exists because ostree only seeds `/var` from the image on a machine's *very first* deployment — every later `bootc upgrade` leaves an already-provisioned machine's `/var` untouched. Installing Homebrew's full tree (thousands of files) into `/var` at build time meant CI rebuilt it from scratch daily for no benefit to any already-deployed machine, and even a brand-new machine's baked-in copy would be immediately superseded by Homebrew's own `brew update` anyway. First-boot install costs nothing in CI and nothing on machines that never end up using Homebrew — the trade-off is that a machine's first login needs network access before `brew` actually works; if the first boot has no network, the unit fails harmlessly and retries on the next boot (no `RemainAfterExit`).

### CI Container Storage Driver

`build.yml` invokes `buildah bud` directly in a plain `run:` step instead of using `redhat-actions/buildah-build`. This is a deliberate departure from the usual ublue-os template pattern: that action's `setStorageOptsEnv()` unconditionally re-injects `overlay.mount_program=<fuse-overlayfs path>` whenever it sees `driver=overlay` and finds a `fuse-overlayfs` binary on `PATH`, with no opt-out — confirmed by reading the action's source across three separate attempts to work around it (`CONTAINERS_STORAGE_CONF`, removing the binary, writing `storage.conf` to the exact path the action's own pre-check reads). `fuse-overlayfs` doesn't support atomic `rename()` the way native overlayfs does, which broke `semanage`'s SELinux policy-store commit during `build.sh`'s package installs (`policycoreutils-python-utils`, `freeipa-client`, etc.) — silently, since RPM scriptlet failures don't fail the overall `dnf5` transaction. The "Use native overlayfs storage driver" step still writes a `driver = "overlay"`, no-`mount_program` `storage.conf` (to both `CONTAINERS_STORAGE_CONF` and `~/.config/containers/storage.conf`) and removes the `fuse-overlayfs` binary from `PATH` — that config now actually takes effect because there's no action left to override it. Bypassing the action also removed a substantial amount of extra work it was doing beyond the `buildah bud` call itself, cutting build time roughly 3x (~13–15min → ~4min) as an unplanned side effect.

### Hostname Preservation

The upstream Bluefin image ships `/etc/hostname` with a default value. To prevent bootc from ever merging that default over a locally configured hostname (which would break Kerberos), this image ships `/etc/hostname` as an empty file via a `COPY` instruction. `RUN rm -f /etc/hostname` does not work because the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, causing "Device or resource busy". `COPY` writes directly to the image layer filesystem outside of a running container and is not subject to the bind-mount.

### Image Signing

The CI pipeline signs images with [Cosign](https://github.com/sigstore/cosign). Requires a `SIGNING_SECRET` repository secret containing the private key (generated with `COSIGN_PASSWORD="" cosign generate-key-pair`). The public key `cosign.pub` is committed to the repo. Never commit `cosign.key`.

### Justfile Environment Variables

Override defaults via environment:
- `IMAGE_NAME` (default: `bluefin-freeipa`) — used as the podman image tag
- `DEFAULT_TAG` (default: `latest`)
- `BIB_IMAGE` — the bootc-image-builder image used for disk builds
