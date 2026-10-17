#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) printf 'Unsupported Linux architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

cd "$root/movie_box_app"
flutter build linux --release
bundle="$PWD/build/linux/$arch/release/bundle"
install_dir="$HOME/.local/opt/movie-box"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"

install -d "$install_dir" "$HOME/.local/bin" "$data_dir/applications" \
  "$data_dir/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$install_dir/"
install -m 644 logo.png "$data_dir/icons/hicolor/256x256/apps/dev.r3ap3r.movie_box_app.png"
ln -sfn "$install_dir/movie_box_app" "$HOME/.local/bin/movie-box"

python3 - "$install_dir/movie_box_app" "$data_dir/applications/dev.r3ap3r.movie_box_app.desktop" <<'PY'
import pathlib
import sys

executable = sys.argv[1]
for character in ('\\', '"', '`', '$'):
    executable = executable.replace(character, '\\' + character)
executable = executable.replace('%', '%%').replace('\\', '\\\\')
pathlib.Path(sys.argv[2]).write_text(
    '[Desktop Entry]\n'
    'Type=Application\n'
    'Name=Movie Box\n'
    'Comment=Browse, watch, and download with your Movie Box server\n'
    f'Exec="{executable}"\n'
    'Icon=dev.r3ap3r.movie_box_app\n'
    'Terminal=false\n'
    'Categories=AudioVideo;Video;Player;\n'
    'StartupWMClass=dev.r3ap3r.movie_box_app\n'
)
PY

if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$data_dir/applications"
fi
printf 'Installed Movie Box to %s\nLaunch it from your application menu or %s\n' \
  "$install_dir" "$HOME/.local/bin/movie-box"
