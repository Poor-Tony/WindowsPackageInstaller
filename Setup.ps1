# Setup.ps1
# Main entrypoint script for Windows Setup Utility
# Usage: .\Setup.ps1 [-Mode <CLI|GUI|Unattended>] [-ConfigPath <path>]

[CmdletBinding()]
param (
    [ValidateSet("CLI", "GUI", "Unattended")]
    [string]$Mode = "GUI",
    [string]$ConfigPath = "config.json"
)

# 1. Relaunch check for Administrator and STA Mode (WPF UI requires STA)
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSTA = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not $isElevated -or ($Mode -eq "GUI" -and -not $isSTA)) {
    $argsList = "-NoProfile -ExecutionPolicy Bypass"
    if ($Mode -eq "GUI" -and -not $isSTA) {
        $argsList += " -STA"
    }
    
    # Pass along parameter arguments
    $argsList += " -File `"$PSCommandPath`""
    if ($PSBoundParameters.ContainsKey('Mode')) {
        $argsList += " -Mode $Mode"
    }
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $argsList += " -ConfigPath `"$ConfigPath`""
    }

    # Relaunch process elevated
    Start-Process powershell.exe -ArgumentList $argsList -Verb RunAs
    exit
}

# 2. Set Script Directory and Import Modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $scriptDir "modules"

# Dot source modules
. (Join-Path $modulesDir "utils.ps1")
. (Join-Path $modulesDir "bootstrap.ps1")
. (Join-Path $modulesDir "packages.ps1")
. (Join-Path $modulesDir "features.ps1")
. (Join-Path $modulesDir "iot.ps1")
. (Join-Path $modulesDir "security.ps1")

# Verify configuration file
$resolvedConfigPath = Resolve-Path -Path (Join-Path $scriptDir $ConfigPath) -ErrorAction SilentlyContinue
if (-not $resolvedConfigPath) {
    Write-ErrorLog "Configuration file not found: $ConfigPath"
    exit 1
}

# Load configuration JSON
try {
    $configContent = Get-Content -Raw -Path $resolvedConfigPath -ErrorAction Stop
    $config = ConvertFrom-Json -InputObject $configContent -ErrorAction Stop
    
    # Configure global logging settings from config.json
    if ($null -ne $config.System) {
        if ($null -ne $config.System.LogFilePath) {
            $Global:LogFilePath = $config.System.LogFilePath
        }
        if ($null -ne $config.System.LoggingEnabled) {
            $Global:LoggingEnabled = [bool]$config.System.LoggingEnabled
        }
    }
} catch {
    Write-ErrorLog "Failed to parse config.json. Error: $_"
    exit 1
}

# 3. Core Setup Pipeline Execution
function Run-PipelineStep {
    param (
        [string]$StepName,
        [scriptblock]$Action
    )
    Write-Log "--------------------------------------------"
    Write-Log "Executing Step: $StepName"
    Write-Log "--------------------------------------------"
    
    try {
        & $Action
    } catch {
        Write-ErrorLog "Step '$StepName' threw an unhandled exception: $_"
    }
}

