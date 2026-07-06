# modules/features.ps1
# Configures Windows Optional Features and Services

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptPath "utils.ps1")

function Configure-WindowsFeatures {
    param (
        [array]$EnableList,
        [array]$DisableList
    )

    Write-Log "===== Configuring Windows Optional Features ====="
    $rebootNeeded = $false

    # 1. Enable Features
    foreach ($feature in $EnableList) {
        Write-Log "Checking optional feature: $feature ..."
        try {
            $status = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
            if ($null -eq $status) {
                Write-WarningLog "Feature '$feature' is not recognized on this version of Windows."
                continue
            }

            if ($status.State -ne "Enabled" -and $status.State -ne "EnabledPending") {
                Write-Log "Enabling feature: $feature ..."
                # -All enables parent features if required
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
                Write-Success "Feature '$feature' enabled."
                if ($result.RestartNeeded) {
                    $rebootNeeded = $true
                }
            } else {
                Write-Log "Feature '$feature' is already enabled."
            }
        } catch {
            Write-ErrorLog "Failed to enable feature '$feature'. Error: $_"
        }
    }

    # 2. Disable Features
    foreach ($feature in $DisableList) {
        Write-Log "Checking optional feature to disable: $feature ..."
        try {
            $status = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
            if ($null -eq $status) {
                Write-WarningLog "Feature '$feature' is not recognized on this version of Windows."
                continue
            }

            if ($status.State -eq "Enabled" -or $status.State -eq "EnabledPending") {
                Write-Log "Disabling feature: $feature ..."
                $result = Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop
                Write-Success "Feature '$feature' disabled."
                if ($result.RestartNeeded) {
                    $rebootNeeded = $true
                }
            } else {
                Write-Log "Feature '$feature' is already disabled."
            }
        } catch {
            Write-ErrorLog "Failed to disable feature '$feature'. Error: $_"
        }
    }

    return $rebootNeeded
}

function Configure-WindowsServices {
    param (
        [array]$ServiceConfigList
    )

    if ($ServiceConfigList.Count -eq 0) {
        return
    }

    Write-Log "===== Configuring Windows Services ====="

    foreach ($svc in $ServiceConfigList) {
        $name = $svc.Name
        $startupType = $svc.StartupType # Automatic, Manual, Disabled
        $state = $svc.State # Running, Stopped

        Write-Log "Configuring service: $name (Startup: $startupType, Target State: $state) ..."
        
        $serviceObj = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $serviceObj) {
            Write-WarningLog "Service '$name' was not found on this system."
            continue
        }

        try {
            # Set Startup Type
            if (-not [string]::IsNullOrEmpty($startupType)) {
                # Map standard names if required
                Set-Service -Name $name -StartupType $startupType -ErrorAction Stop
                Write-Log "Set startup type of '$name' to $startupType."
            }

            # Set Service State
            if (-not [string]::IsNullOrEmpty($state)) {
                if ($state -eq "Running" -and $serviceObj.Status -ne "Running") {
                    Start-Service -Name $name -ErrorAction Stop
                    Write-Success "Service '$name' started."
                } elseif ($state -eq "Stopped" -and $serviceObj.Status -ne "Stopped") {
                    Stop-Service -Name $name -Force -ErrorAction Stop
                    Write-Success "Service '$name' stopped."
                }
            }
        } catch {
            Write-ErrorLog "Failed to configure service '$name'. Error: $_"
        }
    }
}
