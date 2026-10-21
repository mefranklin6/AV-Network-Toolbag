#include "flutter_window.h"

#include <optional>
#include <netfw.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <regex>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Convert adapter friendly names without losing non-ASCII characters.
BSTR FirewallString(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.c_str(), -1, nullptr, 0);
  if (length == 0) return nullptr;
  BSTR value = SysAllocStringLen(nullptr, static_cast<UINT>(length - 1));
  if (value && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.c_str(), -1, value, length)) {
    SysFreeString(value);
    return nullptr;
  }
  return value;
}

HRESULT AddDhcpRule(INetFwRules* rules, const std::string& name,
                    const std::string& interface_alias) {
  Microsoft::WRL::ComPtr<INetFwRule> rule;
  HRESULT status = CoCreateInstance(__uuidof(NetFwRule), nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&rule));
  if (FAILED(status)) return status;

  BSTR rule_name = FirewallString(name);
  BSTR ports = SysAllocString(L"67");
  VARIANT adapter;
  VariantInit(&adapter);
  adapter.vt = VT_BSTR;
  adapter.bstrVal = FirewallString(interface_alias);
  VARIANT interfaces;
  VariantInit(&interfaces);
  interfaces.vt = VT_ARRAY | VT_VARIANT;
  interfaces.parray = SafeArrayCreateVector(VT_VARIANT, 0, 1);
  if (!rule_name || !ports || !adapter.bstrVal || !interfaces.parray) {
    status = E_OUTOFMEMORY;
  } else {
    LONG index = 0;
    status = SafeArrayPutElement(interfaces.parray, &index, &adapter);
    if (SUCCEEDED(status)) status = rule->put_Name(rule_name);
    if (SUCCEEDED(status)) status = rule->put_Direction(NET_FW_RULE_DIR_IN);
    if (SUCCEEDED(status)) status = rule->put_Protocol(NET_FW_IP_PROTOCOL_UDP);
    if (SUCCEEDED(status)) status = rule->put_LocalPorts(ports);
    if (SUCCEEDED(status)) status = rule->put_Profiles(NET_FW_PROFILE2_ALL);
    if (SUCCEEDED(status)) status = rule->put_Interfaces(interfaces);
    if (SUCCEEDED(status)) status = rule->put_Action(NET_FW_ACTION_ALLOW);
    if (SUCCEEDED(status)) status = rule->put_Enabled(VARIANT_TRUE);
    // Publish only after all properties, including interface scope, succeed.
    if (SUCCEEDED(status)) status = rules->Add(rule.Get());
  }
  SysFreeString(rule_name);
  SysFreeString(ports);
  VariantClear(&adapter);
  VariantClear(&interfaces);
  return status;
}

}  // namespace

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
        const bool adding = call.method_name() == "addDhcpRule";
        if (!adding && call.method_name() != "removeRule") {
          result->NotImplemented();
          return;
        }
        const std::string* name = nullptr;
        const std::string* interface_alias = nullptr;
        if (adding) {
          const auto* arguments = call.arguments()
              ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
          if (arguments) {
            const auto name_it = arguments->find(flutter::EncodableValue("name"));
            const auto alias_it = arguments->find(
                flutter::EncodableValue("interfaceAlias"));
            if (name_it != arguments->end()) {
              name = std::get_if<std::string>(&name_it->second);
            }
            if (alias_it != arguments->end()) {
              interface_alias = std::get_if<std::string>(&alias_it->second);
            }
          }
          if (!interface_alias || interface_alias->empty()) {
            result->Error("invalid_interface", "A DHCP adapter name is required.");
            return;
          }
        } else {
          name = call.arguments()
              ? std::get_if<std::string>(call.arguments()) : nullptr;
        }
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
        if (SUCCEEDED(status) && adding) {
          status = AddDhcpRule(rules.Get(), *name, *interface_alias);
        } else if (SUCCEEDED(status)) {
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
          result->Error(adding ? "firewall_create" : "firewall_cleanup",
              std::string("Windows could not ") + (adding ? "create" : "remove") +
              " the temporary DHCP firewall rule (HRESULT " +
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
