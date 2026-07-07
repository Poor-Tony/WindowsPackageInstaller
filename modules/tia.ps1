# modules/tia.ps1
# Handles automated, reboot-resilient installation of Siemens TIA Portal and its additional packages

. (Join-Path $PSScriptRoot "utils.ps1")

$Global:TiaStatePath = "C:\ProgramData\TiaInstallerState.json"
$Global:TiaLocalScriptDir = "C:\ProgramData\WindowsPackageInstaller"

function Get-TiaPackages {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FolderPath
    )

    if (-not (Test-Path -Path $FolderPath)) {
        Write-ErrorLog "Folder path does not exist: $FolderPath"
        return @()
    }

    # Find all exe and iso files (excluding parts like .001, etc.)
    $files = Get-ChildItem -Path $FolderPath -File | Where-Object { $_.Extension -eq ".exe" -or $_.Extension -eq ".iso" }

    if ($files.Count -eq 0) {
        Write-WarningLog "No .exe or .iso installation packages found in: $FolderPath"
        return @()
    }

    # Create package objects
    $packages = @()
    foreach ($file in $files) {
        $type = $file.Extension.ToUpper().Replace(".", "")
        # Modern TIA Portal main packages combine STEP 7, Safety, and WinCC.
        $isCombined = ($file.Name -match "STEP7|STEP_7|TIA_Portal|TIA-Portal") -and ($file.Name -match "WinCC")
        $packages += [PSCustomObject]@{
            Path = $file.FullName
            Name = $file.Name
            Type = $type
            Size = $file.Length
            IsMain = $false
            IsCombined = $isCombined
            Status = "Pending"
        }
    }

    # Check for incompatible base packages (e.g. WinCC Unified vs WinCC Professional)
    $combinedPackages = $packages | Where-Object { $_.IsCombined }
    if ($combinedPackages.Count -gt 1) {
        $hasUnified = $combinedPackages | Where-Object { $_.Name -match "Unified" }
        $hasProfessional = $combinedPackages | Where-Object { $_.Name -match "WINCC_Prof|WinCC_Prof" -or ($_.Name -match "Prof" -and $_.Name -notmatch "Unified") }
        
        if ($hasUnified -and $hasProfessional) {
            Write-ErrorLog "Incompatible TIA Portal base packages detected in folder: $FolderPath"
            Write-ErrorLog "  - Unified: $($hasUnified.Name)"
            Write-ErrorLog "  - Professional: $($hasProfessional.Name)"
            Write-ErrorLog "WinCC Unified and WinCC Professional are not compatible and cannot be installed side-by-side."
            Write-ErrorLog "Please keep only one of these base installers in the folder and restart the setup."
            return @()
        }
    }

    # Identify main package:
    # Look for STEP7, STEP_7, TIA_Portal, Professional in name.
    # Exclude helper keywords like PLCSIM, Startdrive, Safety unless they are part of a combined package.
    $mainCandidates = $packages | Where-Object { 
        $_.Name -match "STEP7" -or 
        $_.Name -match "STEP_7" -or 
        $_.Name -match "TIA_Portal" -or 
        $_.Name -match "TIA-Portal" -or 
        $_.Name -match "Professional"
    }

    $mainPackage = $null
    if ($mainCandidates.Count -gt 0) {
        # Exclude sub-packages if possible to find the actual main installer.
        # Combined packages should NOT be excluded even if they match "Safety".
        $filteredCandidates = $mainCandidates | Where-Object {
            $_.IsCombined -or (
                $_.Name -notmatch "PLCSIM" -and 
                $_.Name -notmatch "Startdrive" -and 
                $_.Name -notmatch "Safety"
            )
        }
        if ($filteredCandidates.Count -gt 0) {
            # Pick the largest of these
            $mainPackage = $filteredCandidates | Sort-Object Size -Descending | Select-Object -First 1
        } else {
            # Fallback to largest candidate
            $mainPackage = $mainCandidates | Sort-Object Size -Descending | Select-Object -First 1
        }
    }

    # If still no main package identified, select the absolute largest package in the folder
    if ($null -eq $mainPackage) {
        $mainPackage = $packages | Sort-Object Size -Descending | Select-Object -First 1
    }

    if ($null -ne $mainPackage) {
        $mainPackage.IsMain = $true
        Write-Log "Identified main package: $($mainPackage.Name) (Size: $([Math]::Round($mainPackage.Size / 1GB, 2)) GB)"
    }

    # Sort packages: Main package first, then others alphabetically.
    # Exclude other combined/base packages to avoid double installation of incompatible main packages.
    $sortedPackages = @()
    if ($null -ne $mainPackage) {
        $sortedPackages += $mainPackage
    }
    
    $addons = @()
    foreach ($pkg in $packages) {
        if (-not $pkg.IsMain) {
            if ($pkg.IsCombined) {
                Write-WarningLog "Excluding other base/combined package from installation list: $($pkg.Name)"
            } else {
                $addons += $pkg
            }
        }
    }
    
    $sortedPackages += $addons | Sort-Object Name

    return $sortedPackages
}

