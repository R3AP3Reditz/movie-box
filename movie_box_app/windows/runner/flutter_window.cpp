#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Desktop-only channel shared with the Linux runner. Dart only calls
  // setFullscreen on desktop platforms; every other method is rejected.
  media_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "dev.r3ap3r.movie_box_app/media",
          &flutter::StandardMethodCodec::GetInstance());
  media_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const auto* requested = std::get_if<bool>(call.arguments());
          if (requested == nullptr) {
            result->Error("invalid_arguments", "setFullscreen expects a bool");
            return;
          }
          SetFullscreen(*requested);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  media_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetFullscreen(bool fullscreen) {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  if (fullscreen) {
    if (!fullscreen_) {
      saved_style_ = GetWindowLongPtr(handle, GWL_STYLE);
      saved_placement_.length = sizeof(saved_placement_);
      GetWindowPlacement(handle, &saved_placement_);
    }
    MONITORINFO monitor_info = {};
    monitor_info.cbSize = sizeof(monitor_info);
    if (!GetMonitorInfo(MonitorFromWindow(handle, MONITOR_DEFAULTTOPRIMARY),
                        &monitor_info)) {
      return;
    }
    // Drop the frame so the client area covers the whole screen.
    SetWindowLongPtr(handle, GWL_STYLE,
                     saved_style_ & ~(WS_CAPTION | WS_THICKFRAME));
    SetWindowPos(handle, HWND_TOP, monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.top,
                 monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    fullscreen_ = true;
    return;
  }
  if (fullscreen_) {
    SetWindowLongPtr(handle, GWL_STYLE, saved_style_);
    SetWindowPlacement(handle, &saved_placement_);
    SetWindowPos(handle, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED | SWP_NOACTIVATE);
  }
  fullscreen_ = false;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_GETMINMAXINFO:
      // Keep the desktop layout usable; below this the shell would switch to
      // the phone bottom-bar layout.
      if (HWND handle = GetHandle()) {
        UINT dpi = GetDpiForWindow(handle);
        if (dpi == 0) {
          dpi = 96;
        }
        const double scale = static_cast<double>(dpi) / 96.0;
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize.x = static_cast<LONG>(900 * scale);
        info->ptMinTrackSize.y = static_cast<LONG>(620 * scale);
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}