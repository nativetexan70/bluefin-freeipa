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

1. **`Containerfile`** — Two-stage build: a scratch `ctx` stage copies `build_files/` (making scripts available without embedding them in the final layer). The base image is `ghcr.io/ublue-os/bluefin:stable`. After the main `RUN` step, a `COPY` instruction ships an empty `/etc/hostname` (see Hostname Preservation below). Ends with `bootc container lint`.
2. **`build_files/build.sh`** — Executed during the container build (`RUN /ctx/build.sh`). Installs `freeipa-client`, `oddjob`, `oddjob-mkhomedir`; creates `/etc/ipa/` and `/etc/sssd/conf.d/` directory skeletons; pre-creates `/var/lib/sss/` and `/var/log/sssd/`; enables `sssd`, `oddjobd`, and `podman.socket`. Runs with `set -ouex pipefail`.
3. **`build_files/hostname`** — Empty file copied to `/etc/hostname` in the image via `COPY`. Must remain empty.
4. **GitHub Actions (`build.yml`)** — Triggers on push to `main`, PRs, and daily schedule. Builds with `buildah`, pushes to GHCR only on non-PR pushes to the default branch, signs with Cosign using `SIGNING_SECRET`.
5. **GitHub Actions (`build-disk.yml`)** — Manually triggered workflow producing `qcow2`, `anaconda-iso-gnome`, and `anaconda-iso-kde` disk images from the published OCI image using `bootc-image-builder`. Can optionally upload to S3.

### Key Files to Modify

- **Add packages or system configuration**: Edit `build_files/build.sh`
- **Change base image**: Edit the `FROM` line in `Containerfile`
- **Change disk image layout**: Edit `disk_config/disk.toml` (qcow2/raw) or `disk_config/iso-gnome.toml` / `disk_config/iso-kde.toml` (ISOs)
- **Change CI behavior or image metadata**: Edit `.github/workflows/build.yml`

### FreeIPA Join Persistence

bootc performs a three-way `/etc` merge on update: it diffs old-image `/etc` vs new-image `/etc` and applies that delta to local `/etc`. Files written by `ipa-client-install` (`sssd.conf`, `krb5.conf`, `/etc/ipa/default.conf`, etc.) are never shipped in this image, so bootc treats them as local additions and never overwrites them. The `/etc/ipa/` and `/etc/sssd/conf.d/` directories are present in the image as empty skeletons — no config content is shipped inside them.

### Chromebook SoundWire/SOF Audio Support

Many recent Chromebooks — including Tiger Lake models in Google's Volteer family (e.g. Lindar/"Lillipup") — drive audio entirely through Intel's SOF DSP over SoundWire (an RT5682 headset codec plus RT1011 speaker amps, in the Volteer case), not a conventional HD-Audio codec. Without extra setup, the desktop shows only a routeless "Dummy Output" sink and the speakers are silent. Three independent fixes are needed, and `build.sh` applies all three:

- **Kernel driver claim.** `snd-intel-dspcfg`'s `dsp_driver` option must stay at auto (`0`) or SOF (`3`); a `dsp_driver=1` (legacy HD-Audio) override — e.g. an `/etc/modprobe.d/alsa-legacy.conf` — stops SOF from ever claiming the controller, so no ASoC sound card is registered at all (not even at the kernel level). This image ships no such override, but `build.sh` removes one defensively (`rm -f /etc/modprobe.d/alsa-legacy.conf`) in case a future base-image layer adds it.
- **ALSA UCM profile.** Once the card exists, WirePlumber/PipeWire still need an ALSA UCM (Use Case Manager) profile to build real routes — a card with no matching profile only gets the routeless stereo-fallback node. Upstream `alsa-ucm-conf` doesn't cover every Chromebook SOF card name (e.g. `sof-rt5682`). `build.sh` installs `alsa-sof-firmware` and `alsa-ucm` (the Fedora package providing `/usr/share/alsa/ucm2`), then layers the community-maintained [alsa-ucm-conf-cros](https://github.com/WeirdTreeThing/alsa-ucm-conf-cros) overlay (`ucm2/` for new profiles, `overrides/` replacing incomplete upstream ones) on top of `/usr/share/alsa/ucm2/`, fetched from its `standalone` branch (its only/default branch) at build time so it stays current as the image is rebuilt. Its profiles detect the board/codec at runtime via DMI `product_family` and i2c modalias probing, so this one overlay covers many Chromebook SOF boards, not just Tiger Lake/Volteer.
- **No early driver claim in the initramfs.** The initramfs regenerated at build time (see below, under Hostname/Plymouth) runs in dracut's "generic" (`--no-hostonly`) mode, which bundles every driver dracut finds under the kernel's module tree — including the whole `sound/` tree, legacy `snd_hda_intel` alongside the SOF stack. initramfs's udev coldplug autoloads matching drivers for every PCI device it sees, including the audio controller, before switch-root — while the real root's SOF firmware and UCM profiles aren't mounted yet. A driver bound that early can leave the controller stuck on the wrong (or non-functional) driver for the rest of boot, since driver bindings don't get undone across switch-root. No audio driver is ever needed pre-switch-root, so `build.sh` passes `--omit-drivers` with every module name found under that kernel's own `kernel/sound/` tree, excluding the whole category from the initramfs and leaving driver selection to happen exactly once, on the real root.

### Hostname Preservation

The upstream Bluefin image ships `/etc/hostname` with a default value. To prevent bootc from ever merging that default over a locally configured hostname (which would break Kerberos), this image ships `/etc/hostname` as an empty file via a `COPY` instruction. `RUN rm -f /etc/hostname` does not work because the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, causing "Device or resource busy". `COPY` writes directly to the image layer filesystem outside of a running container and is not subject to the bind-mount.

### Image Signing

The CI pipeline signs images with [Cosign](https://github.com/sigstore/cosign). Requires a `SIGNING_SECRET` repository secret containing the private key (generated with `COSIGN_PASSWORD="" cosign generate-key-pair`). The public key `cosign.pub` is committed to the repo. Never commit `cosign.key`.

### Justfile Environment Variables

Override defaults via environment:
- `IMAGE_NAME` (default: `bluefin-freeipa`) — used as the podman image tag
- `DEFAULT_TAG` (default: `latest`)
- `BIB_IMAGE` — the bootc-image-builder image used for disk builds
