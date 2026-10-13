#!/bin/bash
# Сборка пакетов gp-vpn — надстройки над официальным GlobalProtect (Palo Alto) для Linux.
# Сам клиент Palo Alto в пакеты не входит: его выдаёт организация (пакет globalprotect, CLI-версия).
#
#   ./build.sh            все форматы: deb, rpm, tar
#   ./build.sh deb        только нужные
#
# dist/ — готовые пакеты и SHA256SUMS. Для rpm нужен rpmbuild (apt install rpm).
set -eo pipefail
umask 022
cd "$(dirname "$(readlink -f "$0")")"

VERSION=3.1
URL=https://github.com/DiMAKES/GlobalProtect-GUI-Debian
MAINTAINER=${MAINTAINER:-"$(git config user.name 2>/dev/null || echo gp-vpn) <$(git config user.email 2>/dev/null || echo root@localhost)>"}
FORMATS=${*:-deb rpm tar}
DESC="Windows-like tray panel for the official GlobalProtect client"

B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
mkdir -p dist

stage() {  # $1 — дерево пакета
  local R=$1
  install -D -m 755 src/gp-vpn-tray  "$R/usr/bin/gp-vpn-tray"
  install -D -m 644 src/gpvpn.py     "$R/usr/lib/gp-vpn/gpvpn.py"
  install -D -m 755 src/gp           "$R/usr/libexec/gp-vpn/gp"
  install -D -m 755 src/gp-vpn-setup "$R/usr/libexec/gp-vpn/setup"
  install -D -m 644 src/gp-vpn-agent.service "$R/usr/lib/systemd/system/gp-vpn-agent.service"
  install -D -m 644 src/gpa-gp-vpn.conf      "$R/etc/systemd/user/gpa.service.d/gp-vpn.conf"
  install -D -m 440 src/gp-vpn.sudoers       "$R/etc/sudoers.d/gp-vpn"
  install -D -m 644 src/gp-vpn.desktop         "$R/usr/share/applications/gp-vpn.desktop"
  local X=usr/share/gnome-shell/extensions/gp-vpn@dimakes.github.io  # экран входа и блокировки
  for f in metadata.json extension.js stylesheet.css; do
    install -D -m 644 "src/shell-extension/gp-vpn@dimakes.github.io/$f" "$R/$X/$f"
  done
  install -D -m 644 src/gp-vpn-gdm.dconf "$R/etc/dconf/db/gdm.d/90-gp-vpn"
  install -D -m 644 src/gp-vpn-tray.desktop    "$R/etc/xdg/autostart/gp-vpn-tray.desktop"            # сеанс
  install -D -m 644 LICENSE   "$R/usr/share/doc/gp-vpn/LICENSE"
  install -D -m 644 README.md "$R/usr/share/doc/gp-vpn/README.md"
  cat > "$R/usr/share/doc/gp-vpn/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: GlobalProtect-GUI-Debian
Source: $URL

Files: *
Copyright: $(date +%Y) $MAINTAINER
License: GPL-3.0+
 Full text: /usr/share/doc/gp-vpn/LICENSE (on Debian also /usr/share/common-licenses/GPL-3).
EOF
  /usr/sbin/visudo -cf "$R/etc/sudoers.d/gp-vpn" >/dev/null
}

size_kb() { du -sk --exclude=DEBIAN "$1" | cut -f1; }

build_deb() {
  local R=$B/deb
  stage "$R"
  mkdir -p "$R/DEBIAN"
  install -m 755 packaging/deb/postinst packaging/deb/prerm packaging/deb/postrm "$R/DEBIAN/"
  install -m 644 packaging/deb/conffiles "$R/DEBIAN/"
  cat > "$R/DEBIAN/control" <<EOF
Package: gp-vpn
Version: $VERSION
Architecture: all
Maintainer: $MAINTAINER
Section: net
Priority: optional
Installed-Size: $(size_kb "$R")
Depends: globalprotect, python3, python3-gi, python3-gi-cairo, gir1.2-gtk-3.0, gir1.2-notify-0.7, sudo, systemd, passwd, procps, util-linux, dconf-cli
Recommends: gnome-shell-extension-appindicator
Conflicts: globalprotect-openconnect
Homepage: $URL
Description: $DESC
 Tray icon and Windows-like panel for the official Palo Alto Networks
 GlobalProtect client (CLI version): status, connect/disconnect, OTP and
 other client prompts, gateway switching on the fly. A GNOME Shell
 extension adds a VPN toggle to the login and lock screens. The agent runs
 under the gpvpn service account, so the VPN works before login and
 survives logins and logouts.
EOF
  dpkg-deb --root-owner-group -Zxz --build "$R" "dist/gp-vpn_${VERSION}_all.deb" >/dev/null
}

build_rpm() {
  command -v rpmbuild >/dev/null || { echo "rpm: нет rpmbuild (sudo apt install rpm) — пропускаю"; return 0; }
  local R=$B/rpm
  stage "$R"
  (cd "$R" && find . ! -type d | sed 's|^\.||' | sort) | awk '
    $0 == "/etc/sudoers.d/gp-vpn"  { print "%attr(0440,root,root) %config(noreplace) " $0; next }
    /^\/etc\//                     { print "%config(noreplace) " $0; next }
    /^\/usr\/share\/doc\/gp-vpn\// { next }
                                   { print }
    END { print "%dir /usr/libexec/gp-vpn"; print "%dir /usr/lib/gp-vpn"; print "%dir /etc/systemd/user/gpa.service.d"
          print "%dir /usr/share/gnome-shell/extensions/gp-vpn@dimakes.github.io"; print "%doc /usr/share/doc/gp-vpn" }' > "$B/files"
  python3 - "$B/gp-vpn.spec" "$R" "$B/files" "$VERSION" "$URL" <<'EOF'
import sys
out, root, files, version, url = sys.argv[1:]
s = open("packaging/rpm/gp-vpn.spec.in").read()
for k, v in {"@VERSION@": version, "@URL@": url, "@ROOT@": root, "@FILES@": open(files).read()}.items():
    s = s.replace(k, v)
open(out, "w").write(s)
EOF
  rpmbuild -bb --quiet --define "_topdir $B/rpmbuild" --define "_rpmdir $PWD/dist" \
    --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$B/gp-vpn.spec" 2>&1 | grep -v -E 'Packages|/var/lib/rpm' || true
}

build_tar() {
  local N=gp-vpn-$VERSION
  local D=$B/tar/$N
  stage "$D/root"
  install -m 755 packaging/tar/install.sh packaging/tar/uninstall.sh "$D/"
  (cd "$D/root" && find . ! -type d | sed 's|^\./||' | sort) > "$D/MANIFEST"
  tar -C "$B/tar" --owner=0 --group=0 -czf "dist/$N.tar.gz" "$N"
}

for fmt in $FORMATS; do
  case $fmt in
    deb) rm -f dist/gp-vpn_*.deb;    build_deb ;;
    rpm) rm -f dist/gp-vpn-*.rpm;    build_rpm ;;
    tar) rm -f dist/gp-vpn-*.tar.gz; build_tar ;;
    *) echo "Неизвестный формат: $fmt (deb, rpm, tar)"; exit 2 ;;
  esac
done
(cd dist && rm -f SHA256SUMS && sha256sum -- * > SHA256SUMS)
ls -l dist
