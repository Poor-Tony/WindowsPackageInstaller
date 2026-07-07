# modules/packages.ps1
# Handles Chocolatey packages installation and custom installers

. (Join-Path $PSScriptRoot "utils.ps1")

function Install-SystemPackages {
    param (
        [Parameter(Mandatory=$true)]
        [array]$PackageList
    )

    # Verify Chocolatey is available
    $chocoFunctional = $false
    if (Get-Command "choco" -ErrorAction SilentlyContinue) {
        $chocoFunctional = $true
    }

    if ($chocoFunctional) {
        Write-Log "===== Installing Packages via Chocolatey ====="
        $failedPackages = @()

        foreach ($pkg in $PackageList) {
            Write-Log "Installing package via Chocolatey: $pkg ..."
            try {
                # Choco install with automatic confirmation (-y) and no progress bar for cleaner logs
                $process = Start-Process -FilePath "choco.exe" -ArgumentList "install `"$pkg`" -y --no-progress" -Wait -NoNewWindow -PassThru -ErrorAction Stop
                
                # Choco exit codes: 0 = success, 3010 = reboot required
                if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                    Write-Success "Package '$pkg' installed successfully via Chocolatey."
                } else {
                    Write-ErrorLog "Chocolatey failed to install '$pkg' (Exit Code: $($process.ExitCode))."
                    $failedPackages += $pkg
                }
            } catch {
                Write-ErrorLog "Failed to run Chocolatey installer for '$pkg'. Error: $_"
                $failedPackages += $pkg
            }
        }

        if ($failedPackages.Count -gt 0) {
            Write-WarningLog "The following packages failed to install: $($failedPackages -join ', ')"
            return $false
        }

        Write-Success "All packages installed successfully via Chocolatey."
        return $true
    }

    Write-ErrorLog "Chocolatey is not functional on this system. Package installation aborted."
    return $false
}

function Install-CustomInstallers {
    param (
        [Parameter(Mandatory=$true)]
        [array]$CustomInstallersList
    )

    if ($CustomInstallersList.Count -eq 0) {
        return $true
    }

    Write-Log "===== Installing Custom Packages ====="
    $tempPath = Join-Path $PSScriptRoot "..\temp"
    if (-not (Test-Path -Path $tempPath)) {
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    }

    $allSuccess = $true

    foreach ($installer in $CustomInstallersList) {
        $name = $installer.Name
        $url = $installer.Url
        $args = $installer.Arguments
        $localPath = $installer.LocalPath

        Write-Log "Processing custom installer: $name ..."

        $installFile = $null

        if (-not [string]::IsNullOrEmpty($localPath) -and (Test-Path -Path $localPath)) {
            Write-Log "Using local installer file: $localPath"
            $installFile = $localPath
        } elseif (-not [string]::IsNullOrEmpty($url)) {
            $fileName = [System.IO.Path]::GetFileName([System.Uri]$url.AbsolutePath)
            if ([string]::IsNullOrEmpty($fileName)) {
                $fileName = "custom_installer.exe"
            }
            $destFile = Join-Path $tempPath $fileName
            if (Download-File -Url $url -OutPath $destFile) {
                $installFile = $destFile
            }
        }

        if ($installFile -and (Test-Path -Path $installFile)) {
            try {
                Write-Log "Executing installer: $installFile with arguments: $args ..."
                $process = Start-Process -FilePath $installFile -ArgumentList $args -Wait -NoNewWindow -PassThru -ErrorAction Stop
                
                if ($process.ExitCode -eq 0) {
                    Write-Success "Custom installer '$name' executed successfully."
                } else {
                    Write-ErrorLog "Custom installer '$name' failed with exit code: $($process.ExitCode)"
                    $allSuccess = $false
                }
            } catch {
                Write-ErrorLog "Failed to run custom installer '$name'. Error: $_"
                $allSuccess = $false
            }
        } else {
            Write-ErrorLog "No valid local file or download URL available for custom installer '$name'."
            $allSuccess = $false
        }
    }

    # Clean temp folder
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }

    return $allSuccess
}
