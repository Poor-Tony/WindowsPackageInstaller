# Windows Setup Utility & Bootstrapper (Chocolatey Version)

A modular, robust, and interactive Windows setup utility designed for **Windows 11 IoT Enterprise LTSC**, **Windows 10 IoT Enterprise LTSC 2021**, and **Windows 11 Pro**. 

The tool specializes in bootstrapping **Chocolatey** as the primary package manager, alongside **Windows Terminal** and **PowerShell 7**, followed by automated software provisioning.

---

## Features

- **Offline-capable Bootstrapping**:
  - **Chocolatey**: Downloads and installs the Chocolatey Package Manager silently.
  - **Windows Terminal**: Installs the MSIX package.
  - **PowerShell 7**: Installs the MSI package silently.
- **Package Provisioning**: Runs Chocolatey commands in an unattended sequence to install custom developer tools/utilities.

---

## Directory Structure

```
WindowsPackageInstaller/
│   Setup.ps1                 # Main entrypoint script (Elevates admin, handles CLI/GUI/Unattended)
│   config.json               # Configuration template for apps and settings
│   README.md                 # This documentation file
│
└───modules/
        bootstrap.ps1         # Bootstrapping logic for Chocolatey, Terminal, and PS7
        packages.ps1          # Package installations via Chocolatey and custom URLs
        utils.ps1             # Logging, OS checks, and STA thread relaunchers
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
- `Bootstrap`: Toggle the installations of Chocolatey, Windows Terminal, and PowerShell 7.
- `Packages`: Define Chocolatey package IDs to download (e.g. `git`, `7zip`) and custom installer configurations.
