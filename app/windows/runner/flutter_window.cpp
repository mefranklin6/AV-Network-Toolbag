#include "flutter_window.h"

#include <optional>
#include <netfw.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <regex>

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
  firewall_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "av_network_toolbag/firewall",
          &flutter::StandardMethodCodec::GetInstance());
  firewall_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "removeRule") {
          result->NotImplemented();
          return;
        }
        const auto* name = call.arguments()
            ? std::get_if<std::string>(call.arguments()) : nullptr;
        if (!name || !std::regex_match(*name,
                std::regex("AVNetworkToolbag-Dart-[0-9]+-[0-9]+"))) {
          result->Error("invalid_rule", "Invalid temporary firewall rule name.");
          return;
        }
        Microsoft::WRL::ComPtr<INetFwPolicy2> policy;
        Microsoft::WRL::ComPtr<INetFwRules> rules;
        HRESULT status = CoCreateInstance(__uuidof(NetFwPolicy2), nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&policy));
        if (SUCCEEDED(status)) status = policy->get_Rules(&rules);
        if (SUCCEEDED(status)) {
          const std::wstring wide_name(name->begin(), name->end());
          BSTR rule_name = SysAllocString(wide_name.c_str());
          if (!rule_name) {
            status = E_OUTOFMEMORY;
          } else {
            status = rules->Remove(rule_name);
            SysFreeString(rule_name);
          }
        }
        if (FAILED(status)) {
          result->Error("firewall_cleanup", "Windows could not remove the temporary firewall rule (HRESULT " +
              std::to_string(status) + ").");
          return;
        }
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  firewall_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
