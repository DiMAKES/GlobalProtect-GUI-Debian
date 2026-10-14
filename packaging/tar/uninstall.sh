#!/bin/bash
# Удаление gp-vpn, установленного из архива (официальный клиент GlobalProtect остаётся)
[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"
systemctl disable --now gp-vpn-agent.service 2>/dev/null
systemctl disable --now gp-vpn-dns.path 2>/dev/null; rm -f /run/NetworkManager/conf.d/90-gp-vpn-dns.conf; nmcli general reload conf,dns-rc 2>/dev/null
while IFS= read -r f; do rm -f "/$f"; done </usr/share/gp-vpn/MANIFEST
rm -rf /usr/libexec/gp-vpn /usr/share/doc/gp-vpn /usr/share/gp-vpn /var/lib/AccountsService/users/gpvpn
systemctl daemon-reload
command -v dconf >/dev/null && dconf update
userdel -r gpvpn 2>/dev/null
echo "gp-vpn удалён."
