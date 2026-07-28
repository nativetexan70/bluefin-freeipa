## Custom ujust recipes shipped by bluefin-freeipa.
##
## Files placed at /usr/share/ublue-os/just/*.just are auto-imported by the
## base Bluefin image's top-level Justfile, making these recipes available
## via `ujust <recipe>` on the deployed system.

# Set up hibernation: swapfile, SELinux label, and resume kernel arguments
[group('System')]
setup-hibernation size="":
    #!/usr/bin/bash
    set -oue pipefail
    if [[ -n "{{ size }}" ]]; then
        sudo /usr/libexec/hibernation-setup.sh "{{ size }}"
    else
        sudo /usr/libexec/hibernation-setup.sh
    fi

# Undo setup-hibernation: remove the swapfile, fstab entry, and kernel arguments
[group('System')]
remove-hibernation:
    sudo /usr/libexec/hibernation-remove.sh

# Toggle suspend-then-hibernate: suspend first, hibernate after 90 min asleep
[group('System')]
toggle-suspend-then-hibernate:
    #!/usr/bin/bash
    set -oue pipefail
    logind_conf=/etc/systemd/logind.conf.d/50-suspend-then-hibernate.conf
    sleep_conf=/etc/systemd/sleep.conf.d/50-suspend-then-hibernate.conf
    if [[ -f "${logind_conf}" ]]; then
        sudo rm -f "${logind_conf}" "${sleep_conf}"
        echo "suspend-then-hibernate disabled; lid close and suspend key suspend normally again."
    else
        if [[ ! -f /var/swap/swapfile ]]; then
            echo "No hibernation swapfile found. Run 'ujust setup-hibernation' first."
            exit 1
        fi
        sudo mkdir -p /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d
        printf '[Login]\nHandleLidSwitch=suspend-then-hibernate\nHandleSuspendKey=suspend-then-hibernate\n' \
            | sudo tee "${logind_conf}" >/dev/null
        printf '[Sleep]\nHibernateDelaySec=90min\n' | sudo tee "${sleep_conf}" >/dev/null
        echo "suspend-then-hibernate enabled: lid close / suspend key now suspend first,"
        echo "then wake and hibernate after 90 minutes asleep (edit ${sleep_conf} to tune)."
    fi
    echo "logind reads this config at startup - reboot (or restart systemd-logind) to apply."
