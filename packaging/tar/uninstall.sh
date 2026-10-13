#!/bin/bash
# Удаление gp-vpn, установленного из архива
[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"
systemctl stop gp-vpn 2>/dev/null
while IFS= read -r f; do rm -f "/$f"; done </usr/share/gp-vpn/MANIFEST
rm -rf /usr/libexec/gp-vpn /usr/libexec/gpclient /usr/share/doc/gp-vpn /usr/share/gp-vpn /var/lib/gp-vpn
echo "gp-vpn удалён."
