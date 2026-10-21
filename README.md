# AV Network Toolbag

Windows Network Tools for the AV Pro, the IoT Technician, and the home-lab.

- No more digging deep into layers of windows to find or change adapter settings
- No more wondering "what IP did that device get?"
- Configure devices on isolated networks without an external DHCP server
- Hassle-free configuration of devices that come out of the box with a self-assigned IP

![main screen](/assets/main_screen.png)
![dhcp server](/assets/dhcp_server.png)
![subnet scan](/assets/subnet_scan.png)
![mDNS listener](/assets/mdns_listner.png)

## Features

- Quickly change multiple network interfaces between **DHCP, Link-Local, and Static IP** assignments
- Save and recall **custom presets** for IPv4 addresses
- Host a temporary **local DHCP server** on networks where none are present
- **Scan subnets** to find and report device IP's, hostnames, and MAC addresses
- **Listen to multicast mDNS** traffic on an interface to find information of devices not on your current subnet
- **Overview of network services** per interface, including internet connectivity, DNS status, and DHCP server information
- Hyper-V **vEthernet aware** so you can set the proper interfaces
- Modern Flutter + Dart app for accessibility, responsiveness, and a compiled .exe
- In-app updating

## Quickstart

Download the installer .exe from the [latest release](https://github.com/mefranklin6/AV-Network-Toolbag/releases/latest).

Windows SmartScreen may warn on first launch because the executable is unsigned. (You can build this project from source if you want to avoid Windows Smart Screen.)

The app requires elevation to administrator in order to change network settings, which is default Windows behavior.

## Acknowledgements

This project was inspired by [netChanger](https://github.com/alecdvor/netChanger/)

## Privacy and Security

The app itself does not include any telemetry, tracking, or features that reduce the users privacy. It only uses the internet to check for the latest version.

The app is only intended for authorized users of a network, and is similar to using tools like Wireshark or a Nmap ping scan.

Windows is likely to flag the installer and program as potentially dangerous: Code signing and trust is in-process so this shouldn't happen in the future.

## AI Disclosure

The foundation of this tool came from my PowerShell tool [NIC_Changer](https://github.com/mefranklin6/NIC_Changer), and AI did most of the translation of the PowerShell backend to Dart and Flutter. NIC_Changer had a human review every line of code, and this project builds on top of that, but is not so strictly reviewed.

## Changelog

### v1.2.1

21 October 2026

- Fixed bug causing DHCP server to serve on a wrong address range if IP of adapter was changed before enabling DHCP server.
- Fixed bug where some computers could not serve DHCP

### v1.2.0

19 October 2026

- Add save and recall IPv4 preset feature. Thanks for the suggestion Isaac!

### v1.1.0

 13 October 2026

- Add raw mDNS listener export feature
- Add mDNS message column to the mDNS listener
- Check for app update on launch

### v1.0.0

8 October 2026

- First release
