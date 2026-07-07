# Setup.ps1
# Main entrypoint script for Windows Setup Utility (Chocolatey Version)
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
$scriptDir = $PSScriptRoot
$modulesDir = Join-Path $scriptDir "modules"

# Dot source modules
. (Join-Path $modulesDir "utils.ps1")
. (Join-Path $modulesDir "bootstrap.ps1")
. (Join-Path $modulesDir "packages.ps1")

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
        [bool]$RunPackages = $true,
        [bool]$RebootIfRequired = $true
    )

    Write-Log "===== WINDOWS SETUP PIPELINE STARTED ====="
    $globalRebootNeeded = $false

    # Step 1: Bootstrapping (Chocolatey, Terminal, PowerShell 7)
    if ($RunBootstrap) {
        Run-PipelineStep "Bootstrap Core Tools" {
            $bootstrapSuccess = Run-BootstrapProcess `
                -InstallChocolatey ($config.Bootstrap.InstallChocolatey) `
                -InstallTerminal ($config.Bootstrap.InstallWindowsTerminal) `
                -InstallPS7 ($config.Bootstrap.InstallPowerShell7)
                
            if (-not $bootstrapSuccess) {
                Write-WarningLog "One or more core tools failed to bootstrap."
            }
        }
    }

    # Step 2: Application Packages List
    if ($RunPackages -and $null -ne $config.Packages) {
        Run-PipelineStep "Application Package Provisioning" {
            if ($null -ne $config.Packages.InstallList) {
                Install-SystemPackages -PackageList ($config.Packages.InstallList)
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
            Write-Host " [1] Run FULL Setup (Bootstrap + Applications)"
            Write-Host " [2] Run Core Bootstrapping Only (Chocolatey, Terminal, PS7)"
            Write-Host " [3] Install Applications List (Chocolatey)"
            Write-Host " [4] Reboot System"
            Write-Host " [5] Exit"
            Write-Host "==========================================================" -ForegroundColor Cyan
            
            $choice = Read-Host "Select an option [1-5]"
            switch ($choice) {
                "1" { Execute-FullSetup -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "2" { Execute-FullSetup -RunBootstrap $true -RunPackages $false -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "3" { Execute-FullSetup -RunBootstrap $false -RunPackages $true -RebootIfRequired $false; Read-Host "Press Enter to return..." }
                "4" { Restart-Computer -Force }
                "5" { exit }
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
                Title="Windows Setup Utility" Height="500" Width="800"
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
                            <TextBlock Text="Automated bootstrapping &amp; package provisioning framework" FontSize="12" Foreground="#8E8EA2" Margin="0,4,0,0"/>
                        </StackPanel>
                        <TextBlock HorizontalAlignment="Right" VerticalAlignment="Center" Text="v1.2.0" Foreground="#06B6D4" FontSize="14" FontWeight="Bold"/>
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
                                    <CheckBox Name="chkInstallChoco" Content="Bootstrap Chocolatey" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkInstallTerminal" Content="Bootstrap Windows Terminal" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,6"/>
                                    <CheckBox Name="chkInstallPS7" Content="Bootstrap PowerShell 7" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,4"/>
                                </StackPanel>
                            </Border>

                            <!-- Provisioning -->
                            <Border BorderBrush="#2A2A3F" BorderThickness="0,0,0,1" Padding="0,0,0,10" Margin="0,0,0,10">
                                <StackPanel>
                                    <TextBlock Text="Application Provisioning" FontSize="12" FontWeight="Bold" Foreground="#8B5CF6" Margin="0,0,0,8"/>
                                    <CheckBox Name="chkRunPackages" Content="Install Applications List" Foreground="#D1D5DB" IsChecked="True" Margin="0,0,0,4"/>
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
                                    </Setter>
                                </Style>
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
                                    </Setter>
                                </Style>
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
            $wpfchkInstallChoco.IsEnabled = $false
            $wpfchkInstallTerminal.IsEnabled = $false
            $wpfchkInstallPS7.IsEnabled = $false
            $wpfchkRunPackages.IsEnabled = $false
            $wpfchkReboot.IsEnabled = $false
            
            $wpftxtConsoleLog.Clear()
            $Global:UIConsoleTextBox = $wpftxtConsoleLog
            
            # Sync configuration object with GUI checkbox states
            $config.Bootstrap.InstallChocolatey = $wpfchkInstallChoco.IsChecked -eq $true
            $config.Bootstrap.InstallWindowsTerminal = $wpfchkInstallTerminal.IsChecked -eq $true
            $config.Bootstrap.InstallPowerShell7 = $wpfchkInstallPS7.IsChecked -eq $true

            # Execute Pipeline
            try {
                Execute-FullSetup `
                    -RunBootstrap ($wpfchkInstallChoco.IsChecked -eq $true -or $wpfchkInstallTerminal.IsChecked -eq $true -or $wpfchkInstallPS7.IsChecked -eq $true) `
                    -RunPackages ($wpfchkRunPackages.IsChecked -eq $true) `
                    -RebootIfRequired ($wpfchkReboot.IsChecked -eq $true)
            } finally {
                # Re-enable inputs
                $wpfbtnRun.IsEnabled = $true
                $wpfbtnCancel.IsEnabled = $true
                $wpfchkInstallChoco.IsEnabled = $true
                $wpfchkInstallTerminal.IsEnabled = $true
                $wpfchkInstallPS7.IsEnabled = $true
                $wpfchkRunPackages.IsEnabled = $true
                $wpfchkReboot.IsEnabled = $true
                $Global:UIConsoleTextBox = $null
            }
        })

        # Show GUI dialog block
        $window.ShowDialog() | Out-Null
    }
}
