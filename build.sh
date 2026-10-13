#!/bin/bash
# Сборка пакетов gp-vpn: панель в трее, служба gp-vpn и gpclient/gpauth из globalprotect-openconnect
# (без платного GUI «GP Connect»). Запуск от обычного пользователя на Debian/Ubuntu:
#
#   ./build.sh                все форматы: deb, rpm, arch, tar — для x86_64 и aarch64
#   ./build.sh deb            только нужные форматы
#
# upstream/  — релизы globalprotect-openconnect: недостающие скачиваются с GitHub и сверяются по sha256
# dist/      — готовые пакеты и SHA256SUMS
# Для rpm нужен rpmbuild (apt install rpm), для arch — zstd.
set -eo pipefail
umask 022
cd "$(dirname "$(readlink -f "$0")")"

VERSION=2.0
GPCLIENT=2.6.5
URL=https://github.com/DiMAKES/GlobalProtect-GUI-Debian
UPSTREAM=https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v$GPCLIENT
MAINTAINER=${MAINTAINER:-"$(git config user.name 2>/dev/null || echo gp-vpn) <$(git config user.email 2>/dev/null || echo root@localhost)>"}
FORMATS=${*:-deb rpm arch tar}
declare -A SHA=(  # sha256 файлов релиза v2.6.5, как их публикует GitHub
  [globalprotect-openconnect_2.6.5-1_amd64.deb]=17b86bffd68611883fbb28ce03c9baddf5e7d2fe7905e22c3ae77ce2531e573b
  [globalprotect-openconnect_2.6.5-1_arm64.deb]=85884818e42b54417926bea2013724f3506ec0f49f4881d3da2213357b901017
  [globalprotect-openconnect_2.6.5_x86_64.bin.tar.xz]=8e01d90b4d2afb61a73b5f3f68f18e3430b3d827a217f7b50ee71e7d269cbf6c
  [globalprotect-openconnect_2.6.5_aarch64.bin.tar.xz]=1430993746e62962a33e217dc2445aa8c52ed0f7d25470d4bde25516db36e6a8
)
DESC="GlobalProtect VPN client with a Windows-like tray panel"

B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
mkdir -p upstream dist

fetch() {  # $1 — файл релиза upstream
  if [ ! -f "upstream/$1" ]; then
    curl -fL -o "upstream/$1.part" "$UPSTREAM/$1"
    mv "upstream/$1.part" "upstream/$1"
  fi
  echo "${SHA[$1]}  upstream/$1" | sha256sum -c --quiet
}

unpack_generic() {  # $1 — x86_64|aarch64, $2 — куда (получится $2/usr/...)
  [ -d "$2" ] && return
  local f=globalprotect-openconnect_${GPCLIENT}_$1.bin.tar.xz
  fetch "$f"
  mkdir -p "$2"
  tar -xJf "upstream/$f" -C "$2" --strip-components=2 "globalprotect-openconnect_$GPCLIENT/artifacts"
}

