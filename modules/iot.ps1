# modules/iot.ps1
# Configures Windows IoT specific features (UWF, Shell Launcher, Auto-Logon, Lock Screen)

. (Join-Path $PSScriptRoot "utils.ps1")

function Configure-ShellLauncher {
    param (
        [bool]$Enable,
        [string]$ShellPath
    )

    Write-Log "===== Configuring Custom Shell / Shell Launcher ====="

    $winlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    if ($Enable) {
        if ([string]::IsNullOrEmpty($ShellPath) -or -not (Test-Path -Path $ShellPath -ErrorAction SilentlyContinue)) {
            Write-WarningLog "Shell path '$ShellPath' is empty or not found. Cannot enable custom shell."
            return
        }

        Write-Log "Setting custom shell to: $ShellPath ..."
        try {
            # Standard custom shell override via Winlogon registry (highly compatible across Pro and IoT)
            Set-ItemProperty -Path $winlogonKey -Name "Shell" -Value $ShellPath -Force -ErrorAction Stop
            Write-Success "Custom shell registry path configured."
        } catch {
            Write-ErrorLog "Failed to configure custom shell in registry. Error: $_"
        }
    } else {
        Write-Log "Restoring default Windows Explorer shell..."
        try {
            Set-ItemProperty -Path $winlogonKey -Name "Shell" -Value "explorer.exe" -Force -ErrorAction Stop
            Write-Success "Explorer shell restored."
        } catch {
            Write-ErrorLog "Failed to restore default shell. Error: $_"
        }
    }
}

function Configure-UnifiedWriteFilter {
    param (
        [bool]$Configure,
        [string]$OverlayType, # RAM or DISK
        [int]$OverlaySizeMB,
        [array]$Exclusions
    )

    Write-Log "===== Configuring Unified Write Filter (UWF) ====="

    # Check if uwfmgr utility exists
    $uwfPath = "$env:SystemRoot\System32\uwfmgr.exe"
    if (-not (Test-Path -Path $uwfPath)) {
        Write-WarningLog "Unified Write Filter utility (uwfmgr.exe) was not found. Skipping UWF configuration. (Only available on Windows IoT/Enterprise)."
        return
    }

    if (-not $Configure) {
        Write-Log "UWF configuration is disabled in config.json. Ensuring filter is disabled..."
        try {
            # Disable filter
            & uwfmgr.exe filter disable | Out-Null
            Write-Log "UWF filter set to disable on next reboot."
        } catch {
            Write-ErrorLog "Failed to disable UWF. Error: $_"
        }
        return
    }

    try {
        Write-Log "Configuring UWF overlay parameters..."
        
        # Set overlay type
        if ($OverlayType -eq "RAM" -or $OverlayType -eq "DISK") {
            & uwfmgr.exe overlay set-type $OverlayType | Out-Null
            Write-Log "UWF overlay type set to $OverlayType."
        }

        # Set overlay size
        if ($OverlaySizeMB -gt 256) {
            & uwfmgr.exe overlay set-size $OverlaySizeMB | Out-Null
            Write-Log "UWF overlay size set to $OverlaySizeMB MB."
        }

        # Configure exclusions
        foreach ($excl in $Exclusions) {
            Write-Log "Adding UWF exclusion: $excl ..."
            if (Test-Path -Path $excl) {
                # Check if it's a file or directory to call the appropriate uwfmgr parameter
                $isDir = (Get-Item -Path $excl).PSIsContainer
                if ($isDir) {
                    & uwfmgr.exe file add-exclusion $excl | Out-Null
                } else {
                    & uwfmgr.exe file add-exclusion $excl | Out-Null
                }
                Write-Log "Exclusion '$excl' added."
            } else {
                # Add it anyway as exclusions can be wildcarded or pre-created paths
                & uwfmgr.exe file add-exclusion $excl | Out-Null
                Write-Log "Exclusion '$excl' added (Path did not exist at runtime)."
            }
        }

        # Enable UWF filter
        & uwfmgr.exe filter enable | Out-Null
        Write-Success "UWF configured and scheduled to enable on next reboot."
    } catch {
        Write-ErrorLog "Failed to configure UWF. Error: $_"
    }
}