function Save-TiaState {
    param (
        [Parameter(Mandatory=$true)]
        $State
    )

    try {
        $json = ConvertTo-Json -InputObject $State -Depth 100
        # Ensure parent directory exists
        $parentDir = Split-Path -Path $Global:TiaStatePath -Parent
        if (-not (Test-Path -Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        $json | Out-File -FilePath $Global:TiaStatePath -Force -Encoding UTF8
        Write-Log "Tia Portal installer state saved."
    } catch {
        Write-ErrorLog "Failed to save TIA Portal installation state. Error: $_"
    }
}

function Load-TiaState {
    if (-not (Test-Path -Path $Global:TiaStatePath)) {
        return $null
    }

    try {
        $content = Get-Content -Raw -Path $Global:TiaStatePath -ErrorAction Stop
        $state = ConvertFrom-Json -InputObject $content -ErrorAction Stop
        return $state
    } catch {
        Write-ErrorLog "Failed to load TIA Portal installation state. Error: $_"
        return $null
    }
}

function Register-TiaRunOnce {
    Write-Log "Registering RunOnce key to resume installation after reboot..."
    $runOnceKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $valueName = "TiaPortalInstaller"
    $scriptPath = Join-Path $Global:TiaLocalScriptDir "Setup.ps1"
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Unattended -ResumeTia"

    try {
        Set-ItemProperty -Path $runOnceKey -Name $valueName -Value $command -Force -ErrorAction Stop
        Write-Success "Registered RunOnce command: $command"
    } catch {
        Write-ErrorLog "Failed to write RunOnce registry key. Error: $_"
    }
}

function Remove-TiaRunOnce {
    $runOnceKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $valueName = "TiaPortalInstaller"
    if (Get-ItemProperty -Path $runOnceKey -Name $valueName -ErrorAction SilentlyContinue) {
        try {
            Remove-ItemProperty -Path $runOnceKey -Name $valueName -Force -ErrorAction Stop
            Write-Log "Removed RunOnce registry key."
        } catch {
            Write-WarningLog "Failed to remove RunOnce registry key: $_"
        }
    }
}

function Test-RebootPending {
    $pending = $false
    
    # 1. Component Based Servicing
    if (Get-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -ErrorAction SilentlyContinue) {
        $pending = $true
    }
    
    # 2. Windows Update
    if (Get-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -ErrorAction SilentlyContinue) {
        $pending = $true
    }
    
    # 3. Session Manager (Pending File Rename Operations)
    $pfro = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
    if ($null -ne $pfro -and $pfro.PendingFileRenameOperations.Count -gt 0) {
        $pending = $true
    }
    
    return $pending
}

function Install-TiaPackage {
    param (
        [Parameter(Mandatory=$true)]
        $Package
    )

    Write-Log "===== Installing Package: $($Package.Name) ====="

    $success = $false
    $driveLetter = $null
    $installerPath = $null

    if ($Package.Type -eq "ISO") {
        Write-Log "Mounting ISO: $($Package.Path) ..."
        try {
            $mountResult = Mount-DiskImage -ImagePath $Package.Path -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 3 # Allow Windows to assign drive letter
            
            # Find the drive letter
            $driveLetter = ($mountResult | Get-Volume).DriveLetter
            if (-not $driveLetter) {
                $driveLetter = (Get-DiskImage -ImagePath $Package.Path | Get-Volume).DriveLetter
            }

            if (-not $driveLetter) {
                Write-ErrorLog "Failed to obtain drive letter for mounted ISO."
                return $false
            }

            Write-Log "ISO mounted successfully on drive $($driveLetter):"

            # Locate the installer executable
            $installerPath = Join-Path "${driveLetter}:" "Start.exe"
            if (-not (Test-Path -Path $installerPath)) {
                $installerPath = Join-Path "${driveLetter}:" "Setup.exe"
            }

            if (-not (Test-Path -Path $installerPath)) {
                # Fallback search
                $exeFiles = Get-ChildItem -Path "${driveLetter}:\" -Filter "*.exe" -File
                $matchingExe = $exeFiles | Where-Object { $_.Name -match "Start" -or $_.Name -match "Setup" } | Select-Object -First 1
                if ($matchingExe) {
                    $installerPath = $matchingExe.FullName
                } elseif ($exeFiles.Count -gt 0) {
                    $installerPath = ($exeFiles | Sort-Object Length -Descending | Select-Object -First 1).FullName
                }
            }

            if (-not $installerPath -or -not (Test-Path -Path $installerPath)) {
                Write-ErrorLog "Could not locate installer (Start.exe or Setup.exe) on mounted ISO."
                Dismount-DiskImage -ImagePath $Package.Path | Out-Null
                return $false
            }

        } catch {
            Write-ErrorLog "Failed to mount ISO. Error: $_"
            return $false
        }
    } else {
        # EXE Package
        $installerPath = $Package.Path
    }

    try {
        Write-Log "Starting silent installation from: $installerPath ..."
        
        # We pass standard silent options for Siemens installers
        # /silent is Siemens custom switch; /qn and REBOOT=Suppress are standard MSI options passed down
        # Siemens self-extracting .exe files also accept /silent
        $process = Start-Process -FilePath $installerPath -ArgumentList "/silent", "/norestart", "REBOOT=Suppress" -Wait -NoNewWindow -PassThru -ErrorAction Stop
        
        Write-Log "Installer process finished. Exit Code: $($process.ExitCode)"
        
        # Treat 0 (Success) and 3010 (Reboot Required) as successful installations
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            $success = $true
        } else {
            Write-ErrorLog "Installer returned non-success exit code: $($process.ExitCode)"
            $success = $false
        }
    } catch {
        Write-ErrorLog "Failed to execute installer. Error: $_"
        $success = $false
    } finally {
        if ($Package.Type -eq "ISO" -and $null -ne $driveLetter) {
            Write-Log "Dismounting ISO: $($Package.Path) ..."
            try {
                Dismount-DiskImage -ImagePath $Package.Path -ErrorAction Stop | Out-Null
                Write-Log "ISO dismounted successfully."
            } catch {
                Write-WarningLog "Failed to dismount ISO: $_"
            }
        }
    }

    return $success
}

function Copy-InstallerToLocal {
    $scriptDir = $PSScriptRoot
    # Since modules is inside the project root, parent directory of $PSScriptRoot is the script root
    $projectRoot = Split-Path -Path $scriptDir -Parent
    
    if ($projectRoot -ne $Global:TiaLocalScriptDir) {
        Write-Log "Copying installation script utility to local directory: $Global:TiaLocalScriptDir for reboot resilience..."
        try {
            if (-not (Test-Path -Path $Global:TiaLocalScriptDir)) {
                New-Item -ItemType Directory -Path $Global:TiaLocalScriptDir -Force | Out-Null
            }
            # Copy all files and folders excluding temp and git metadata
            Get-ChildItem -Path $projectRoot | Where-Object { $_.Name -ne "temp" -and $_.Name -ne ".git" } | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $Global:TiaLocalScriptDir -Recurse -Force
            }
            Write-Success "Script files copied successfully."
        } catch {
            Write-ErrorLog "Failed to copy script files to local directory: $_"
        }
    }
}

function Start-TiaInstallation {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FolderPath
    )

    Write-Log "============================================="
    Write-Log "Starting TIA Portal Silent Installation"
    Write-Log "Folder Path: $FolderPath"
    Write-Log "============================================="

    # 1. Copy script files locally so that RunOnce doesn't point to a network/temporary drive
    Copy-InstallerToLocal

    # 2. Get sorted packages
    $packages = Get-TiaPackages -FolderPath $FolderPath
    if ($packages.Count -eq 0) {
        Write-ErrorLog "No packages to install."
        return
    }

    # 3. Create state
    $state = [PSCustomObject]@{
        FolderPath = $FolderPath
        Packages = $packages
    }

    Save-TiaState $state

    # 4. Start loop
    Run-TiaInstallLoop
}

function Resume-TiaInstallation {
    Write-Log "Resuming TIA Portal Silent Installation from state file..."
    
    $state = Load-TiaState
    if ($null -eq $state) {
        Write-ErrorLog "No installation state file found at $Global:TiaStatePath. Cannot resume."
        Remove-TiaRunOnce
        return
    }

    # If we resume, find any packages marked "Installing"
    # This means the installer for this package initiated a reboot mid-installation
    # We mark it as Completed and move forward
    $installingPackages = $state.Packages | Where-Object { $_.Status -eq "Installing" }
    foreach ($pkg in $installingPackages) {
        Write-WarningLog "Package '$($pkg.Name)' was in 'Installing' state when system rebooted. Assuming it completed successfully or triggered the reboot."
        $pkg.Status = "Completed"
    }
    
    if ($installingPackages.Count -gt 0) {
        Save-TiaState $state
    }

    # Continue the installation loop
    Run-TiaInstallLoop
}

function Run-TiaInstallLoop {
    $state = Load-TiaState
    if ($null -eq $state) {
        Write-ErrorLog "Installation state not found in loop."
        Remove-TiaRunOnce
        return
    }

    # Find the next pending package
    $pending = $state.Packages | Where-Object { $_.Status -eq "Pending" }

    if ($pending.Count -eq 0) {
        Write-Success "============================================="
        Write-Success "TIA Portal & Option Packages Installation COMPLETE!"
        Write-Success "============================================="
        
        # Cleanup
        Remove-TiaRunOnce
        if (Test-Path -Path $Global:TiaStatePath) {
            Remove-Item -Path $Global:TiaStatePath -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $package = $pending[0]
    Write-Log "Processing next package: $($package.Name) ($($pending.Count) packages remaining)"

    # Mark as Installing and save state
    $package.Status = "Installing"
    Save-TiaState $state

    # Register RunOnce in case the installer reboots automatically
    Register-TiaRunOnce

    # Install
    $success = Install-TiaPackage -Package $package

    if ($success) {
        Write-Success "Package installation succeeded: $($package.Name)"
        $package.Status = "Completed"
        Save-TiaState $state

        # Check if we should reboot
        $rebootNeeded = $false
        if ($package.IsMain) {
            Write-Log "Main package installed. Reboot is highly recommended."
            $rebootNeeded = $true
        } elseif (Test-RebootPending) {
            Write-Log "A reboot is pending on the system."
            $rebootNeeded = $true
        }

        if ($rebootNeeded) {
            Write-WarningLog "Reboot is required to continue. Rebooting computer in 10 seconds..."
            Start-Sleep -Seconds 10
            Restart-Computer -Force
            return
        } else {
            # Run the next package immediately
            Run-TiaInstallLoop
        }
    } else {
        Write-ErrorLog "Installation failed for package: $($package.Name). Aborting."
        $package.Status = "Failed"
        Save-TiaState $state
        Remove-TiaRunOnce
    }
}
