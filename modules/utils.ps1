# modules/utils.ps1
# Core utility functions for Windows Setup Utility

# Force TLS 1.2 for all web requests (required for GitHub/NuGet downloads on older PowerShell versions)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$Global:LogFilePath = "C:\Windows\Temp\WindowsSetupUtility.log"
$Global:LoggingEnabled = $true
$Global:UIConsoleTextBox = $null

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedMsg = "[$timestamp] [$Level] $Message"

    # Set console color based on log level
    switch ($Level) {
        "SUCCESS" { Write-Host $formattedMsg -ForegroundColor Green }
        "WARNING" { Write-Host $formattedMsg -ForegroundColor Yellow }
        "ERROR"   { Write-Host $formattedMsg -ForegroundColor Red }
        default   { Write-Host $formattedMsg -ForegroundColor White }
    }

    # If GUI textbox is active, write to it and refresh UI events
    if ($null -ne $Global:UIConsoleTextBox) {
        try {
            $Global:UIConsoleTextBox.Dispatcher.Invoke([Action]{
                $Global:UIConsoleTextBox.AppendText($formattedMsg + "`r`n")
                $Global:UIConsoleTextBox.ScrollToEnd()
            })
            
            # Allow UI thread to process events so it stays responsive
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action] { }
            )
        } catch {
            Write-Host "[WARNING] Failed to write to GUI console: $_" -ForegroundColor Yellow
        }
    }

    # Write to log file if enabled
    if ($Global:LoggingEnabled) {
        try {
            $logDir = Split-Path -Path $Global:LogFilePath -Parent
            if (-not (Test-Path -Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $formattedMsg | Out-File -FilePath $Global:LogFilePath -Append -Encoding UTF8
        } catch {
            Write-Host "[WARNING] Failed to write to log file: $_" -ForegroundColor Yellow
        }
    }
}

function Write-Success {
    param ([string]$Message)
    Write-Log -Message $Message -Level "SUCCESS"
}

function Write-WarningLog {
    param ([string]$Message)
    Write-Log -Message $Message -Level "WARNING"
}

function Write-ErrorLog {
    param ([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}

function Assert-Admin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-ErrorLog "This script must be run as Administrator."
        exit 1
    }
}

function Get-OSInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $architecture = $os.OSArchitecture
    
    # Standardize architecture string
    if ($architecture -match "64") {
        $arch = "x64"
    } elseif ($architecture -match "32") {
        $arch = "x86"
    } elseif ($architecture -match "ARM") {
        $arch = "arm64"
    } else {
        $arch = "x64" # fallback
    }

    $isIotLtsc = $false
    if ($os.Caption -match "IoT" -and $os.Caption -match "LTSC") {
        $isIotLtsc = $true
    }

    return [PSCustomObject]@{
        Caption = $os.Caption
        Version = $os.Version
        BuildNumber = $os.BuildNumber
        Architecture = $arch
        IsIoT = $os.Caption -match "IoT"
        IsLtsc = $os.Caption -match "LTSC"
        IsIotLtsc = $isIotLtsc
    }
}

function Download-File {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Url,
        [Parameter(Mandatory=$true)]
        [string]$OutPath
    )

    Write-Log "Downloading $Url to $OutPath ..."
    
    # Ensure parent directory exists
    $dir = Split-Path -Path $OutPath -Parent
    if (-not (Test-Path -Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($Url, $OutPath)
        if (Test-Path -Path $OutPath) {
            Write-Log "Successfully downloaded file." -Level "SUCCESS"
            return $true
        }
    } catch {
        Write-WarningLog "WebClient download failed: $_. Retrying with Invoke-WebRequest..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -ErrorAction Stop
            if (Test-Path -Path $OutPath) {
                Write-Log "Successfully downloaded file using Invoke-WebRequest." -Level "SUCCESS"
                return $true
            }
        } catch {
            Write-ErrorLog "Failed to download $Url. Error: $_"
            return $false
        }
    }
    return $false
}

function Expand-Nupkg {
    param (
        [Parameter(Mandatory=$true)]
        [string]$NupkgUrl,
        [Parameter(Mandatory=$true)]
        [string]$TargetAppxPath,
        [Parameter(Mandatory=$true)]
        [string]$TempDir,
        [Parameter(Mandatory=$true)]
        [string]$InnerAppxPath # relative path inside nupkg
    )

    $tempZip = Join-Path $TempDir "temp_package.zip"
    $extractedDir = Join-Path $TempDir "temp_extracted"

    if (Test-Path -Path $tempZip) { Remove-Item -Path $tempZip -Force }
    if (Test-Path -Path $extractedDir) { Remove-Item -Path $extractedDir -Recurse -Force -ErrorAction SilentlyContinue }

    # Download NuGet package
    $success = Download-File -Url $NupkgUrl -OutPath $tempZip
    if (-not $success) {
        return $false
    }

    try {
        Write-Log "Extracting NuGet package to find $InnerAppxPath ..."
        # Extract archive
        Expand-Archive -Path $tempZip -DestinationPath $extractedDir -Force

        $sourceAppx = Join-Path $extractedDir $InnerAppxPath
        if (Test-Path -Path $sourceAppx) {
            $destDir = Split-Path -Path $TargetAppxPath -Parent
            if (-not (Test-Path -Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -Path $sourceAppx -Destination $TargetAppxPath -Force
            Write-Success "Extracted and copied APPX to $TargetAppxPath"
            return $true
        } else {
            Write-ErrorLog "Could not find expected inner APPX path: $sourceAppx"
            return $false
        }
    } catch {
        Write-ErrorLog "Failed to extract NuGet package. Error: $_"
        return $false
    } finally {
        # Cleanup
        if (Test-Path -Path $tempZip) { Remove-Item -Path $tempZip -Force }
        if (Test-Path -Path $extractedDir) { Remove-Item -Path $extractedDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