stage() {  # $1 — дерево пакета, $2 — распакованный upstream
  local R=$1 U=$2
  install -D -m 755 "$U/usr/bin/gpclient"                  "$R/usr/bin/gpclient"
  install -D -m 755 "$U/usr/bin/gpauth"                    "$R/usr/bin/gpauth"
  install -D -m 755 "$U/usr/libexec/gpclient/vpnc-script"  "$R/usr/libexec/gpclient/vpnc-script"
  install -D -m 755 "$U/usr/libexec/gpclient/hipreport.sh" "$R/usr/libexec/gpclient/hipreport.sh"
  install -D -m 755 src/gp-vpn       "$R/usr/sbin/gp-vpn"
  install -D -m 755 src/gp-vpn-run   "$R/usr/libexec/gp-vpn/run"
  install -D -m 755 src/gp-vpn-tray  "$R/usr/bin/gp-vpn-tray"
  install -D -m 440 src/gp-vpn.sudoers "$R/etc/sudoers.d/gp-vpn"
  install -D -m 644 src/gp-vpn.desktop "$R/usr/share/applications/gp-vpn.desktop"
  install -D -m 644 src/gp-vpn-greeter.desktop "$R/usr/share/gdm/greeter/autostart/gp-vpn.desktop"  # экран входа
  install -D -m 644 src/gp-vpn-tray.desktop "$R/etc/xdg/autostart/gp-vpn-tray.desktop"            # сеанс
  install -D -m 644 LICENSE   "$R/usr/share/doc/gp-vpn/LICENSE"
  install -D -m 644 README.md "$R/usr/share/doc/gp-vpn/README.md"
  cat > "$R/usr/share/doc/gp-vpn/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: GlobalProtect-GUI-Debian
Source: $URL

Files: *
Copyright: $(date +%Y) $MAINTAINER
License: GPL-3.0+

Files: usr/bin/gpclient usr/bin/gpauth usr/libexec/gpclient/*
Copyright: Kevin Yue and contributors
Source: https://github.com/yuezk/GlobalProtect-openconnect (v$GPCLIENT)
License: GPL-3.0

License: GPL-3.0+
 Full text: /usr/share/doc/gp-vpn/LICENSE (on Debian also /usr/share/common-licenses/GPL-3).
EOF
  /usr/sbin/visudo -cf "$R/etc/sudoers.d/gp-vpn" >/dev/null
}

size_kb() { du -sk --exclude=DEBIAN --exclude='.*' "$1" | cut -f1; }

DEBDEPS=
build_deb() {  # $1 — amd64|arm64
  local A=$1 U=$B/up-deb-$1 R=$B/deb-$1 f=globalprotect-openconnect_${GPCLIENT}-1_$1.deb
  fetch "$f"
  dpkg-deb -x "upstream/$f" "$U"
  stage "$R" "$U"
  if [ -z "$DEBDEPS" ]; then  # библиотеки gpclient/gpauth -> пакеты Debian (по amd64; у arm64 те же имена)
    local amd=$B/up-deb-amd64
    [ -d "$amd" ] || { fetch "globalprotect-openconnect_${GPCLIENT}-1_amd64.deb"; dpkg-deb -x "upstream/globalprotect-openconnect_${GPCLIENT}-1_amd64.deb" "$amd"; }
    mkdir -p "$B/shlibs/debian"
    printf 'Source: gp-vpn\n\nPackage: gp-vpn\nArchitecture: any\n' > "$B/shlibs/debian/control"
    DEBDEPS=$(cd "$B/shlibs" && dpkg-shlibdeps -O -e"$amd/usr/bin/gpclient" -e"$amd/usr/bin/gpauth" 2>/dev/null | sed 's/^shlibs:Depends=//')
  fi
  mkdir -p "$R/DEBIAN"
  install -m 755 packaging/deb/prerm packaging/deb/postrm "$R/DEBIAN/"
  install -m 644 packaging/deb/conffiles "$R/DEBIAN/"
  cat > "$R/DEBIAN/control" <<EOF
Package: gp-vpn
Version: $VERSION+gp$GPCLIENT-1
Architecture: $A
Maintainer: $MAINTAINER
Section: net
Priority: optional
Installed-Size: $(size_kb "$R")
Depends: $DEBDEPS, python3, python3-gi, python3-gi-cairo, gir1.2-gtk-3.0, gir1.2-notify-0.7, sudo, systemd, iproute2, openssl, ca-certificates
Recommends: gnome-shell-extension-appindicator
Conflicts: globalprotect-openconnect
Replaces: globalprotect-openconnect
Homepage: $URL
Description: $DESC
 Tray icon and panel for GlobalProtect VPN: status, connect/disconnect,
 gateway switching on the fly, SSO/SAML, password and client certificate
 login, connecting from the login screen. Includes the gp-vpn service with
 HIP report and gpclient/gpauth $GPCLIENT from globalprotect-openconnect
 (without the paid GUI).
EOF
  dpkg-deb --root-owner-group -Zxz --build "$R" "dist/gp-vpn_${VERSION}+gp${GPCLIENT}-1_$A.deb" >/dev/null
}

build_rpm() {  # $1 — x86_64|aarch64
  command -v rpmbuild >/dev/null || { echo "rpm: нет rpmbuild (sudo apt install rpm) — пропускаю"; return 0; }
  local A=$1 U=$B/up-bin-$1 R=$B/rpm-$1
  unpack_generic "$A" "$U"
  stage "$R" "$U"
  (cd "$R" && find . ! -type d | sed 's|^\.||' | sort) | awk '
    $0 == "/etc/sudoers.d/gp-vpn" { print "%attr(0440,root,root) %config(noreplace) " $0; next }
    /^\/etc\//                    { print "%config(noreplace) " $0; next }
    /^\/usr\/share\/doc\/gp-vpn\// { next }
                                  { print }
    END { print "%dir /usr/libexec/gp-vpn"; print "%dir /usr/libexec/gpclient"; print "%doc /usr/share/doc/gp-vpn" }' > "$B/files-$A"
  python3 - "$B/gp-vpn-$A.spec" "$R" "$B/files-$A" "$VERSION" "$URL" "$GPCLIENT" <<'EOF'
import sys
out, root, files, version, url, gp = sys.argv[1:]
s = open("packaging/rpm/gp-vpn.spec.in").read()
for k, v in {"@VERSION@": version, "@URL@": url, "@GPCLIENT@": gp, "@ROOT@": root, "@FILES@": open(files).read()}.items():
    s = s.replace(k, v)
open(out, "w").write(s)
EOF
  rpmbuild -bb --quiet --target "$A" --define "_topdir $B/rpmbuild" --define "_rpmdir $PWD/dist" \
    --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$B/gp-vpn-$A.spec"
}

build_arch() {  # $1 — x86_64|aarch64
  local A=$1 U=$B/up-bin-$1 R=$B/arch-$1
  unpack_generic "$A" "$U"
  stage "$R" "$U"
  mv "$R/usr/sbin/gp-vpn" "$R/usr/bin/gp-vpn" && rmdir "$R/usr/sbin"  # в Arch /usr/sbin — ссылка на /usr/bin
  install -m 644 packaging/arch/gp-vpn.install "$R/.INSTALL"
  {
    echo "pkgname = gp-vpn"
    echo "pkgbase = gp-vpn"
    echo "pkgver = $VERSION-1"
    echo "pkgdesc = $DESC"
    echo "url = $URL"
    echo "builddate = $(date +%s)"
    echo "packager = $MAINTAINER"
    echo "size = $(( $(size_kb "$R") * 1024 ))"
    echo "arch = $A"
    echo "license = GPL-3.0-or-later"
    echo "conflict = globalprotect-openconnect"
    echo "backup = etc/sudoers.d/gp-vpn"
    echo "backup = etc/xdg/autostart/gp-vpn-tray.desktop"
    for d in glibc gcc-libs zlib lz4 zstd xxhash gnutls p11-kit nettle gmp libidn2 libunistring libtasn1 libffi openssl \
             webkit2gtk-4.1 libsoup3 gtk3 libnotify python python-gobject python-cairo sudo systemd iproute2; do
      echo "depend = $d"
    done
    echo "optdepend = gnome-shell-extension-appindicator: tray icon on GNOME"
  } > "$R/.PKGINFO"
  python3 packaging/arch/mkpkg.py "$R" "dist/gp-vpn-$VERSION-1-$A.pkg.tar.zst"
}

build_tar() {  # $1 — x86_64|aarch64
  local A=$1 U=$B/up-bin-$1 N=gp-vpn-$VERSION-$1
  local D=$B/tar/$N
  unpack_generic "$A" "$U"
  stage "$D/root" "$U"
  install -m 755 packaging/tar/install.sh packaging/tar/uninstall.sh "$D/"
  (cd "$D/root" && find . ! -type d | sed 's|^\./||' | sort) > "$D/MANIFEST"
  tar -C "$B/tar" --owner=0 --group=0 -czf "dist/$N.tar.gz" "$N"
}

for fmt in $FORMATS; do
  case $fmt in
    deb)  rm -f dist/gp-vpn_*.deb;         build_deb amd64;    build_deb arm64 ;;
    rpm)  rm -f dist/gp-vpn-*.rpm;         build_rpm x86_64;   build_rpm aarch64 ;;
    arch) rm -f dist/gp-vpn-*.pkg.tar.zst; build_arch x86_64;  build_arch aarch64 ;;
    tar)  rm -f dist/gp-vpn-*.tar.gz;      build_tar x86_64;   build_tar aarch64 ;;
    *) echo "Неизвестный формат: $fmt (deb, rpm, arch, tar)"; exit 2 ;;
  esac
done
(cd dist && rm -f SHA256SUMS && sha256sum -- * > SHA256SUMS)
ls -l dist
