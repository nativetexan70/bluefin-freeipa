# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A custom [bootc](https://github.com/bootc-dev/bootc) OCI image layered on top of `ghcr.io/ublue-os/bluefin:stable` (a Universal Blue image), adding FreeIPA client support and the [Fleet](https://fleetdm.com) agent (`fleetd`). Images are built via GitHub Actions and published to `ghcr.io/personalcyber/bluefin-freeipa`. The image is designed so that a FreeIPA domain join and a Fleet enrollment both survive `bootc` updates via bootc's three-way `/etc` merge.

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
2. **`build_files/build.sh`** — Executed during the container build (`RUN /ctx/build.sh`). Installs `freeipa-client`, `oddjob`, `oddjob-mkhomedir`; creates `/etc/ipa/` and `/etc/sssd/conf.d/` directory skeletons; pre-creates `/var/lib/sss/` and `/var/log/sssd/`; builds and installs `fleetd` (Fleet's agent) via `fleetctl package --type=rpm` (no `--fleet-url`/`--enroll-secret`) and truncates `/etc/default/orbit` to empty; enables `sssd`, `oddjobd`, `podman.socket`, and `orbit`. Runs with `set -ouex pipefail`.
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

### Fleet Agent Persistence

`fleetd` (Orbit + osqueryd) is built in `build.sh` via `fleetctl package --type=rpm`, with no `--fleet-url`/`--enroll-secret` passed (`--use-system-configuration` expresses the same intent but is only accepted for `--type=pkg`/`msi`), which produces an RPM that does not have a Fleet URL or enroll secret compiled in. Instead, Orbit's systemd unit reads `ORBIT_FLEET_URL`/`ORBIT_ENROLL_SECRET` (and related settings) from `/etc/default/orbit` via `EnvironmentFile` at runtime. `build.sh` truncates that file to empty after installing the package, so the same three-way `/etc` merge that protects the FreeIPA join protects Fleet enrollment: whatever an admin writes into `/etc/default/orbit` post-deployment is a local addition bootc never overwrites. Orbit's runtime state lives under `/opt/orbit`, which the Bluefin base image symlinks to `/var/opt/orbit` — mutable and preserved across updates like any other `/var` path.

### Hostname Preservation

The upstream Bluefin image ships `/etc/hostname` with a default value. To prevent bootc from ever merging that default over a locally configured hostname (which would break Kerberos), this image ships `/etc/hostname` as an empty file via a `COPY` instruction. `RUN rm -f /etc/hostname` does not work because the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, causing "Device or resource busy". `COPY` writes directly to the image layer filesystem outside of a running container and is not subject to the bind-mount.

### Image Signing

The CI pipeline signs images with [Cosign](https://github.com/sigstore/cosign). Requires a `SIGNING_SECRET` repository secret containing the private key (generated with `COSIGN_PASSWORD="" cosign generate-key-pair`). The public key `cosign.pub` is committed to the repo. Never commit `cosign.key`.

### Justfile Environment Variables

Override defaults via environment:
- `IMAGE_NAME` (default: `bluefin-freeipa`) — used as the podman image tag
- `DEFAULT_TAG` (default: `latest`)
- `BIB_IMAGE` — the bootc-image-builder image used for disk builds
