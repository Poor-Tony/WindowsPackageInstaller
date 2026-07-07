# modules/security.ps1
# Configures Security parameters (Windows Defender & User Account Control UAC)

. (Join-Path $PSScriptRoot "utils.ps1")

function Configure-UAC {
    param (
        [int]$ConsentPromptBehaviorAdmin,
        [int]$EnableLUA
    )

    Write-Log "===== Configuring User Account Control (UAC) ====="
    
    $uacRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

    try {
        if ($null -ne $ConsentPromptBehaviorAdmin) {
            Write-Log "Setting UAC ConsentPromptBehaviorAdmin to $ConsentPromptBehaviorAdmin ..."
            Set-ItemProperty -Path $uacRegistryPath -Name "ConsentPromptBehaviorAdmin" -Value $ConsentPromptBehaviorAdmin -Type DWord -Force -ErrorAction Stop
        }

        if ($null -ne $EnableLUA) {
            Write-Log "Setting UAC EnableLUA (Enable UAC) to $EnableLUA ..."
            Set-ItemProperty -Path $uacRegistryPath -Name "EnableLUA" -Value $EnableLUA -Type DWord -Force -ErrorAction Stop
            Write-WarningLog "Changing EnableLUA requires a reboot to take effect."
        }

        Write-Success "UAC configured successfully."
    } catch {
        Write-ErrorLog "Failed to configure UAC registry keys. Error: $_"
    }
}

function Configure-WindowsDefender {
    param (
        [bool]$RealTimeProtection,
        [array]$Exclusions
    )

    Write-Log "===== Configuring Windows Defender ====="

    # Check if Windows Defender module is available
    $defenderModule = Get-Command "Set-MpPreference" -ErrorAction SilentlyContinue
    if (-not $defenderModule) {
        Write-WarningLog "Windows Defender management cmdlets are not available on this system. Skipping."
        return
    }

    try {
        # Configure Real-Time Protection
        # Set-MpPreference: -DisableRealtimeMonitoring takes $true to DISABLE and $false to ENABLE
        $disableRealtime = $null
        if ($RealTimeProtection) {
            $disableRealtime = $false
            Write-Log "Enabling Windows Defender Real-Time Protection..."
        } else {
            $disableRealtime = $true
            Write-WarningLog "DISABLING Windows Defender Real-Time Protection!"
        }

        if ($null -ne $disableRealtime) {
            Set-MpPreference -DisableRealtimeMonitoring $disableRealtime -ErrorAction Stop
            Write-Success "Windows Defender Real-Time Protection set to $RealTimeProtection."
        }

        # Configure Exclusions
        if ($Exclusions.Count -gt 0) {
            Write-Log "Configuring Windows Defender Exclusions..."
            foreach ($path in $Exclusions) {
                # Verify paths if they exist, or add anyway if they are system environment paths
                Write-Log "Adding Defender exclusion path: $path ..."
                Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
            }
            Write-Success "Defender exclusion paths updated."
        }
    } catch {
        Write-ErrorLog "Failed to configure Windows Defender. Error: $_"
    }
}
