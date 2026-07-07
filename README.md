# Windows Setup Utility & Bootstrapper

A modular, robust, and interactive Windows setup utility designed for **Windows 11 IoT Enterprise LTSC**, **Windows 10 IoT Enterprise LTSC 2021**, and **Windows 11 Pro**. 

The tool specializes in bootstrapping essential modern components (**WinGet**, **Windows Terminal**, and **PowerShell 7**) on LTSC systems where the Microsoft Store is unavailable, falling back to **Chocolatey** if WinGet installation is not successful, and installing a preset list of applications.

---

## Features

- **Offline-capable Bootstrapping**:
  - **WinGet**: Downloads and registers the Windows Package Manager along with essential VCLibs and UI Xaml dependencies without needing the Microsoft Store.
  - **Chocolatey (Fallback)**: If WinGet bootstrapping fails, the tool automatically installs Chocolatey as a backup package manager.
  - **Windows Terminal**: Installs the MSIX package.
  - **PowerShell 7**: Installs the MSI package silently.
- **Package Provisioning**: Runs installation commands in an unattended sequence to install custom developer tools/utilities. Supports WinGet natively and falls back to Chocolatey package mapping automatically.

---

## Directory Structure

```
WindowsPackageInstaller/
│   Setup.ps1                 # Main entrypoint script (Elevates admin, handles CLI/GUI/Unattended)
│   config.json               # Configuration template for apps and settings
│   README.md                 # This documentation file
│
└───modules/
        bootstrap.ps1         # Bootstrapping logic for WinGet, Terminal, PS7, and Chocolatey fallback
        packages.ps1          # Package installations via Winget/Chocolatey and custom URLs
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

The setup is fully configurable via [config.json](file:///home/andreas/Code/WindowsPackageInstaller/config.json). 

Key sections include:
- `Bootstrap`: Toggle the installations of Winget, Windows Terminal, and PowerShell 7.
- `Packages`: Define package IDs to download (e.g. `Git.Git`, `7zip.7zip`) and custom installer configurations.
