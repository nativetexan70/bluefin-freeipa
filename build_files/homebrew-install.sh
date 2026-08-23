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

# The chmod/setgid pair above only fixes what already exists at this
# instant. Every later `brew install` of a new formula (Cellar/<name>/,
# opt/<name>, etc.), `brew update`'s git working tree, and var/homebrew/
# locks/ all create NEW files and directories - as whichever brew-group
# member happens to run the command, not as linuxbrew - and setgid only
# guarantees those inherit the 'brew' *group*, not group-write: the
# actual permission bits on a newly created file/dir are still cut down
# by that user's umask (Fedora's default 022 strips group-write
# entirely), which is exactly what left Cellar/ unwritable for a second
# brew-group member despite `id` showing them in the group. A default
# ACL avoids this because it isn't subject to umask the way plain mode
# bits are (see acl(5): a default ACL on the parent, not umask, is what
# determines a new file's group permissions), so it's what keeps
# everything created under this prefix group-writable indefinitely,
# for every user and umask, not just at this first-boot install.
setfacl -R -m g:brew:rwX -d -m g:brew:rwx /home/linuxbrew/.linuxbrew
