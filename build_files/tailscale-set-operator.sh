#!/bin/bash
# Sets the invoking user as the Tailscale operator, so tailscale/trayscale
# commands work for that user without repeated sudo prompts (trayscale has
# no privilege-escalation UI of its own, and by default only root can
# control tailscaled — see README "Tailscale/Trayscale Operator").
#
# Deliberately takes no arguments: it always operates on whichever user
# invoked it via sudo, read from SUDO_USER (always set by sudo itself,
# unaffected by env_reset). This lets the sudoers rule that grants NOPASSWD
# access to this script match on the exact path with no wildcard, so a user
# can only ever make themselves the operator, never another account.
set -euo pipefail

target_user="${SUDO_USER:?tailscale-set-operator must be run via sudo}"
exec /usr/bin/tailscale set --operator="$target_user"
