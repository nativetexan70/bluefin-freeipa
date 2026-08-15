#!/usr/bin/env python3
"""Exclude local sudo/wheel accounts from the GDM login screen.

On a FreeIPA-joined machine, the accounts worth showing at login are
domain accounts, not this image's local ones - but GDM/AccountsService
has no supported way to reclassify an already-created account as a
"system account" after the fact (the SystemAccount D-Bus property is
read-only, confirmed live: `busctl --system set-property ...
SystemAccount b true` fails with "Property is not writable"), and no
way to know this account's future username at image-build time - it's
created later, by Anaconda kickstart or gnome-initial-setup, whichever
ISO variant is used, with a name the user picks.

So this runs at every boot instead, discovering whichever local
wheel-group account(s) actually exist right now and excluding them via
the one mechanism accounts-daemon supports for this: the [greeter]
Exclude= list in /etc/gdm/custom.conf - confirmed by the literal path
string "/etc/gdm/custom.conf" present in the installed accounts-daemon
binary itself (`strings /usr/libexec/accounts-daemon`), alongside
"user %s %ld excluded" / "user %s %ld not excluded" tracing exactly
this check.

Only genuinely local accounts can ever match here: SSSD/domain users
are resolved through NSS but are never lines in /etc/passwd itself, so
scanning /etc/passwd directly can't accidentally catch a domain user
regardless of its UID or group membership.
"""

import configparser
import subprocess
import sys

CUSTOM_CONF = "/etc/gdm/custom.conf"
UID_MIN = 1000


def local_wheel_members() -> list[str]:
    members = []
    with open("/etc/passwd", encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split(":")
            if len(fields) < 3 or not fields[2].isdigit():
                continue
            name, uid = fields[0], int(fields[2])
            if uid < UID_MIN:
                continue
            groups = subprocess.run(
                ["id", "-nG", name], capture_output=True, text=True, check=False
            ).stdout.split()
            if "wheel" in groups:
                members.append(name)
    return sorted(members)


def main() -> int:
    exclude = ",".join(local_wheel_members())

    conf = configparser.ConfigParser()
    conf.optionxform = str  # GDM's keys are case-sensitive
    conf.read(CUSTOM_CONF)

    if conf.get("greeter", "Exclude", fallback=None) == exclude:
        return 0  # nothing changed - skip the daemon restart

    if not conf.has_section("greeter"):
        conf.add_section("greeter")
    conf.set("greeter", "Exclude", exclude)

    with open(CUSTOM_CONF, "w", encoding="utf-8") as f:
        conf.write(f, space_around_delimiters=False)

    # Best-effort: accounts-daemon needs to reread the file to update its
    # cached user list. A failure here just means the change takes effect
    # on the next natural restart/reboot instead of immediately.
    subprocess.run(["systemctl", "restart", "accounts-daemon.service"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
