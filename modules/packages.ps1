# modules/packages.ps1
# Handles Winget packages installation and custom installers

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptPath "utils.ps1")

function Install-WingetPackages {
    param (
        [Parameter(Mandatory=$true)]
        [array]$PackageList
    )

    Write-Log "===== Installing Packages via Winget ====="
    
    # Verify winget is available
    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
        Write-ErrorLog "Winget is not available on this system. Cannot install packages."
        return $false
    }

    $failedPackages = @()

    foreach ($pkg in $PackageList) {
        Write-Log "Installing package: $pkg ..."
        try {
            # Run winget installation with silent arguments
            # --accept-source-agreements and --accept-package-agreements are essential for unattended install
            $process = Start-Process -FilePath "winget.exe" -ArgumentList "install --id `"$pkg`" --silent --accept-source-agreements --accept-package-agreements" -Wait -NoNewWindow -PassThru -ErrorAction Stop
            
            # Winget return codes: 
            # 0 = Success
            # 0x8a15001f / 0x8a15002b = Already installed or no update available (often treated as success)
            # 0x8a15003f = No packages found
            $exitCode = $process.ExitCode
            
            if ($exitCode -eq 0 -or $exitCode -eq 0x8a15001f -or $exitCode -eq 0x8a15002b) {
                Write-Success "Package '$pkg' is installed (Exit Code: $exitCode)."
            } else {
                Write-WarningLog "Winget install returned non-standard exit code ($exitCode) for '$pkg'."
                $failedPackages += $pkg
            }
        } catch {
            Write-ErrorLog "Failed to execute winget for '$pkg'. Error: $_"
            $failedPackages += $pkg
        }
    }

    if ($failedPackages.Count -gt 0) {
        Write-WarningLog "The following packages failed to install: $($failedPackages -join ', ')"
        return $false
    }

    Write-Success "All winget packages installed successfully."
    return $true
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
    $tempPath = Join-Path $scriptPath "..\temp"
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
