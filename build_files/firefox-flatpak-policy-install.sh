#!/bin/bash
# Installs this image's Firefox enterprise policy into the one place the
# Firefox Flatpak actually reads system-wide policy from.
#
# The Flatpak build of Firefox is sandboxed and can't see the host's
# /etc/firefox at all - the classic /etc/firefox/policies/policies.json
# path (or firefox/distribution/policies.json) that native-package
# Firefox reads is invisible to it. The mechanism it does honor instead
# is the org.mozilla.firefox.systemconfig Flatpak extension: Firefox
# looks for a policies.json under that extension's directory tree, at
#
#   /var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/<arch>/<branch>/policies/policies.json
#
# Nothing needs to be `flatpak install`ed to make this exist - the
# extension directory is just a path convention accounts-daemon-style
# tooling (here, this script) is expected to populate directly; no
# flatpak metadata/ref needs to be registered for it.
#
# <arch> and <branch> aren't knowable at image build time, and
# /var/lib/flatpak itself isn't part of this image's own /var at build
# time either (ostree only seeds /var from the image on a machine's very
# first deployment, and Firefox's own Flatpak install may not even have
# happened by then - see build.sh's Homebrew section for the same
# distinction). So this runs at every boot instead of once, discovering
# whichever arch/branch Firefox is actually installed as right now via
# `flatpak list`, and is a harmless no-op whenever Firefox isn't
# installed as a system Flatpak yet.

set -euo pipefail

POLICY_SRC=/usr/share/bluefin-freeipa/firefox-flatpak-policies.json

flatpak list --system --app --columns=application,arch,branch 2>/dev/null |
    while read -r app arch branch; do
        [[ "${app}" == "org.mozilla.firefox" ]] || continue

        dest="/var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/${arch}/${branch}/policies/policies.json"

        # Idempotent: skip the copy (and the pointless mtime bump) if the
        # installed policy already matches this image's copy.
        if ! cmp -s "${POLICY_SRC}" "${dest}" 2>/dev/null; then
            install -Dm644 "${POLICY_SRC}" "${dest}"
        fi
    done
