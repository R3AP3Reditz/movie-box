#!/bin/sh
# Package a Flutter Linux release bundle as deb, rpm, and AppImage.
set -eu
version="${1:?version}"
bundle="${2:?bundle directory}"
out="${3:?output directory}"
icon="${4:?png icon}"
name=moviebox
mkdir -p "$out"

stage=$(mktemp -d)
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

# Shared install tree used by deb and rpm.
root="$stage/root"
mkdir -p "$root/opt/moviebox" "$root/usr/bin" "$root/usr/share/applications" "$root/usr/share/icons/hicolor/128x128/apps"
cp -a "$bundle"/. "$root/opt/moviebox/"
cp "$icon" "$root/usr/share/icons/hicolor/128x128/apps/moviebox.png"
chmod 755 "$root/opt/moviebox/movie_box_app"
cat > "$root/usr/bin/moviebox" << 'EOF'
#!/bin/sh
exec /opt/moviebox/movie_box_app "$@"
EOF
chmod 755 "$root/usr/bin/moviebox"
cat > "$root/usr/share/applications/moviebox.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Movie Box
Exec=moviebox
Icon=moviebox
Categories=AudioVideo;
EOF

# deb
deb="$stage/deb"
mkdir -p "$deb/DEBIAN"
cp -a "$root"/. "$deb/"
cat > "$deb/DEBIAN/control" << EOF
Package: moviebox
Version: $version
Section: video
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 | libgtk-3-0t64, libblkid1, liblzma5
Maintainer: R3AP3R Editz <r3ap3reditz@users.noreply.github.com>
Description: Movie Box desktop client
 Self-hosted Movie Box for Linux.
EOF
dpkg-deb --root-owner-group --build "$deb" "$out/MovieBox-$version-linux-x64.deb"

# rpm
spec="$stage/moviebox.spec"
cat > "$spec" << EOF
Name: moviebox
Version: $version
Release: 1
Summary: Movie Box desktop client
License: SEE LICENSE
BuildArch: x86_64
AutoReqProv: no
Requires: gtk3, libblkid, xz-libs
%define __os_install_post %{nil}
%define _build_id_links none

%description
Self-hosted Movie Box for Linux.

%install
mkdir -p %{buildroot}
cp -a $root/. %{buildroot}/

%files
/opt/moviebox
/usr/bin/moviebox
/usr/share/applications/moviebox.desktop
/usr/share/icons/hicolor/128x128/apps/moviebox.png
EOF
QA_RPATHS=$((0x0002)) rpmbuild --define "_topdir $stage/rpm" --define "_rpmdir $out" -bb "$spec"
mv "$out/x86_64/moviebox-$version-1.x86_64.rpm" "$out/MovieBox-$version-linux-x64.rpm"
rmdir "$out/x86_64"

# AppImage
appdir="$stage/MovieBox.AppDir"
mkdir -p "$appdir"
cp -a "$bundle"/. "$appdir/"
cp "$icon" "$appdir/moviebox.png"
cp "$root/usr/share/applications/moviebox.desktop" "$appdir/moviebox.desktop"
cat > "$appdir/AppRun" << 'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/movie_box_app" "$@"
EOF
chmod 755 "$appdir/AppRun"
tool="$stage/appimagetool"
curl -fsSL -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$tool"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" "$appdir" "$out/MovieBox-$version-linux-x64.AppImage"
