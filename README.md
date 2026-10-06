# AV Network Toolbag

Windows Network Tools for the AV Technician.

The application lives in `flutter_app/nic_changer`. It uses a responsive,
keyboard-accessible Flutter interface with a native Dart Windows backend. Adapter
information comes directly from the Windows IP Helper API; no PowerShell process
or legacy WinForms interface is included.

## Features

- Quickly set multiple NIC addresses between DHCP, Link-Local, and Static IP assignments
- Quickly change static IP addresses
- Host a temporary local DHCP server on networks where none are present
- Scan networks to find and report devices, host names and MAC addresses
- Overview of network services per NIC, such as internet connectivity and DNS server statuses
- Hyper-V vEthernet awareness: easier to set the correct interface
- Native Windows adapter discovery with bounded, asynchronous operations

![app picture](/assets/app_pic_v2_1_0.png)
![dhcp server](/assets/dhcp_server.png)
![subnet scan](/assets/subnet_scan.png)

## Quickstart

Download the Windows application [from the latest release](https://github.com/mefranklin6/NIC_Changer/releases/latest).

## Flutter development

From `flutter_app/nic_changer`, run:

```powershell
flutter pub get
flutter run -d windows
```

The executable requests administrator privileges because Windows requires
elevation for adapter changes, firewall rules, and the temporary DHCP service.
The backend is implemented in Dart, using Windows FFI for adapter discovery and
short-lived, time-limited Windows utilities for configuration and ICMP checks.

## Acknowledgments

This project builds upon the work of alecdvor. Their repository <https://github.com/alecdvor/netChanger/> provided the foundation for this project.

## Changelog

### v2.1.2

- Fix excessive popups when running the .exe (comment out informational Write-Host lines)

### v2.1.1

- Fix issue where the .exe artifact was not being included in Releases

### v2.1.0

- Added the ability to host a DHCP server on networks where there are none
- Added DHCP server status (external, internal, none)
- Update CI/CD to build a .exe upon release

### v2.0.0

- Complete GUI overhaul, with dark mode option
- Subnet scanning, searching, and reporting to return active IP addresses, host names, and MAC addresses per interface.
- DNS Check
- Async GUI updates and test results
- CIDR Selection for subnet mask
- Static IP collision detection and warning
- Input verification
- Enhanced adapter type checking and filtering, including support for vEthernet and virtual switches found in Hyper-V enabled PC's
- Accessibility improvements

### v1.0.0

- Hide the console window
- Add check for admin rights
- Add 'try to re-launch as admin' method
- Add subnet mask feature and GUI element
- GUI Improvements
(perception of responsiveness, disable buttons when busy)
- Change function name (to clear an unapproved verb warning)
- Add debugging prints.  These print when the console is shown.
- Changed "Force Link Local" to check for address availability first
(slightly more RFC 3927 compliant)
- Removed unused VLAN code and references
- Fixed "Internet Connection" bug where the test was not using the selected adapter
- Remove .exe in favor of running the .ps1 file directly
