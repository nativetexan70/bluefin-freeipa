#!/bin/bash
# Installs Homebrew into /home/linuxbrew/.linuxbrew on first real boot, and
# re-normalizes its shared prefix's group/permissions on every boot after
# that (see the comment above the chgrp/setfacl block below for why).
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

# Only run the actual installer if nothing has installed Homebrew here yet.
# This check (not ConditionPathExists on the unit) is what makes the
# install idempotent now, because the group/permission fixup below needs
# to run unconditionally every boot - see the comment above it.
if [[ ! -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    _brew_install_script="$(mktemp)"
    trap 'rm -f "${_brew_install_script}"' EXIT
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "${_brew_install_script}"
    setpriv --reuid=linuxbrew --regid=linuxbrew --init-groups \
        env HOME=/home/linuxbrew USER=linuxbrew NONINTERACTIVE=1 \
        bash "${_brew_install_script}"
fi

# The 'brew' group grants write access to the installation to local users
# and FreeIPA domain users added to it (see build.sh); users not in the
# group can still run any package that is already installed.
#
# This block runs on EVERY boot, not just once right after we install
# Homebrew ourselves above, and is guarded only on the prefix existing at
# all. That's deliberate: Homebrew's own official installer sets the
# prefix's group to "$(id -gn)" of whoever ran it - our own install step
# runs as linuxbrew (private group "linuxbrew", not "brew"), which is
# already wrong until this fixup runs, but the same is true, far worse,
# if a human ever bootstraps Homebrew themselves (e.g. this unit hasn't
# had network yet on first boot, so they just follow brew.sh's own
# instructions) - then the prefix comes out owned by *their* personal
# account and group instead, and ConditionPathExists gating this whole
# unit on "brew" already existing meant that fixup never ran again for
# that machine. Re-running it unconditionally, every boot, means whoever
# actually created the tree first no longer matters.
if [[ -d /home/linuxbrew/.linuxbrew ]]; then
    chgrp -R brew /home/linuxbrew/.linuxbrew
    chmod -R g+rwX /home/linuxbrew/.linuxbrew
    find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +

    # The chmod/setgid pair above only fixes what already exists at this
    # instant. Every later `brew install` of a new formula (Cellar/<name>/,
    # opt/<name>, etc.), `brew update`'s git working tree, and
    # var/homebrew/locks/ all create NEW files and directories - as
    # whichever brew-group member happens to run the command, not as
    # linuxbrew - and setgid only guarantees those inherit the 'brew'
    # *group*, not group-write: the actual permission bits on a newly
    # created file/dir are still cut down by that user's umask (Fedora's
    # default 022 strips group-write entirely), which is exactly what left
    # Cellar/ unwritable for a second brew-group member despite `id`
    # showing them in the group. A default ACL avoids this because it
    # isn't subject to umask the way plain mode bits are (see acl(5): a
    # default ACL on the parent, not umask, is what determines a new
    # file's group permissions), so it's what keeps everything created
    # under this prefix group-writable indefinitely, for every user and
    # umask, not just right after an install.
    setfacl -R -m g:brew:rwX -d -m g:brew:rwx /home/linuxbrew/.linuxbrew
fi
