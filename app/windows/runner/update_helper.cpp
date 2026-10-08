#include <windows.h>
#include <shellapi.h>

#include <filesystem>
#include <cstdlib>
#include <string>

namespace fs = std::filesystem;

namespace {

bool CopyTree(const fs::path& source, const fs::path& destination,
              std::wstring* error_message) {
  std::error_code error;
  fs::create_directories(destination, error);
  if (error) {
    *error_message = L"Could not create the destination directory: " +
                     destination.wstring();
    return false;
  }

  fs::recursive_directory_iterator iterator(
      source, fs::directory_options::skip_permission_denied, error);
  const fs::recursive_directory_iterator end;
  while (!error && iterator != end) {
    const fs::path relative = fs::relative(iterator->path(), source, error);
    if (error) {
      break;
    }
    const fs::path target = destination / relative;
    if (iterator->is_directory(error)) {
      fs::create_directories(target, error);
    } else if (iterator->is_regular_file(error)) {
      fs::create_directories(target.parent_path(), error);
      if (!error) {
        fs::copy_file(iterator->path(), target,
                      fs::copy_options::overwrite_existing, error);
      }
    }
    if (!error) {
      iterator.increment(error);
    }
  }
  if (error) {
    const std::string detail = error.message();
    *error_message = L"Could not copy an update file: " +
                     std::wstring(detail.begin(), detail.end());
    return false;
  }
  return true;
}

void ShowFailure(const std::wstring& message) {
  ::MessageBoxW(nullptr, message.c_str(), L"AV Network Toolbag Update",
                MB_OK | MB_ICONERROR | MB_SYSTEMMODAL);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE, _In_opt_ HINSTANCE,
                      _In_ wchar_t*, _In_ int) {
  int argument_count = 0;
  LPWSTR* arguments = ::CommandLineToArgvW(::GetCommandLineW(), &argument_count);
  if (arguments == nullptr || argument_count != 6) {
    ShowFailure(L"The updater was started with invalid arguments.");
    if (arguments != nullptr) {
      ::LocalFree(arguments);
    }
    return EXIT_FAILURE;
  }

  const DWORD parent_process_id = wcstoul(arguments[1], nullptr, 10);
  const fs::path payload_directory(arguments[2]);
  const fs::path staging_directory(arguments[3]);
  const fs::path install_directory(arguments[4]);
  const std::wstring executable_name(arguments[5]);
  const fs::path helper_path(arguments[0]);
  ::LocalFree(arguments);

  HANDLE parent_process =
      ::OpenProcess(SYNCHRONIZE, FALSE, parent_process_id);
  if (parent_process != nullptr) {
    ::WaitForSingleObject(parent_process, 30000);
    ::CloseHandle(parent_process);
  }
  ::Sleep(300);

  const fs::path backup_directory = staging_directory / L"backup";
  std::error_code cleanup_error;
  fs::remove_all(backup_directory, cleanup_error);

  std::wstring error_message;
  if (!CopyTree(install_directory, backup_directory, &error_message)) {
    ShowFailure(L"The installed application could not be backed up.\n\n" +
                error_message);
    return EXIT_FAILURE;
  }

  if (!CopyTree(payload_directory, install_directory, &error_message)) {
    std::wstring rollback_error;
    CopyTree(backup_directory, install_directory, &rollback_error);
    ShowFailure(L"The update could not be installed. The previous version was "
                L"restored.\n\n" + error_message);
    return EXIT_FAILURE;
  }

  const fs::path executable_path = install_directory / executable_name;
  const HINSTANCE launch_result = ::ShellExecuteW(
      nullptr, L"open", executable_path.c_str(), nullptr,
      install_directory.c_str(), SW_SHOWNORMAL);
  if (reinterpret_cast<INT_PTR>(launch_result) <= 32) {
    ShowFailure(L"The update was installed, but the application could not be "
                L"restarted. Start it manually from:\n\n" +
                executable_path.wstring());
    return EXIT_FAILURE;
  }

  fs::remove_all(staging_directory, cleanup_error);
  ::MoveFileExW(helper_path.c_str(), nullptr, MOVEFILE_DELAY_UNTIL_REBOOT);
  return EXIT_SUCCESS;
}

