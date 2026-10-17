# Windows desktop

Movie Box supports native Windows desktop builds alongside Android and Linux. Windows uses the existing Flutter screens and the same API, with `video_player_media_kit` and `media_kit_libs_windows_video` for streaming and offline playback. Unlike Linux, Windows does not need a separately installed libmpv: the media-kit package ships the native libraries with the build output.

## Requirements

- Flutter with Dart compatible with `^3.13.1`, Windows desktop enabled (`flutter config --enable-windows-desktop`).
- 64-bit Windows 10 or 11.
- Visual Studio 2022 with the **Desktop development with C++** workload, including the MSVC toolchain and the Windows 10/11 SDK. Flutter's Windows build uses MSBuild, so the command-line build tools alone are not sufficient.

Use `flutter doctor -v` to confirm the Windows toolchain group, then `flutter devices` to confirm a `windows` device is listed.

## Run, build, and install

From the repository root:

```sh
cd movie_box_app
flutter pub get
flutter run -d windows
flutter build windows --release
```

A release build writes `build/windows/x64/runner/Release/`. That folder contains `movie_box_app.exe`, the required DLLs, and a `data/` directory. Copy the **whole folder**; the executable does not run on its own.

To install for the current user, copy the Release folder to a location such as `%LOCALAPPDATA%\Programs\MovieBox` and create a Start Menu shortcut to `movie_box_app.exe` under `%APPDATA%\Microsoft\Windows\Start Menu\Programs`. An installer script is not provided, so no unattended installation is claimed here.

Preferences, the downloader database, and offline files live in the application-support directory that `path_provider` resolves for this app (`dev.r3ap3r.movie_box_app`), beneath `%APPDATA%`. Replacing the program folder keeps them.

## Behavior

- Set your API address and optional token in Settings. A local scraper uses `http://127.0.0.1:8000`; the Android emulator's `10.0.2.2` address is not needed on Windows.
- The window opens at 1360x860 and declares a minimum of 900x620. Windows enforces that minimum through `WM_GETMINMAXINFO`; narrower desktop windows would fall back to the phone bottom-tab shell, so the minimum keeps the desktop rail layout.
- Use the fullscreen button or **F** to enter native window fullscreen; **Escape** exits. Fullscreen is handled by the Windows runner: it removes the window frame and covers the monitor, then restores the previous style and placement on exit. It is reached through the `dev.r3ap3r.movie_box_app/media` method channel (`setFullscreen`), the same channel the Linux runner implements.
- Ctrl+1 to 5 select the five tabs and Ctrl+F opens Search while the main shell has focus.
- Downloads run in-process and continue while the app is running, including while minimized. **Closing the app stops transfers.** Reopen it to recover interrupted transfers. Pause/resume depends on server range support, valid links, and the availability of temporary files.
- Windows does not use Android notification permission, and desktop download notifications are not promised.
- Download thumbnails fall back to cached artwork or the placeholder icon; Android's native video-frame extraction is not used on Windows.

## Verification status

The Windows platform code in this repository was written on Linux and **has not been compiled or run**. There is no Windows build in this project's checks. The checks that were run cover the shared Dart code, not the Windows runner:

- `flutter analyze` and `flutter test` (all 187 widget and regression tests) pass, and the same Dart sources build and run on Linux.
- `flutter build linux --release` succeeds with the Windows media-kit dependency present, which confirms the package resolves but says nothing about the Windows binaries.
- The Windows C++ changes in `windows/runner/` (the fullscreen method channel, the minimum window size, the window title and icon) and the `flutter build windows` output are unverified until someone builds them on Windows.

Before distributing, build on Windows and check playback, fullscreen entry and exit, the 900x620 minimum size, offline downloads, and offline playback:

```sh
cd movie_box_app
flutter analyze
flutter test
flutter build windows --release
```