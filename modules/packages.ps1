# modules/packages.ps1
# Handles Chocolatey packages installation and custom installers

. (Join-Path $PSScriptRoot "utils.ps1")

function Install-SystemPackages {
    param (
        [array]$PackageList = @()
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
        [array]$CustomInstallersList = @()
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
                if ($installFile -like "*.zip") {
                    $destination = $installer.Destination
                    if ([string]::IsNullOrEmpty($destination)) {
                        $destination = Join-Path $env:ProgramFiles $name
                    }
                    
                    Write-Log "Extracting ZIP archive: $installFile to $destination ..."
                    if (-not (Test-Path -Path $destination)) {
                        New-Item -ItemType Directory -Path $destination -Force | Out-Null
                    }
                    Expand-Archive -Path $installFile -DestinationPath $destination -Force
                    
                    # Create a btop.exe copy of btop4win.exe if it exists, to allow running with 'btop'
                    $btop4winExe = Join-Path $destination "btop4win.exe"
                    $btopExe = Join-Path $destination "btop.exe"
                    if ((Test-Path -Path $btop4winExe) -and -not (Test-Path -Path $btopExe)) {
                        Copy-Item -Path $btop4winExe -Destination $btopExe -Force
                    }
                    
                    Write-Success "ZIP package '$name' extracted successfully to $destination."
                    
                    if ($installer.AddToPath -eq $true) {
                        $pathKey = "HKLM:\System\CurrentControlSet\Control\Session Manager\Environment"
                        $currentPath = (Get-ItemProperty -Path $pathKey -Name "Path").Path
                        if ($currentPath -notlike "*$destination*") {
                            $newPath = $currentPath + ";" + $destination
                            Set-ItemProperty -Path $pathKey -Name "Path" -Value $newPath -Force | Out-Null
                            # Also update current session's PATH
                            $env:PATH = $env:PATH + ";" + $destination
                            Write-Log "Added $destination to System PATH."
                        }
                    }
                } else {
                    Write-Log "Executing installer: $installFile with arguments: $args ..."
                    $process = Start-Process -FilePath $installFile -ArgumentList $args -Wait -NoNewWindow -PassThru -ErrorAction Stop
                    
                    if ($process.ExitCode -eq 0) {
                        Write-Success "Custom installer '$name' executed successfully."
                    } else {
                        Write-ErrorLog "Custom installer '$name' failed with exit code: $($process.ExitCode)"
                        $allSuccess = $false
                    }
                }
            } catch {
                Write-ErrorLog "Failed to install custom package '$name'. Error: $_"
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

function Install-SystemNerdFonts {
    param (
        [array]$FontList = @()
    )

    if ($FontList.Count -eq 0) {
        return
    }

    Write-Log "===== Installing Nerd Fonts System-Wide ====="
    
    # Load PresentationCore to read font metadata
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    } catch {
        Write-WarningLog "Failed to load PresentationCore. Font names will be registered based on filenames."
    }

    # Query latest release tag from GitHub, or fallback
    $repo = "ryanoasis/nerd-fonts"
    $tag = "v3.4.0"
    try {
        $api = "https://api.github.com/repos/$repo/releases/latest"
        $response = Invoke-RestMethod -Uri $api -UseBasicParsing -ErrorAction Stop
        if ($response -and $response.tag_name) {
            $tag = $response.tag_name
        }
    } catch {
        Write-WarningLog "Failed to query latest Nerd Fonts version. Using fallback: $tag"
    }

    $tempPath = Join-Path $PSScriptRoot "..\temp_fonts"
    if (-not (Test-Path -Path $tempPath)) {
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    }

    $fontsFolder = Join-Path $env:SystemRoot "Fonts"
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

    foreach ($font in $FontList) {
        Write-Log "Processing Nerd Font: $font ..."
        
        $zipUrl = "https://github.com/$repo/releases/download/$tag/$font.zip"
        $destZip = Join-Path $tempPath "$font.zip"
        
        # Download font zip
        if (-not (Download-File -Url $zipUrl -OutPath $destZip)) {
            Write-ErrorLog "Failed to download Nerd Font: $font"
            continue
        }

        # Extract font zip
        $extractDir = Join-Path $tempPath $font
        if (Test-Path -Path $extractDir) {
            Remove-Item -Path $extractDir -Recurse -Force | Out-Null
        }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        try {
            Write-Log "Extracting $font.zip ..."
            Expand-Archive -Path $destZip -DestinationPath $extractDir -Force
            
            # Find all font files (.ttf, .otf)
            $fontFiles = Get-ChildItem -Path $extractDir -File -Recurse | Where-Object { $_.Extension -eq ".ttf" -or $_.Extension -eq ".otf" }
            
            Write-Log "Found $($fontFiles.Count) font files for $font."
            
            foreach ($file in $fontFiles) {
                $targetPath = Join-Path $fontsFolder $file.Name
                
                # Extract internal font name
                $fontRegistryName = $null
                try {
                    $uri = New-Object System.Uri($file.FullName)
                    $typeface = New-Object System.Windows.Media.GlyphTypeface($uri)
                    
                    $familyName = $typeface.Win32FamilyNames["en-us"]
                    if (-not $familyName) {
                        $familyName = ($typeface.Win32FamilyNames.Values | Select-Object -First 1)
                    }
                    
                    $faceName = $typeface.Win32FaceNames["en-us"]
                    if (-not $faceName) {
                        $faceName = ($typeface.Win32FaceNames.Values | Select-Object -First 1)
                    }
                    
                    if ($familyName) {
                        $fontRegistryName = "$familyName"
                        if ($faceName -and $faceName -ne "Regular") {
                            $fontRegistryName += " $faceName"
                        }
                        
                        if ($file.Extension -eq ".otf") {
                            $fontRegistryName += " (OpenType)"
                        } else {
                            $fontRegistryName += " (TrueType)"
                        }
                    }
                } catch {
                    # Log warning but continue with fallback name
                    Write-WarningLog "Could not read typeface metadata for $($file.Name): $_"
                }

                # Fallback registry name if we couldn't parse metadata
                if ([string]::IsNullOrEmpty($fontRegistryName)) {
                    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).Replace("-", " ").Replace("_", " ")
                    if ($file.Extension -eq ".otf") {
                        $fontRegistryName = "$cleanName (OpenType)"
                    } else {
                        $fontRegistryName = "$cleanName (TrueType)"
                    }
                }

                # Copy to C:\Windows\Fonts if not already present or if we need to overwrite
                try {
                    if (-not (Test-Path -Path $targetPath)) {
                        Copy-Item -Path $file.FullName -Destination $targetPath -Force
                    }
                } catch {
                    Write-WarningLog "Failed to copy font file $($file.Name) to Fonts directory (it may be in use)."
                }

                # Register in HKLM Registry
                try {
                    Set-ItemProperty -Path $registryPath -Name $fontRegistryName -Value $file.Name -Force | Out-Null
                } catch {
                    Write-ErrorLog "Failed to write registry entry for font: $fontRegistryName"
                }
            }
            
            Write-Success "Nerd Font '$font' installed and registered successfully."
            
        } catch {
            Write-ErrorLog "Failed to install Nerd Font '$font'. Error: $_"
        } finally {
            # Clean up font extraction dir and zip
            if (Test-Path -Path $extractDir) {
                Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if (Test-Path -Path $destZip) {
                Remove-Item -Path $destZip -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # Clean temporary fonts directory
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}
