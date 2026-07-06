# Windows Setup Utility & Bootstrapper

A modular, robust, and interactive Windows setup utility designed for **Windows 11 IoT Enterprise LTSC**, **Windows 10 IoT Enterprise LTSC 2021**, and **Windows 11 Pro**. 

The tool specializes in bootstrapping essential modern components (**WinGet**, **Windows Terminal**, and **PowerShell 7**) on LTSC systems where the Microsoft Store is unavailable, followed by automated software provisioning and system customization.

---

## Features

- **Offline-capable Bootstrapping**:
  - **WinGet**: Downloads and registers the Windows Package Manager along with essential VCLibs and UI Xaml dependencies without needing the Microsoft Store.
  - **Windows Terminal**: Installs the MSIX package.
  - **PowerShell 7**: Installs the MSI package silently.
- **Package Provisioning**: Runs Winget commands in an unattended sequence to install custom developer tools/utilities. Supports custom installers (MSI/EXE) with command-line arguments.
- **Windows Optional Features & Services**: Enables optional features (e.g. WSL, containers) and sets startup states of core services.
- **IoT-Specific Settings**: 
  - **Unified Write Filter (UWF)** overlay size, overlay type (RAM/DISK), and directory/file exclusions.
  - **Auto-Logon**: Configures registry parameters for administrative or operator accounts.
  - **Custom Shell / Shell Launcher**: Replaces `explorer.exe` with a custom shell path or reverts back.
  - **Lock Screen Tweak**: Disables lock screen and keyboard shortcuts (CTRL+ALT+DEL prompts).
- **Security Control**: Configures User Account Control (UAC) prompts and sets Windows Defender real-time protection and path exclusion policies.

---

## Directory Structure

```
D:\Projekte\Code\WindowsPackageInstaller\
│   Setup.ps1                 # Main entrypoint script (Elevates admin, handles CLI/GUI/Unattended)
│   config.json               # Configuration template for apps, features, and settings
│   README.md                 # This documentation file
│
└───modules/
        bootstrap.ps1         # Offline bootstrapping logic for WinGet, Terminal, and PS7
        packages.ps1          # Package installations via Winget and custom URLs
        features.ps1          # Manages Windows Optional Features and Services
        iot.ps1               # Configures custom shell, auto-logon, UWF, and lock screen settings
        security.ps1          # Configures Windows Defender exclusions and UAC prompt level
        utils.ps1             # Logging, OS checks, NuGet extractors, and STA thread relaunchers
```

---

## Requirements

- **Operating System**: Windows 10 IoT LTSC 2021, Windows 11 IoT LTSC, or Windows 10/11 Pro/Enterprise.
- **PowerShell Version**: PowerShell 5.1 (standard built-in) or PowerShell 7 Core.
- **Privileges**: Administrator privileges (the script will automatically trigger a UAC prompt to elevate if required).
- **Network Access**: Internet connection for the bootstrap download stage (if installing packages online), or you can pre-stage files in a local directory using the `CustomInstallers` config block.

---

## How to Run

1. Open PowerShell as **Administrator**.
2. Set the execution policy to allow script execution if not already enabled:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
   ```
3. Run the entrypoint script:
   - **Interactive WPF GUI (Default)**:
     ```powershell
     .\Setup.ps1 -Mode GUI
     ```
   - **Interactive CLI Menu**:
     ```powershell
     .\Setup.ps1 -Mode CLI
     ```
   - **Unattended Mode (for deployments)**:
     ```powershell
     .\Setup.ps1 -Mode Unattended
     ```

---

## Configuration (`config.json`)

The setup is fully configurable via [config.json](file:///D:/Projekte/Code/WindowsPackageInstaller/config.json). 

Key sections include:
- `Bootstrap`: Toggle the installations of Winget, Windows Terminal, and PowerShell 7.
- `Packages`: Define winget package IDs to download (e.g. `Git.Git`, `7zip.7zip`) and custom installer configurations.
- `IoT`: Configure write filters, custom operator shell paths, automatic logons, and lock screen restrictions.
- `Features`: Enable or disable optional packages (e.g., `Microsoft-Windows-Subsystem-Linux`).
- `Security`: Set Windows Defender settings, exclusion folders, and UAC prompt behaviors.