function Execute-FullSetup {
    param (
        [bool]$RunBootstrap = $true,
        [bool]$RunFeatures = $true,
        [bool]$RunIoT = $true,
        [bool]$RunSecurity = $true,
        [bool]$RunPackages = $true,
        [bool]$RebootIfRequired = $true
    )

    Write-Log "===== WINDOWS SETUP PIPELINE STARTED ====="
    $globalRebootNeeded = $false

    # Step 1: Bootstrapping (WinGet, Terminal, PowerShell 7)
    if ($RunBootstrap) {
        Run-PipelineStep "Bootstrap Core Tools" {
            $bootstrapSuccess = Run-BootstrapProcess `
                -InstallWinget ($config.Bootstrap.InstallWinget) `
                -InstallTerminal ($config.Bootstrap.InstallWindowsTerminal) `
                -InstallPS7 ($config.Bootstrap.InstallPowerShell7)
                
            if (-not $bootstrapSuccess) {
                Write-WarningLog "One or more core tools failed to bootstrap. Proceeding with remaining steps..."
            }
        }
    }

    # Step 2: System optional features and services
    if ($RunFeatures -and $null -ne $config.Features) {
        Run-PipelineStep "Optional Features & Services" {
            $rebootNeeded = Configure-WindowsFeatures `
                -EnableList ($config.Features.Enable) `
                -DisableList ($config.Features.Disable)
                
            if ($rebootNeeded) { $globalRebootNeeded = $true }
            
            if ($null -ne $config.Services -and $null -ne $config.Services.Configure) {
                Configure-WindowsServices -ServiceConfigList ($config.Services.Configure)
            }
        }
    }

    # Step 3: IoT Specific Settings
    if ($RunIoT -and $null -ne $config.IoT) {
        Run-PipelineStep "IoT Registry Configurations" {
            if ($null -ne $config.IoT.ShellLauncher) {
                Configure-ShellLauncher `
                    -Enable ($config.IoT.ShellLauncher.Enable) `
                    -ShellPath ($config.IoT.ShellLauncher.ShellPath)
            }
            
            if ($null -ne $config.IoT.AutoLogon) {
                Configure-AutoLogon `
                    -Enable ($config.IoT.AutoLogon.Enable) `
                    -Username ($config.IoT.AutoLogon.Username) `
                    -Password ($config.IoT.AutoLogon.Password) `
                    -Domain ($config.IoT.AutoLogon.Domain)
            }
            
            if ($null -ne $config.IoT.LockScreen) {
                Configure-LockScreenSettings `
                    -DisableLockScreen ($config.IoT.LockScreen.DisableLockScreen) `
                    -DisableKeyCombinations ($config.IoT.LockScreen.DisableKeyCombinations)
            }
            
            if ($null -ne $config.IoT.UnifiedWriteFilter) {
                Configure-UnifiedWriteFilter `
                    -Configure ($config.IoT.UnifiedWriteFilter.Configure) `
                    -OverlayType ($config.IoT.UnifiedWriteFilter.OverlayType) `
                    -OverlaySizeMB ($config.IoT.UnifiedWriteFilter.OverlaySizeMB) `
                    -Exclusions ($config.IoT.UnifiedWriteFilter.Exclusions)
            }
        }
    }

    # Step 4: Security (Defender & UAC)
    if ($RunSecurity -and $null -ne $config.Security) {
        Run-PipelineStep "Security Policy Settings" {
            if ($null -ne $config.Security.UAC) {
                Configure-UAC `
                    -ConsentPromptBehaviorAdmin ($config.Security.UAC.ConsentPromptBehaviorAdmin) `
                    -EnableLUA ($config.Security.UAC.EnableLUA)
                # UAC disable requires reboot
                if ($config.Security.UAC.EnableLUA -eq 0) {
                    $globalRebootNeeded = $true
                }
            }
            
            if ($null -ne $config.Security.Defender) {
                Configure-WindowsDefender `
                    -RealTimeProtection ($config.Security.Defender.RealTimeProtection) `
                    -Exclusions ($config.Security.Defender.Exclusions)
            }
        }
    }

    # Step 5: Winget Applications List
    if ($RunPackages -and $null -ne $config.Packages) {
        Run-PipelineStep "Application Package Provisioning" {
            if ($config.Packages.Winget.Enable -and $null -ne $config.Packages.Winget.InstallList) {
                Install-WingetPackages -PackageList ($config.Packages.Winget.InstallList)
            }
            if ($null -ne $config.Packages.CustomInstallers) {
                Install-CustomInstallers -CustomInstallersList ($config.Packages.CustomInstallers)
            }
        }
    }

    Write-Log "=========================================="
    Write-Log "===== PIPELINE EXECUTION COMPLETED ====="
    Write-Log "=========================================="

    if ($globalRebootNeeded) {
        Write-WarningLog "A system reboot is required to apply all configurations."
        if ($RebootIfRequired) {
            Write-Log "Initiating system reboot in 10 seconds (Unattended Mode)..."
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        }
    }
}

# 4. Handle Execution Modes
switch ($Mode) {
    "Unattended" {
        Write-Log "Starting Unattended Mode..."
        Execute-FullSetup -RebootIfRequired ($config.System.RebootIfRequired)
    }
    
    "CLI" {
        # Console Mode interactive menu
        while ($true) {
            Clear-Host
            $os = Get-OSInfo
            Write-Host "==========================================================" -ForegroundColor Cyan
            Write-Host "         Windows Setup Utility - CLI Controller           " -ForegroundColor Cyan
            Write-Host "==========================================================" -ForegroundColor Cyan
            Write-Host " Detected OS : $($os.Caption) ($($os.Architecture))" -ForegroundColor Gray
            Write-Host " Build       : $($os.BuildNumber) " -ForegroundColor Gray
            Write-Host " Log File    : $Global:LogFilePath" -ForegroundColor Gray
            Write-Host "----------------------------------------------------------"
            Write-Host " [1] Run FULL Setup (Unattended Run-List)"
            Write-Host " [2] Run Core Bootstrapping Only (WinGet, Terminal, PS7)"
            Write-Host " [3] Apply Optional Features & Services Config"
            Write-Host " [4] Apply IoT Tweaks (UWF, Auto-Logon, custom shell)"
            Write-Host " [5] Apply Security Policy Settings (Defender, UAC)"
            Write-Host " [6] Install Applications List (Winget + Custom)"
            Write-Host " [7] Reboot System"
            Write-Host " [8] Exit"
            Write-Host "==========================================================" -ForegroundColor Cyan
            
            $choice = Read-Host "Select an option [1-8]"
            switch ($choice) {
                "1" { Execute-FullSetup -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "2" { Execute-FullSetup -RunBootstrap $true -RunFeatures $false -RunIoT $false -RunSecurity $false -RunPackages $false -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "3" { Execute-FullSetup -RunBootstrap $false -RunFeatures $true -RunIoT $false -RunSecurity $false -RunPackages $false -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "4" { Execute-FullSetup -RunBootstrap $false -RunFeatures $false -RunIoT $true -RunSecurity $false -RunPackages $false -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "5" { Execute-FullSetup -RunBootstrap $false -RunFeatures $false -RunIoT $false -RunSecurity $true -RunPackages $false -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "6" { Execute-FullSetup -RunBootstrap $false -RunFeatures $false -RunIoT $false -RunSecurity $false -RunPackages $true -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "7" { Restart-Computer -Force }
                "8" { exit }
            }
        }
    }
    
    "GUI" {
        # Load WPF assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase

        # XAML Layout String
        $xaml = @"
        <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                Title="Windows IoT LTSC Setup Utility" Height="620" Width="850"
                WindowStartupLocation="CenterScreen" Background="#12121E" Foreground="#FFFFFF"
                BorderBrush="#3B2E5C" BorderThickness="1" ResizeMode="NoResize">
            <Grid Margin="15">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                
                <!-- Header -->
                <Border Grid.Row="0" BorderBrush="#252538" BorderThickness="0,0,0,1" Padding="0,0,0,15" Margin="0,0,0,15">
                    <Grid>
                        <StackPanel>
                            <TextBlock Text="Windows Setup Utility" FontSize="24" FontWeight="Bold" Foreground="#8B5CF6"/>
                            <TextBlock Text="Automated OS deployment, bootstrapping &amp; provisioning framework" FontSize="12" Foreground="#8E8EA2" Margin="0,4,0,0"/>
                        </StackPanel>
                        <TextBlock HorizontalAlignment="Right" VerticalAlignment="Center" Text="v1.0.0" Foreground="#06B6D4" FontSize="14" FontWeight="Bold"/>
                    </Grid>
                </Border>
                
                <!-- Main Layout -->
                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="320"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    
                    <!-- Left Options Panel -->
                    <Border Grid.Column="0" Background="#181829" CornerRadius="8" Padding="15" Margin="0,0,15,0">
                        <StackPanel>
                            <TextBlock Text="Execution Options" FontSize="16" FontWeight="SemiBold" Foreground="#F3F4F6" Margin="0,0,0,15"/>
                            
                            <!-- Bootstrap -->
                            <Border BorderBrush="#2A2A3F" BorderThickness="0,0,0,1" Padding="0,0,0,10" Margin="0,0,0,10">
                                <StackPanel>
                                    <TextBlock Text="Bootstrap Packages" FontSize="12" FontWeight="Bold" Foreground="#8B5CF6" Margin="0,0,0,8"/>
                                    <CheckBox Name="chkInstallWinget" Content="Bootstrap WinGet" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkInstallTerminal" Content="Bootstrap Windows Terminal" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkInstallPS7" Content="Bootstrap PowerShell 7" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,4"/>
                                </StackPanel>
                            </Border>

                            <!-- Modules -->
                            <Border BorderBrush="#2A2A3F" BorderThickness="0,0,0,1" Padding="0,0,0,10" Margin="0,0,0,10">
                                <StackPanel>
                                    <TextBlock Text="Configuration Modules" FontSize="12" FontWeight="Bold" Foreground="#8B5CF6" Margin="0,0,0,8"/>
                                    <CheckBox Name="chkRunFeatures" Content="Enable Optional Features &amp; Services" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkRunIoT" Content="Apply IoT Settings (UWF, shell, auto-logon)" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkRunSecurity" Content="Configure Security Policies (UAC, Defender)" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkRunPackages" Content="Install Winget Applications List" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,4"/>
                                </StackPanel>
                            </Border>

                            <!-- Post Execution -->
                            <StackPanel>
                                <TextBlock Text="Post-Execution" FontSize="12" FontWeight="Bold" Foreground="#8B5CF6" Margin="0,0,0,8"/>
                                <CheckBox Name="chkReboot" Content="Reboot System if Required" Foreground="#D1D5DB" IsChecked="False"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                    
                    <!-- Right Logs Panel -->
                    <Border Grid.Column="1" Background="#0C0C14" CornerRadius="8" BorderBrush="#252538" BorderThickness="1">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <Border Grid.Row="0" Background="#141424" CornerRadius="7,7,0,0" Padding="10">
                                <TextBlock Text="Live Execution Console Log" FontSize="12" FontWeight="SemiBold" Foreground="#8E8EA2"/>
                            </Border>
                            
                            <TextBox Grid.Row="1" Name="txtConsoleLog" Background="Transparent" Foreground="#10B981" BorderThickness="0"
                                     FontFamily="Consolas" FontSize="11" IsReadOnly="True" VerticalScrollBarVisibility="Auto" 
                                     AcceptsReturn="True" TextWrapping="Wrap" Margin="10"/>
                        </Grid>
                    </Border>
                </Grid>
                
                <!-- Footer / Info -->
                <Grid Grid.Row="2" Margin="0,15,0,0">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <TextBlock Text="Target OS: " Foreground="#8E8EA2"/>
                        <TextBlock Name="lblDetectedOS" Text="Checking..." Foreground="#F3F4F6" FontWeight="SemiBold"/>
                    </StackPanel>
                    
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="btnCancel" Content="Close" Width="100" Height="35" Background="#2A2A3F" Foreground="#FFFFFF" BorderThickness="0" Margin="0,0,10,0">
                            <Button.Resources>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border Background="{TemplateBinding Background}" CornerRadius="5">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Border>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Button.Resources>
                        </Button>
                        
                        <Button Name="btnRun" Content="RUN SETUP" Width="150" Height="35" Background="#8B5CF6" Foreground="#FFFFFF" FontWeight="Bold" BorderThickness="0">
                            <Button.Resources>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border Background="{TemplateBinding Background}" CornerRadius="5">
                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Border>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Button.Resources>
                        </Button>
                    </StackPanel>
                </Grid>
            </Grid>
        </Window>
"@

        # Parse XAML
        [xml]$xml = $xaml
        $reader = New-Object System.Xml.XmlNodeReader $xml
        $window = [System.Windows.Markup.XamlReader]::Load($reader)

        # Automatically map all controls with Name attribute to variables (prefixed with wpf)
        $xml.SelectNodes("//*[@Name]") | ForEach-Object {
            Set-Variable -Name "wpf$($_.Name)" -Value $window.FindName($_.Name) -Scope Script
        }

        # Initialize labels with current OS
        $os = Get-OSInfo
        $wpflblDetectedOS.Text = "$($os.Caption) ($($os.Architecture)) - Build $($os.BuildNumber)"

        # Button Cancel Event
        $wpfbtnCancel.Add_Click({
            $window.Close()
        })

        # Button Run Event
        $wpfbtnRun.Add_Click({
            # Disable inputs during run
            $wpfbtnRun.IsEnabled = $false
            $wpfbtnCancel.IsEnabled = $false
            $wpfchkInstallWinget.IsEnabled = $false
            $wpfchkInstallTerminal.IsEnabled = $false
            $wpfchkInstallPS7.IsEnabled = $false
            $wpfchkRunFeatures.IsEnabled = $false
            $wpfchkRunIoT.IsEnabled = $false
            $wpfchkRunSecurity.IsEnabled = $false
            $wpfchkRunPackages.IsEnabled = $false
            $wpfchkReboot.IsEnabled = $false
            
            $wpftxtConsoleLog.Clear()
            $Global:UIConsoleTextBox = $wpftxtConsoleLog
            
            # Sync configuration object with GUI checkbox states
            $config.Bootstrap.InstallWinget = $wpfchkInstallWinget.IsChecked -eq $true
            $config.Bootstrap.InstallWindowsTerminal = $wpfchkInstallTerminal.IsChecked -eq $true
            $config.Bootstrap.InstallPowerShell7 = $wpfchkInstallPS7.IsChecked -eq $true

            # Execute Pipeline
            try {
                Execute-FullSetup `
                    -RunBootstrap ($wpfchkInstallWinget.IsChecked -eq $true -or $wpfchkInstallTerminal.IsChecked -eq $true -or $wpfchkInstallPS7.IsChecked -eq $true) `
                    -RunFeatures ($wpfchkRunFeatures.IsChecked -eq $true) `
                    -RunIoT ($wpfchkRunIoT.IsChecked -eq $true) `
                    -RunSecurity ($wpfchkRunSecurity.IsChecked -eq $true) `
                    -RunPackages ($wpfchkRunPackages.IsChecked -eq $true) `
                    -RebootIfRequired ($wpfchkReboot.IsChecked -eq $true)
            } finally {
                # Re-enable inputs
                $wpfbtnRun.IsEnabled = $true
                $wpfbtnCancel.IsEnabled = $true
                $wpfchkInstallWinget.IsEnabled = $true
                $wpfchkInstallTerminal.IsEnabled = $true
                $wpfchkInstallPS7.IsEnabled = $true
                $wpfchkRunFeatures.IsEnabled = $true
                $wpfchkRunIoT.IsEnabled = $true
                $wpfchkRunSecurity.IsEnabled = $true
                $wpfchkRunPackages.IsEnabled = $true
                $wpfchkReboot.IsEnabled = $true
                $Global:UIConsoleTextBox = $null
            }
        })

        # Show GUI dialog block
        $window.ShowDialog() | Out-Null
    }
}
