# Linux desktop

Movie Box supports native Linux desktop builds alongside Android. Linux uses the existing Flutter screens and API, with `video_player_media_kit` for streaming and offline playback. Android retains its existing video backend.

## Requirements

- Flutter with Dart compatible with `^3.13.1`, Linux desktop enabled.
- Clang, CMake, Ninja, pkg-config, GTK 3 development files, and libstdc++ development files.
- libmpv and its development package for the Linux video renderer.
- Python 3 for the per-user installation script.

For Ubuntu/Debian:

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev libmpv-dev python3
```

For Fedora (libmpv may require your configured multimedia repository):

```sh
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel libstdc++-devel mpv-libs-devel python3
```

Use `flutter doctor -v` to check your build environment. Runtime systems need GTK 3, libmpv, and their dependencies. The build is native to the architecture and Linux distribution used to compile it; this is not a universal AppImage or a statically linked bundle.

## Run, build, and install

From the repository root:

```sh
cd movie_box_app
flutter pub get
flutter run -d linux
flutter build linux --release
```

To build and install for the current user, run from the repository root:

```sh
bash scripts/install_linux.sh
```

The installer needs no root privileges. It copies the **entire** Flutter bundle to `~/.local/opt/movie-box`, installs a `~/.local/bin/movie-box` command, and registers **Movie Box** in the application menu with its icon. Re-running updates the installed program without deleting preferences or downloads. Close the app before updating it.

The launcher and icon use `${XDG_DATA_HOME:-~/.local/share}`. Preferences, task records, and Linux offline files live in the application-support directory resolved by `path_provider`, normally beneath `$XDG_DATA_HOME/dev.r3ap3r.movie_box_app` (default `~/.local/share/dev.r3ap3r.movie_box_app`).

## Behavior

- Set your API address and optional token in Settings. A local scraper uses `http://127.0.0.1:8000`; the Android emulator's `10.0.2.2` address is not needed on Linux.
- Use the fullscreen button or **F** to enter native window fullscreen; **Escape** exits. Space toggles playback and Left/Right seek when the video has keyboard focus.
- Linux navigation renders live frames instead of taking route snapshots, which are incompatible with the native video texture.
- Downloads continue while the app is running, including while minimized. **Closing the app stops transfers.** Reopen it to recover interrupted transfers. Pause/resume depends on server range support, valid links, and the availability of temporary files.
- Linux does not use Android notification permission or promise desktop download notifications.
- Download thumbnails fall back to cached artwork or the placeholder icon. Android's native video-frame extraction is not used on Linux.

## Verification

```sh
cd movie_box_app
flutter analyze
flutter test
flutter build linux --release
```

The Linux integration test uses a generated local MP4 and a local HTTP fixture server, not third-party media or the public API. It exercises navigation, empty search, streaming with request headers, bookmarks, watch history, fullscreen, real downloads with subtitles, and offline playback.

Generate a test clip with FFmpeg, then run the test in a desktop session (or under `xvfb-run`):

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=24 -t 30 \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart /tmp/moviebox-test.mp4
cd movie_box_app
XDG_DATA_HOME="$(mktemp -d)" flutter test integration_test/linux_app_test.dart \
  -d linux --dart-define=MOVIEBOX_TEST_VIDEO=/tmp/moviebox-test.mp4
```

The test mocks the app's preference store and uses temporary download storage. A separate `XDG_DATA_HOME` isolates the downloader plugin's own database from your installed app.
