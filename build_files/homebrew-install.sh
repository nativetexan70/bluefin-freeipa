#!/bin/bash
# Installs Homebrew into /home/linuxbrew/.linuxbrew on first real boot.
#
# This used to run at image build time, but that wrote the entire Homebrew
# tree (thousands of files) into /var, and ostree only seeds /var from the
# image on a machine's very first deployment — every later `bootc upgrade`
# leaves an already-provisioned machine's /var untouched, so a build-time
# install was rebuilt from scratch in CI every day for no benefit to any
# already-deployed machine, and even a brand-new machine's first-day copy
# is immediately superseded by Homebrew's own `brew update` anyway. Running
# this once, on the machine, avoids all of that: it costs nothing in CI and
# nothing on machines that never end up using Homebrew.
#
# Runs as root (see homebrew-install.service); privilege-drops to the
# linuxbrew account itself for the actual install, the same way build.sh
# used to. setpriv (not runuser/su) because su/runuser invoke PAM, which
# has caused problems in this image's other privilege-drop step
# (build-time brew install) — kept consistent here even though PAM is
# available at real boot, so both code paths behave identically.

set -euo pipefail

install -d -m 0755 -o linuxbrew -g linuxbrew /var/home/linuxbrew

_brew_install_script="$(mktemp)"
trap 'rm -f "${_brew_install_script}"' EXIT
curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    -o "${_brew_install_script}"
setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
    env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
    bash "${_brew_install_script}"

# The 'brew' group grants write access to the installation to local users
# and FreeIPA domain users added to it (see build.sh); users not in the
# group can still run any package that is already installed.
chgrp -R brew /home/linuxbrew/.linuxbrew
chmod -R g+rwX /home/linuxbrew/.linuxbrew
find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +
