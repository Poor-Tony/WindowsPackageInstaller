# modules/bootstrap.ps1
# Bootstrapping module to install Winget, Windows Terminal, and PowerShell 7 on Windows IoT LTSC / Pro

. (Join-Path $PSScriptRoot "utils.ps1")

# Fallback links in case GitHub API is rate-limited or offline
$Global:FallbackWingetBundle = "https://github.com/microsoft/winget-cli/releases/download/v1.8.1911/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
$Global:FallbackWingetLicense = "https://github.com/microsoft/winget-cli/releases/download/v1.8.1911/c8a2b535496440e29b13970b5550a266_License1.xml"
$Global:FallbackTerminalBundle = "https://github.com/microsoft/terminal/releases/download/v1.20.11781.0/Microsoft.WindowsTerminal_1.20.11781.0_8wekyb3d8bbwe.msixbundle"
$Global:FallbackPowerShellMsi = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.3/PowerShell-7.4.3-win-x64.msi"

# Direct Microsoft CDN Link for VC Runtime dependency
$Global:VCLibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
$Global:UiXamlNugetUrl = "https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.7"

function Get-GitHubReleaseAsset {
    param (
        [string]$Repo,
        [string]$Extension,
        [string]$FallbackUrl
    )

    Write-Log "Querying latest release assets for repo '$Repo' (Filter: $Extension) ..."
    try {
        $api = "https://api.github.com/repos/$Repo/releases/latest"
        $response = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.assets) {
            $asset = $response.assets | Where-Object { $_.name -like "*$Extension" } | Select-Object -First 1
            if ($asset -and $asset.browser_download_url) {
                Write-Log "Found latest online release: $($asset.browser_download_url)"
                return $asset.browser_download_url
            }
        }
    } catch {
        Write-WarningLog "Failed to query GitHub API for '$Repo': $_. Using hardcoded fallback URL."
    }
    return $FallbackUrl
}

function Bootstrap-Dependencies {
    param ([string]$TempDir)

    Write-Log "===== Checking and Installing Core Appx Dependencies ====="
    
    # 1. VC++ Runtime (VCLibs)
    $vclibsPackageName = "Microsoft.VCLibs.140.00.UWPDesktop"
    $hasVCLibs = Get-AppxPackage -Name $vclibsPackageName -AllUsers
    
    if (-not $hasVCLibs) {
        Write-Log "VCLibs UWP Desktop Runtime not found. Installing..."
        $destPath = Join-Path $TempDir "Microsoft.VCLibs.x64.14.00.Desktop.appx"
        if (Download-File -Url $Global:VCLibsUrl -OutPath $destPath) {
            try {
                Add-AppxPackage -Path $destPath -ErrorAction Stop
                Write-Success "Successfully installed Microsoft.VCLibs"
            } catch {
                Write-ErrorLog "Failed to install Microsoft.VCLibs appx. Error: $_"
                return $false
            }
        } else {
            return $false
        }
    } else {
        Write-Log "Microsoft.VCLibs is already installed."
    }

    # 2. Microsoft.UI.Xaml (required for modern AppInstaller/Winget UI & Terminal dependencies)
    $uiXamlPackageName = "Microsoft.UI.Xaml.2.8"
    $hasUiXaml = Get-AppxPackage -Name $uiXamlPackageName -AllUsers
    
    if (-not $hasUiXaml) {
        Write-Log "Microsoft.UI.Xaml.2.8 not found. Bootstrapping from NuGet package..."
        $destAppx = Join-Path $TempDir "Microsoft.UI.Xaml.2.8.appx"
        
        # We extract NuGet package and find the x64 APPX file
        $tempExtractDir = Join-Path $TempDir "ui_xaml_extract"
        $tempZip = Join-Path $TempDir "ui_xaml.zip"
        
        if (Download-File -Url $Global:UiXamlNugetUrl -OutPath $tempZip) {
            try {
                Write-Log "Extracting NuGet package to extract appx dependency..."
                Expand-Archive -Path $tempZip -DestinationPath $tempExtractDir -Force
                
                # Search for the x64 appx file dynamically (handles variation in packaging structure)
                $appxFile = Get-ChildItem -Path $tempExtractDir -Filter "*UI.Xaml*.appx" -Recurse | 
                            Where-Object { $_.FullName -match "x64" } | 
                            Select-Object -First 1
                
                if ($appxFile) {
                    Write-Log "Found dependency APPX at: $($appxFile.FullName)"
                    Copy-Item -Path $appxFile.FullName -Destination $destAppx -Force
                    Add-AppxPackage -Path $destAppx -ErrorAction Stop
                    Write-Success "Successfully installed Microsoft.UI.Xaml.2.8"
                } else {
                    Write-ErrorLog "Failed to locate x64 Microsoft.UI.Xaml.appx file within downloaded NuGet package."
                    return $false
                }
            } catch {
                Write-ErrorLog "Failed to extract or install Microsoft.UI.Xaml.2.8. Error: $_"
                return $false
            } finally {
                # Clean temp extraction files
                if (Test-Path -Path $tempZip) { Remove-Item -Path $tempZip -Force }
                if (Test-Path -Path $tempExtractDir) { Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } else {
            return $false
        }
    } else {
        Write-Log "Microsoft.UI.Xaml.2.8 is already installed."
    }

    return $true
}

function Bootstrap-Winget {
    param ([string]$TempDir)

    Write-Log "===== Checking and Bootstrapping Windows Package Manager (Winget) ====="
    
    # Check if winget command is available and functional
    $wingetExists = Get-Command "winget" -ErrorAction SilentlyContinue
    if ($wingetExists) {
        try {
            $version = winget --version
            Write-Log "WinGet is already installed and functional. Version: $version"
            return $true
        } catch {
            Write-WarningLog "WinGet binary is registered but not functional. Attempting re-install/repair..."
        }
    }

    Write-Log "Winget is not installed/functional. Proceeding with installation..."
    
    # Make sure dependencies are met first
    if (-not (Bootstrap-Dependencies -TempDir $TempDir)) {
        Write-ErrorLog "Aborting Winget installation because dependencies failed to install."
        return $false
    }

    # Fetch latest Winget download URLs from GitHub API, or fall back
    $wingetBundleUrl = Get-GitHubReleaseAsset -Repo "microsoft/winget-cli" -Extension "msixbundle" -FallbackUrl $Global:FallbackWingetBundle
    $wingetLicenseUrl = Get-GitHubReleaseAsset -Repo "microsoft/winget-cli" -Extension "xml" -FallbackUrl $Global:FallbackWingetLicense

    $bundlePath = Join-Path $TempDir "Microsoft.DesktopAppInstaller.msixbundle"
    $licensePath = Join-Path $TempDir "Microsoft.DesktopAppInstaller.xml"

    # Download bundle and license
    $d1 = Download-File -Url $wingetBundleUrl -OutPath $bundlePath
    $d2 = Download-File -Url $wingetLicenseUrl -OutPath $licensePath

    if ($d1 -and $d2) {
        try {
            Write-Log "Installing Windows Package Manager (AppInstaller)..."
            # On some IoT LTSC systems, registering via AppxProvisionedPackage is better to support all users
            # Fall back to Add-AppxPackage if provisioned fails or isn't applicable
            try {
                Write-Log "Attempting to register provisioned package for all users..."
                Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -LicensePath $licensePath -ErrorAction Stop | Out-Null
                Write-Success "WinGet provisioned successfully."
            } catch {
                Write-WarningLog "Add-AppxProvisionedPackage failed: $_. Falling back to standard Add-AppxPackage..."
                Add-AppxPackage -Path $bundlePath -ErrorAction Stop
                Write-Success "WinGet installed for the current user."
            }

            # Warm up and register paths
            Write-Log "Registering Winget application package..."
            $winAppPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
            if (-not ($env:PATH -like "*$winAppPath*")) {
                Write-Log "Adding WindowsApps to session PATH environment variables."
                $env:PATH += ";$winAppPath"
            }
            
            # Run test
            Start-Sleep -Seconds 2
            $versionTest = winget --version
            Write-Success "Winget is now functional! Version: $versionTest"
            return $true
        } catch {
            Write-ErrorLog "Failed to register Winget package. Error: $_"
            return $false
        }
    } else {
        Write-ErrorLog "Failed to download Winget bundle or license."
        return $false
    }
}

function Bootstrap-WindowsTerminal {
    param ([string]$TempDir)

    Write-Log "===== Checking and Bootstrapping Windows Terminal ====="
    
    $terminalInstalled = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -AllUsers
    if ($terminalInstalled) {
        Write-Log "Windows Terminal is already installed."
        return $true
    }

    Write-Log "Windows Terminal is not installed. Proceeding with installation..."

    # Ensure dependencies are met
    if (-not (Bootstrap-Dependencies -TempDir $TempDir)) {
        Write-ErrorLog "Aborting Terminal installation because dependencies failed to install."
        return $false
    }

    $terminalUrl = Get-GitHubReleaseAsset -Repo "microsoft/terminal" -Extension "msixbundle" -FallbackUrl $Global:FallbackTerminalBundle
    $bundlePath = Join-Path $TempDir "Microsoft.WindowsTerminal.msixbundle"

    if (Download-File -Url $terminalUrl -OutPath $bundlePath) {
        try {
            Write-Log "Installing Windows Terminal..."
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop
            Write-Success "Windows Terminal installed successfully!"
            return $true
        } catch {
            Write-ErrorLog "Failed to install Windows Terminal package. Error: $_"
            return $false
        }
    }
    return $false
}

function Bootstrap-PowerShell7 {
    param ([string]$TempDir)

    Write-Log "===== Checking and Bootstrapping PowerShell 7 ====="
    
    $pwshExists = Get-Command "pwsh" -ErrorAction SilentlyContinue
    $defaultInstallPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    
    if ($pwshExists -or (Test-Path -Path $defaultInstallPath)) {
        Write-Log "PowerShell 7 is already installed."
        return $true
    }

    Write-Log "PowerShell 7 is not detected. Installing MSI silently..."
    
    # Query latest stable MSI from GitHub API, or fall back
    $psUrl = $Global:FallbackPowerShellMsi
    try {
        $api = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
        $response = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.assets) {
            $asset = $response.assets | Where-Object { $_.name -like "*win-x64.msi" } | Select-Object -First 1
            if ($asset -and $asset.browser_download_url) {
                $psUrl = $asset.browser_download_url
            }
        }
    } catch {
        Write-WarningLog "Failed to query latest PowerShell 7 release from API. Using fallback: $psUrl"
    }

    $msiPath = Join-Path $TempDir "PowerShell7_Install.msi"

    if (Download-File -Url $psUrl -OutPath $msiPath) {
        try {
            Write-Log "Running silent MSI installer for PowerShell 7..."
            $arguments = "/package `"$msiPath`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENFOLDER=1 ENABLE_PSAUTOMATICUPDATE=1"
            
            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                Write-Success "PowerShell 7 installation completed successfully! (Exit Code: $($process.ExitCode))"
                return $true
            } else {
                Write-ErrorLog "msiexec failed with exit code: $($process.ExitCode)"
                return $false
            }
        } catch {
            Write-ErrorLog "Failed to run MSI installer. Error: $_"
            return $false
        }
    }
    return $false
}

function Bootstrap-Chocolatey {
    Write-Log "===== Checking and Bootstrapping Chocolatey (Fallback Package Manager) ====="
    
    $chocoExists = Get-Command "choco" -ErrorAction SilentlyContinue
    if ($chocoExists) {
        Write-Log "Chocolatey is already installed."
        return $true
    }

    Write-Log "Chocolatey is not detected. Installing Chocolatey..."
    try {
        # Force TLS 1.2
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        
        # Download and run the install.ps1 script
        $installScriptUrl = "https://community.chocolatey.org/install.ps1"
        $scriptContent = Invoke-RestMethod -Uri $installScriptUrl -UseBasicParsing -ErrorAction Stop
        
        # Run the installation script in the current session
        Invoke-Expression $scriptContent
        
        # Add Chocolatey's path to the current session env:Path if not already present
        $chocoPath = Join-Path $env:ALLUSERSPROFILE "chocolatey\bin"
        if (-not ($env:PATH -like "*$chocoPath*")) {
            $env:PATH += ";$chocoPath"
        }
        
        # Refresh env variables for the current session (Chocolatey sets chocolateyInstall)
        $env:ChocolateyInstall = [System.Environment]::GetEnvironmentVariable("ChocolateyInstall", "Machine")
        
        # Verify it works
        $testChoco = Get-Command "choco" -ErrorAction SilentlyContinue
        if ($testChoco) {
            Write-Success "Chocolatey installed successfully!"
            return $true
        } else {
            Write-ErrorLog "Chocolatey command was not registered in the session PATH after installation."
            return $false
        }
    } catch {
        Write-ErrorLog "Failed to install Chocolatey. Error: $_"
        return $false
    }
}

function Run-BootstrapProcess {
    param (
        [bool]$InstallWinget = $true,
        [bool]$InstallTerminal = $true,
        [bool]$InstallPS7 = $true
    )

    $tempPath = Join-Path $PSScriptRoot "..\temp"
    if (-not (Test-Path -Path $tempPath)) {
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    }

    $allSuccess = $true

    if ($InstallWinget) {
        $res = Bootstrap-Winget -TempDir $tempPath
        if (-not $res) { 
            Write-WarningLog "WinGet installation failed! Bootstrapping Chocolatey as a backup..."
            $chocoRes = Bootstrap-Chocolatey
            if (-not $chocoRes) {
                $allSuccess = $false
            }
        }
    }
    if ($InstallTerminal) {
        $res = Bootstrap-WindowsTerminal -TempDir $tempPath
        if (-not $res) { $allSuccess = $false }
    }
    if ($InstallPS7) {
        $res = Bootstrap-PowerShell7 -TempDir $tempPath
        if (-not $res) { $allSuccess = $false }
    }

    # Clean up temp folder
    Write-Log "Cleaning up temporary files..."
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $allSuccess
}