function Configure-AutoLogon {
    param (
        [bool]$Enable,
        [string]$Username,
        [string]$Password,
        [string]$Domain
    )

    Write-Log "===== Configuring Windows Auto-Logon ====="
    
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    if ($Enable) {
        if ([string]::IsNullOrEmpty($Username)) {
            Write-WarningLog "Username is required to enable Auto-Logon. Skipping."
            return
        }

        Write-Log "Enabling Auto-Logon for user: $Username ..."
        try {
            Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "1" -Force -ErrorAction Stop
            Set-ItemProperty -Path $winlogonPath -Name "DefaultUserName" -Value $Username -Force -ErrorAction Stop
            Set-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -Value $Password -Force -ErrorAction Stop
            
            if (-not [string]::IsNullOrEmpty($Domain)) {
                Set-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -Value $Domain -Force -ErrorAction Stop
            } else {
                # Fall back to local computer name as domain
                $computerName = $env:COMPUTERNAME
                Set-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -Value $computerName -Force -ErrorAction Stop
            }

            # Optional: Disable the shift override key if you want to force auto-logon without escape option
            # Set-ItemProperty -Path $winlogonPath -Name "ForceAutoLogon" -Value "1" -Force -ErrorAction Stop

            Write-Success "Auto-Logon configured successfully."
        } catch {
            Write-ErrorLog "Failed to configure Auto-Logon registry keys. Error: $_"
        }
    } else {
        Write-Log "Disabling Windows Auto-Logon..."
        try {
            Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "0" -Force -ErrorAction Stop
            # Clear stored password
            Remove-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
            Write-Success "Auto-Logon disabled."
        } catch {
            Write-ErrorLog "Failed to disable Auto-Logon. Error: $_"
        }
    }
}

function Configure-LockScreenSettings {
    param (
        [bool]$DisableLockScreen,
        [bool]$DisableKeyCombinations
    )

    Write-Log "===== Configuring Lock Screen Settings ====="

    # 1. Disable Lock Screen
    if ($DisableLockScreen) {
        Write-Log "Disabling Windows Lock Screen..."
        $personalizationPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
        try {
            if (-not (Test-Path -Path $personalizationPath)) {
                New-Item -Path $personalizationPath -Force | Out-Null
            }
            Set-ItemProperty -Path $personalizationPath -Name "NoLockScreen" -Value 1 -Type DWord -Force -ErrorAction Stop
            
            # Disable Ctrl+Alt+Del prompt for Logon
            $systemPoliciesPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            Set-ItemProperty -Path $systemPoliciesPath -Name "DisableCAD" -Value 1 -Type DWord -Force -ErrorAction Stop
            
            $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
            Set-ItemProperty -Path $winlogonPath -Name "DisableCAD" -Value 1 -Type DWord -Force -ErrorAction Stop

            Write-Success "Lock Screen and Ctrl+Alt+Del requirement disabled."
        } catch {
            Write-ErrorLog "Failed to disable Lock Screen. Error: $_"
        }
    } else {
        # Restore defaults
        $personalizationPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
        try {
            if (Test-Path -Path $personalizationPath) {
                Remove-ItemProperty -Path $personalizationPath -Name "NoLockScreen" -ErrorAction SilentlyContinue
            }
            Write-Log "Lock Screen setting restored to default."
        } catch {
            Write-ErrorLog "Failed to restore Lock Screen setting. Error: $_"
        }
    }

    # 2. Keyboard Filter for Key Combinations (Win key, Ctrl+Alt+Del bypass, etc.)
    # Keyboard Filter is configured under HKLM:\SOFTWARE\Microsoft\Windows Embedded\KeyboardFilter
    if ($DisableKeyCombinations) {
        Write-Log "Configuring Keyboard Filter registry tweaks (disabling common hotkeys)..."
        $kbFilterPath = "HKLM:\SOFTWARE\Microsoft\Windows Embedded\KeyboardFilter"
        try {
            if (-not (Test-Path -Path $kbFilterPath)) {
                New-Item -Path $kbFilterPath -Force | Out-Null
            }
            # Enable Keyboard Filter driver in registry if feature is installed
            Set-ItemProperty -Path $kbFilterPath -Name "Enabled" -Value 1 -Type DWord -Force -ErrorAction Stop
            Write-Success "Keyboard Filter enabled in registry."
        } catch {
            Write-WarningLog "Failed to configure Keyboard Filter. Verify if Keyboard Filter optional feature is enabled."
        }
    }
}
