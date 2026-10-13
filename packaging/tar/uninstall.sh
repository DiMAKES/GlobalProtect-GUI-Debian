#!/bin/bash
# Удаление gp-vpn, установленного из архива (официальный клиент GlobalProtect остаётся)
[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"
systemctl disable --now gp-vpn-agent.service 2>/dev/null
while IFS= read -r f; do rm -f "/$f"; done </usr/share/gp-vpn/MANIFEST
rm -rf /usr/libexec/gp-vpn /usr/share/doc/gp-vpn /usr/share/gp-vpn /var/lib/AccountsService/users/gpvpn
systemctl daemon-reload
command -v dconf >/dev/null && dconf update
userdel -r gpvpn 2>/dev/null
echo "gp-vpn удалён."
