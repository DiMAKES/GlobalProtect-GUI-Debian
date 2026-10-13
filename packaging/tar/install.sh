#!/bin/bash
# Установка gp-vpn из архива на любой Linux с systemd: sudo ./install.sh
set -e
[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"
cd "$(dirname "$(readlink -f "$0")")"

missing=()
python3 -c 'import gi, cairo; gi.require_version("Gtk", "3.0"); gi.require_version("Notify", "0.7"); gi.require_foreign("cairo"); from gi.repository import Gtk, Notify' 2>/dev/null ||
  missing+=("Python GTK 3 + libnotify + cairo")
for c in sudo systemctl openssl ip; do command -v "$c" >/dev/null || missing+=("$c"); done
LIBS=$(ldd root/usr/bin/gpclient root/usr/bin/gpauth | grep 'not found' | awk '{print $1}' | sort -u)
[ -z "$LIBS" ] || missing+=($LIBS)
if [ ${#missing[@]} -gt 0 ]; then
  echo "Не хватает: ${missing[*]}"
  echo "Поставьте зависимости и запустите снова:"
  echo "  Fedora/RHEL:  dnf install python3-gobject python3-cairo gtk3 libnotify webkit2gtk4.1 gnutls lz4 xxhash openssl iproute"
  echo "  openSUSE:     zypper install python3-gobject-cairo typelib-1_0-Gtk-3_0 typelib-1_0-Notify-0_7 libwebkit2gtk-4_1-0 iproute2"
  echo "  Arch:         pacman -S python-gobject python-cairo gtk3 libnotify webkit2gtk-4.1 gnutls lz4 xxhash openssl iproute2"
  echo "  Debian/Ubuntu: лучше поставить .deb"
  exit 1
fi

systemctl stop gp-vpn 2>/dev/null || true
cp -a root/. /
chmod 440 /etc/sudoers.d/gp-vpn
visudo -cf /etc/sudoers.d/gp-vpn >/dev/null
install -D -m 644 MANIFEST /usr/share/gp-vpn/MANIFEST
install -m 755 uninstall.sh /usr/share/gp-vpn/uninstall.sh
echo "Готово. Значок в трее появится после повторного входа; панель — «VPN GlobalProtect» в меню."
echo "Удаление: sudo /usr/share/gp-vpn/uninstall.sh"
