# bluefin-freeipa

A custom [bootc](https://github.com/bootc-dev/bootc) image layered on [Bluefin](https://github.com/ublue-os/bluefin) (Universal Blue) that ships `freeipa-client` pre-installed, along with all required dependencies. The image is built and published automatically to GHCR via GitHub Actions and is designed so that an existing FreeIPA domain join survives `bootc` updates.

Published image: `ghcr.io/personalcyber/bluefin-freeipa:latest`

---

# Switching to This Image

## From an Existing Bazzite or Universal Blue System

If you are already running a bootc-based system (Bazzite, Bluefin, Aurora, etc.), switching requires a single command and a reboot. No reinstall is needed.

```bash
sudo bootc switch ghcr.io/personalcyber/bluefin-freeipa:latest
```

`bootc switch` stages the new image. The switch takes effect on the next reboot.

```bash
systemctl reboot
```

After rebooting, confirm you are on the new image:

```bash
sudo bootc status
```

> [!NOTE]
> If your current system is already joined to a FreeIPA domain, the join state is preserved. See [FreeIPA Join Persistence](#freeipa-join-persistence) below for details on how this works.

## From a Non-bootc Fedora or RPM-based System

A fresh install using an ISO is the recommended path. Download or build an ISO from this repository (see [Building Disk Images](#building-disk-images)) and boot from it. The installer's post-install script automatically switches the new system to `ghcr.io/personalcyber/bluefin-freeipa:latest`.

---

# Setting Up FreeIPA Client

The `freeipa-client`, `sssd`, `oddjob`, and `oddjob-mkhomedir` packages are pre-installed in this image. After switching or installing, join the machine to your FreeIPA domain using `ipa-client-install`.

## Prerequisites

- Network access to your FreeIPA server (DNS must be resolvable)
- A one-time password or admin credentials for enrollment

## Joining the Domain

```bash
sudo ipa-client-install \
    --domain=your.domain.example \
    --server=ipa.your.domain.example \
    --realm=YOUR.DOMAIN.EXAMPLE \
    --mkhomedir \
    --no-ntp
```

Key flags:
- `--mkhomedir` — creates home directories on first login via `oddjob-mkhomedir`, which is enabled in this image
- `--no-ntp` — recommended if NTP is already managed by another service (e.g., `systemd-timesyncd` or Chrony on your network)
- `--unattended` — add this flag for scripted/automated enrollment together with `--password`

`ipa-client-install` will write and own `/etc/ipa/default.conf`, `/etc/sssd/sssd.conf`, `/etc/krb5.conf`, and related files. These are treated as local files by bootc and will not be overwritten by image updates.

After the join completes, verify that `sssd` is running:

```bash
systemctl status sssd
```

And test that a domain user can be resolved:

```bash
id <domain-username>
```

## Leaving the Domain

To remove the machine from FreeIPA cleanly:

```bash
sudo ipa-client-install --uninstall
```

## Login Screen

This image's GDM login screen is meant to list domain accounts, not this image's one local (sudo/wheel) fallback account. GDM's account list is populated by AccountsService as accounts actually log in — this happens the same way for local and domain accounts alike, so domain accounts need nothing special to eventually appear there; a `hide-local-admins-gdm.service` unit runs at every boot to keep the local admin account specifically out of the list (via GDM's `[greeter] Exclude=` mechanism in `/etc/gdm/custom.conf`), since AccountsService has no supported way to reclassify an account as hidden after it's already been created.

Both accounts still log in the same way — the local admin account isn't disabled, just excluded from the clickable list. If GDM shows no account at all yet (e.g. right after first boot, before anyone has logged in), typing a username at the prompt works as normal.

---

# FreeIPA Join Persistence

This image is specifically designed so that an existing domain join survives `bootc` updates. Here is how it works.

When `bootc` applies an update it performs a **three-way merge** of `/etc`:

1. It diffs the old image's `/etc` against the new image's `/etc`.
2. It applies that delta to your local `/etc`.

Files that exist locally but are **not present in the image** are treated as local additions and are never touched. This image deliberately ships the directory skeletons `/etc/ipa/` and `/etc/sssd/conf.d/` but ships **no config file content** inside them. Every file that `ipa-client-install` writes — `sssd.conf`, `default.conf`, `krb5.conf`, etc. — is therefore a local addition that bootc will never overwrite.

Runtime state (`/var/lib/sss/`, `/var/log/sssd/`) lives under `/var`, which bootc never modifies.

**In practice:** after a `bootc update` and reboot, `sssd` comes back up reading the same config it had before the update, and domain authentication continues without any intervention.

### What Could Break a Join

- Manually editing a file that a future image version also ships (currently none, by design)
- Running `ipa-client-install --uninstall` before updating, then expecting the join to survive

---

# Changes to the Base Bluefin Image

This image is built on top of `ghcr.io/ublue-os/bluefin:stable` and makes the following deliberate modifications to support FreeIPA client functionality and ensure it persists across `bootc` updates.

## Packages Added

| Package | Purpose |
|---|---|
| `freeipa-client` | Core FreeIPA client tooling (`ipa-client-install`, `ipa` CLI). Also pulls in `sssd`, `krb5-workstation`, `certmonger`, and other required dependencies. |
| `oddjob` | D-Bus service that allows `sssd` to perform privileged operations (e.g. creating home directories) on behalf of unprivileged processes. |
| `oddjob-mkhomedir` | PAM module and helper that automatically creates a home directory on first login for domain users. |

## Systemd Units Enabled

| Unit | Purpose |
|---|---|
| `sssd` | System Security Services Daemon — handles Kerberos authentication, LDAP user/group lookups, and caching for the FreeIPA domain. |
| `oddjobd` | D-Bus daemon for `oddjob`. Must be running for `pam_oddjob_mkhomedir` to create home directories at login. |
| `podman.socket` | Inherited from the Bluefin base; retained for rootless container support. |
| `homebrew-install.service` | One-time, first-boot-only unit that installs Homebrew (see below). Skips on every later boot once installed. |

## Homebrew

[Homebrew](https://brew.sh) is installed system-wide at `/home/linuxbrew/.linuxbrew` and is available to every user — including FreeIPA domain users — without any per-user setup.

The brew environment is sourced automatically for all login and interactive shells via `/etc/profile.d/brew.sh`. No manual PATH configuration is required.

### Installed on first boot, not baked into the image

Unlike most of this image's other content, Homebrew is **not** present at `t=0` of first boot — it's installed by a one-time `systemd` unit (`homebrew-install.service`) the first time the machine boots with network access, then never touched again. The `linuxbrew` user/`brew` group themselves *are* present from the very first boot (declared in the image via a pinned `systemd-sysusers.d` entry); only the actual Homebrew files are deferred.

This means:
- **First boot needs network access** before `brew` actually works. If the very first boot has no network, the install unit fails harmlessly and retries automatically on the next boot.
- Once installed, Homebrew is never touched by `bootc upgrade` — ostree only seeds `/var` from the image on a machine's first deployment, so the install is effectively permanent per-machine from that point on, the same as if it had shipped in the image. Packages you install via `brew` afterward are equally unaffected by image updates.
- You can check progress or force a retry with `systemctl status homebrew-install.service` / `sudo systemctl restart homebrew-install.service`.

### Running installed packages

All users can run any package already installed in the shared prefix without any additional configuration. The `brew` command itself is in PATH for every user.

### Installing new packages (write access)

Package installation requires write access to the shared prefix. Access is controlled by the `brew` group.

**Self-service, for the currently logged-in user (local or FreeIPA domain):**

```bash
ujust enable-brew-install
```

This adds `$USER` to the local `brew` group via `sudo usermod -aG brew`. It works the same way for FreeIPA domain users as it does for local accounts — group membership is just an entry in the local `/etc/group` file keyed by username, and NSS resolves domain usernames through `sssd` the same way it resolves local ones.

**For an admin granting access to another user:**

```bash
sudo usermod -aG brew <username-or-domain-username>
```

Run this on each host where the user needs install access, or manage it centrally via an IPA sudo rule or HBAC rule that grants `usermod` privileges to a designated admin group.

In both cases, the user must log out and back in (or run `newgrp brew`) for the group change to take effect.

> [!NOTE]
> Users not in the `brew` group can still run any package that is already installed. Only writing new packages to the shared prefix requires group membership.

New packages you install stay writable for every `brew` group member afterward too — the prefix carries a default ACL (set up by `homebrew-install.service`) granting the `brew` group write access to anything created under it later, so a `brew install` you run isn't left owned by a group but with permission bits your own umask happened to strip.

## /etc Directory Skeleton

`ipa-client-install` writes its configuration into `/etc/ipa/`, `/etc/sssd/`, and `/etc/krb5.conf`. For bootc's three-way `/etc` merge to treat those files as local additions (and therefore never overwrite them on update), the directories must exist in the image but must contain no config file content.

This image creates the following empty directory skeletons at build time:

| Path | Permissions | Purpose |
|---|---|---|
| `/etc/ipa/` | `0755` | Root directory for IPA client config. `ipa-client-install` writes `default.conf` here. |
| `/etc/sssd/conf.d/` | `0750` | Drop-in directory for SSSD config fragments. `ipa-client-install` writes `sssd.conf` one level up. |

No config files are shipped inside these paths. Every file written by `ipa-client-install` is a local addition from bootc's perspective and will never be touched by an image update.

## /var State Directories

SSSD's, certmonger's, and `ipa-client`'s cache/runtime/state directories all live under `/var`, which bootc never modifies after a machine's first deployment. sssd's are declared via `systemd-tmpfiles` (a `var-state.conf` shipped to `/usr/lib/tmpfiles.d/`) rather than existing in the image directly — `systemd-tmpfiles-setup.service` creates them fresh on every first boot, before `sssd` starts, so there's no race and nothing baked into the image for them. certmonger's and `ipa-client`'s are created by their own RPM packages regardless, but are declared in the same file too so they're documented as intentional rather than incidental build artifacts:

| Path | Permissions | Owner |
|---|---|---|
| `/var/lib/sss/db` | `0711` | root |
| `/var/lib/sss/pipes/private` | `0755` | root |
| `/var/lib/sss/keytabs` | `0770` | sssd |
| `/var/log/sssd` | `0755` | root |
| `/var/lib/certmonger`, `/cas`, `/local`, `/requests` | `0755` / `0700` | root |
| `/var/lib/ipa-client`, `/pki`, `/sysrestore` | `0755` | root |

## Hostname Preservation

The upstream Bluefin image ships `/etc/hostname` containing a default value. If bootc's three-way merge applies a new image that still contains that default, and the local hostname has never been changed from the default, the hostname can be reset — breaking Kerberos, which ties tickets to the machine's FQDN.

This image ships `/etc/hostname` as an **empty file**, written via a `COPY` instruction in the Containerfile (not a `RUN` step — the OCI build runtime bind-mounts `/etc/hostname` into every `RUN` container, making `rm` fail with *Device or resource busy*). With an empty file in the image, bootc has no meaningful upstream value to merge against, and the hostname set during installation or by `hostnamectl` is always preserved across updates.

> [!IMPORTANT]
> Set the correct FQDN hostname **before** running `ipa-client-install`. The hostname is baked into the Kerberos principal and LDAP host entry at join time.
>
> ```bash
> sudo hostnamectl set-hostname myhost.your.domain.example
> ```

---

# Keeping the Image Updated

`bootc` checks for and stages updates automatically if the `bootc-fetch-apply-updates.timer` systemd unit is enabled. To enable automatic updates:

```bash
sudo systemctl enable --now bootc-fetch-apply-updates.timer
```

Updates are staged in the background and applied on the next reboot. A reboot does **not** happen automatically unless you also configure a reboot schedule.

To trigger a manual update check:

```bash
sudo bootc upgrade
```

## Troubleshooting: Unverified Registry Warning

If `bootc upgrade` shows a message like:

```
Pulling manifest: ostree-unverified-registry:ghcr.io/personalcyber/bluefin-freeipa:latest
```

This means the running system does not yet have the cosign signature policy installed. The policy files are baked into this image and take effect automatically on all future upgrades **after** the first one — but the very first upgrade from an older image (or from a switched system) still runs without them.

**One-time fix:** install the policy files manually, then run the upgrade:

```bash
# Install the cosign public key
sudo mkdir -p /etc/pki/containers
sudo curl -fsSL https://raw.githubusercontent.com/personalcyber/bluefin-freeipa/main/build_files/cosign.pub \
    -o /etc/pki/containers/bluefin-freeipa.pub

# Install the signature policy
sudo curl -fsSL https://raw.githubusercontent.com/personalcyber/bluefin-freeipa/main/build_files/policy.json \
    -o /etc/containers/policy.json

# Install the sigstore registry config
sudo mkdir -p /etc/containers/registries.d
sudo curl -fsSL https://raw.githubusercontent.com/personalcyber/bluefin-freeipa/main/build_files/registries.d-personalcyber.yaml \
    -o /etc/containers/registries.d/ghcr.io-personalcyber.yaml

sudo bootc upgrade
```

After rebooting into the new image, all subsequent upgrades will show `ostree-image-signed` and no further action is needed.

## Troubleshooting: SELinux Permission Errors During Switch or Upgrade

If `bootc switch` or `bootc upgrade` fails with an error like:

```
Switching (ostree): Pulling: Importing: Writing merged filesystem to mtree:
Writing content object: Setting xattrs: fsetxattr(security.selinux): Permission denied
```

This means the bootc process lacks the `CAP_MAC_ADMIN` Linux capability needed to write SELinux security labels onto files in the new image layer. It is most common when switching between different base images (e.g. Bazzite → bluefin-freeipa) but can also occur on first upgrade to a new major image version.

**Workaround:** Put SELinux into permissive mode for the duration of the switch, then reboot:

```bash
sudo setenforce 0
sudo bootc switch ghcr.io/personalcyber/bluefin-freeipa:latest
# or: sudo bootc upgrade
sudo setenforce 1
systemctl reboot
```

`setenforce 0` is transient — it only lasts until the next reboot. On first boot into the new image, the deployed image's own SELinux policy activates and the filesystem is automatically relabeled. This is safe because security is restored as soon as the new image boots.

> [!NOTE]
> If you are switching from a non-bootc system or a completely different distribution, a fresh install from the [installer ISO](#building-disk-images-locally) is the more reliable path.

## Troubleshooting: No Sound on Chromebook Hardware (SOF DSP Boot Failure)

This image installs everything the SOF/SoundWire audio stack needs (firmware, UCM profiles — see the Containerfile build script), but on Chromebooks converted to run this image via [MrChromebox](https://mrchromebox.tech) coreboot firmware, audio can still fail completely: `aplay -l` / `/proc/asound/cards` shows no sound card at all, and `journalctl -k` shows the DSP repeatedly failing to boot:

```
sof-audio-pci-intel-tgl 0000:00:1f.3: cl_dsp_init: timeout with rom_status_reg (0x80000) read
sof-audio-pci-intel-tgl 0000:00:1f.3: 0x06000021: module: ROM, state: CSE_IPC_RESET_PHASE_1, waiting for: CSE_CSR, running
sof-audio-pci-intel-tgl 0000:00:1f.3: error: dsp init failed after 3 attempts with err: -110
```

**Root cause:** on Tiger Lake-class hardware (e.g. Google Volteer/"Lindar"), the audio DSP's firmware image is not loaded directly — it's authenticated through a handshake with the platform's CSE (Converged Security Engine), which is the same subsystem as the Intel Management Engine (ME). MrChromebox's firmware utility exposes ME on/off as a user-configurable option during flashing (common on Chromebook conversions, for privacy/security reasons). **If ME is disabled, CSE never boots, so the DSP ROM's authentication handshake has nothing to answer it** — it times out three times (`-110` = `ETIMEDOUT`) and no sound card is ever registered. This is a firmware-level dependency; no kernel parameter, SOF firmware variant (IPC3 vs IPC4), or driver choice on the OS side can work around it — forcing the older AVS driver (`snd_intel_dspcfg.dsp_driver=4`) confirms this, since AVS's simpler, pre-cAVS-secure-boot firmware-loading path does get past the CSE handshake, but Fedora doesn't ship an AVS firmware blob for Tiger Lake, so it's not a usable fix either — only useful as a diagnostic to confirm CSE is the actual blocker.

**Fix:** re-enable Intel ME in [MrChromebox's firmware utility](https://mrchromebox.tech) (ME-mode option) and reflash. Once CSE is running, `sof-audio-pci-intel-tgl` completes its firmware boot normally and the SoundWire card (e.g. `rt5682`/`rt1011`) is registered, at which point this image's UCM overlay (see the Containerfile build script) takes over correctly.

## Chromebook Keyboard Input Source

This image registers **"English (Chromebook)"** as a selectable entry in GNOME Settings → Region & Language → Input Sources → Add an Input Source. Selecting it is what activates everything below — plain "English (US)" is left as a completely standard layout.

On Chromebooks converted to run this image via MrChromebox firmware, the Search/Launcher key, the action-key top row (back/forward/refresh/brightness/volume), and the Overview key are already remapped to their correct keycodes by firmware/kernel defaults and picked up automatically by **every** keyboard layout, so those parts need nothing from this variant. What it adds is the ChromeOS Search-key combos that need somewhere to go — this hardware has no dedicated Home, End, Page Up, Page Down, or Delete keys at all, since ChromeOS only ever reaches them via `Search` held with another key. Since `Search` is already this image's `Super` key, there's no key left free to play that role, so the Chromebook variant uses **Right Alt** instead:

| Combo | Result |
|---|---|
| `Right Alt + ←` | Home |
| `Right Alt + →` | End |
| `Right Alt + ↑` | Page Up |
| `Right Alt + ↓` | Page Down |
| `Right Alt + Backspace` | Delete |
| `Right Alt + Esc` | Task Manager (opens `gnome-system-monitor`) |

The first five work in every application automatically — they produce real `Home`/`End`/`Page Up`/`Page Down`/`Delete` keypresses, not a desktop-specific shortcut, and `Shift` still combines normally on top (e.g. `Right Alt+Shift+←` still extends a text selection). `Right Alt + Esc` is the one ChromeOS combo (`Search+Esc` → task manager) with no GNOME equivalent, so it's wired to a system-wide custom keybinding instead.

Two other ChromeOS Search-combos need nothing from this image at all, because `Search` is already `Super` here and GNOME's own defaults already do the same thing: **lock screen** (`Search+L` → GNOME's stock `Super+L`) and **launch/switch to the Nth pinned app** (`Search+1`–`9` → GNOME Shell's stock `Super+1`–`9`).

(Separately, `localectl set-x11-keymap <layout> <variant> chromebook` sets the XKB *model* to `chromebook`, which only affects on-screen-keyboard geometry graphics — unrelated to, and not required alongside, the input source above.)

---

# Building the Image Locally

Requires [just](https://just.systems/) and [podman](https://podman.io/). Both are available by default on all Universal Blue images.

```bash
just build          # Build the container image
just lint           # Run shellcheck on all shell scripts
just format         # Run shfmt on all shell scripts
just check          # Validate Justfile syntax
just clean          # Remove local build artifacts
```

---

# Building Disk Images Locally

Disk images (QCOW2 and installer ISOs) are produced by [bootc-image-builder](https://github.com/osbuild/bootc-image-builder) running as a privileged Podman container. `just` and `podman` are required. Both are available by default on all Universal Blue images.

> [!IMPORTANT]
> ISO builds require the published OCI image to be accessible. The `build-iso-*` targets use the locally built container image (`localhost/bluefin-freeipa:latest`). The `rebuild-iso-*` targets rebuild the container image first.

## Build Sequence

Always follow this order when building locally:

1. **Build the container image** — this produces `localhost/bluefin-freeipa:latest` in your local Podman store:

   ```bash
   just build
   ```

2. **Build the disk image** — this invokes bootc-image-builder against the locally built image:

   ```bash
   just build-iso-gnome    # Anaconda installer ISO (GNOME desktop)
   just build-iso-kde      # Anaconda installer ISO (KDE desktop)
   just build-qcow2        # QCOW2 virtual machine image
   ```

   Output is written to `output/` in the repository root.

   If you want to rebuild the container image and the disk image in a single step, use the `rebuild-*` variants instead:

   ```bash
   just rebuild-iso-gnome
   just rebuild-iso-kde
   just rebuild-qcow2
   ```

> [!NOTE]
> `just build-iso-gnome` (and the other `build-*` targets) do **not** rebuild the container image. If you have made changes to `build_files/build.sh` or `Containerfile`, run `just build` first, or use `just rebuild-iso-gnome` to do both steps automatically.

## Running a Built Image in a VM

After a successful build you can boot the image locally in a browser-based VM:

```bash
just run-vm-qcow2       # Boot the QCOW2 image (opens browser at localhost:8006+)
just run-vm-iso-gnome   # Boot the GNOME ISO in a VM
just run-vm-iso-kde     # Boot the KDE ISO in a VM
```

The VM runner requires `podman` and KVM (`/dev/kvm`). A browser window opens automatically after ~30 seconds.

## Output Files

| Target | Output path |
|---|---|
| `build-qcow2` | `output/qcow2/disk.qcow2` |
| `build-iso-gnome` | `output/bootiso/install.iso` |
| `build-iso-kde` | `output/bootiso/install.iso` |

Run `just clean` to remove all build artifacts.

---

# Building Disk Images via GitHub Actions

The [build-disk.yml](./.github/workflows/build-disk.yml) workflow builds installable disk images (`qcow2`, `anaconda-iso-gnome`, and `anaconda-iso-kde`) from the **published** OCI image at `ghcr.io/personalcyber/bluefin-freeipa:latest`. Trigger it manually from the **Actions** tab, selecting `amd64` or `arm64`.

> [!NOTE]
> The GitHub Actions workflow uses the last image pushed to GHCR, not your local build. Push your changes and wait for the `build.yml` workflow to complete before triggering `build-disk.yml`.

The ISO kickstart is pre-configured to switch a newly installed system to `ghcr.io/personalcyber/bluefin-freeipa:latest` automatically.

To upload disk images to S3, add the following repository secrets under `Settings` → `Secrets and Variables` → `Actions`:

| Secret | Description |
|---|---|
| `S3_PROVIDER` | Provider name from the [rclone S3 list](https://rclone.org/s3/) |
| `S3_BUCKET_NAME` | Your bucket name |
| `S3_ACCESS_KEY_ID` | Access key for the bucket |
| `S3_SECRET_ACCESS_KEY` | Secret key for the bucket |
| `S3_REGION` | Bucket region (`auto` if unknown) |
| `S3_ENDPOINT` | Provider-specific endpoint URL |

---

# Image Signing

Images pushed to GHCR are signed with [Cosign](https://github.com/sigstore/cosign) using a key stored as the `SIGNING_SECRET` repository secret. The public key is at [`cosign.pub`](./cosign.pub).

To verify an image locally:

```bash
cosign verify --key cosign.pub ghcr.io/personalcyber/bluefin-freeipa:latest
```

> [!WARNING]
> Never commit `cosign.key` to the repository. Only `cosign.pub` is safe to commit.

---

# Community

- [Universal Blue Forums](https://universal-blue.discourse.group/)
- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions)
