<#
Notes:
	Run from an admin PowerShell window:
	  irm a.xon.ac/dns|iex                  (prompts for the site key)
	  $k='SITEKEY';irm a.xon.ac/dns|iex     (key inline)
#>

##### Required Variables #####

$client      = if ($k) { $k } elseif ($env:DNSClientId) { $env:DNSClientId } else { Read-Host "ScoutDNS site key" }
$downloadURL = "https://download.scoutdns.com/device_agent/installers/scoutdns-agent-win-x64.msi"
$outFile     = "C:\Axon\dnsScout.msi"
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on PS 5.1

##### Functions #####

# Waits until no other Windows Installer job is running
function Wait-MsiIdle {
    param([int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute').Dispose()
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return $true    # mutex doesn't exist = installer is idle
        } catch {
            # mutex exists but couldn't be opened - still busy
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

# Waits for the installer to be free, runs msiexec, waits for it, returns the exit code
function Invoke-Msi {
    param([string]$Arguments)
    if (-not (Wait-MsiIdle)) { return 1618 }
    (Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru).ExitCode
}

# Uninstalls a package by name; skips if not installed, stops the script if it fails
function Uninstall-App {
    param([string]$Name)
    $codes = (Get-Package -Name $Name -ErrorAction SilentlyContinue).FastPackageReference
    if (-not $codes) { Write-Host "$Name not installed, skipping."; return }
    foreach ($code in $codes) {
        Write-Host "Uninstalling $Name..."
        $exit = Invoke-Msi "/X$code /qn /norestart"
        Write-Host "$Name uninstall exit code: $exit"
        if ($exit -notin 0, 1605, 3010) {   # 1605 = not installed, 3010 = success, reboot needed
            throw "ERROR: $Name uninstall failed ($exit). Aborting."
        }
    }
}

##### Script Logic #####

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "ERROR: Run this from an admin PowerShell window"
}
if (-not $client) { throw "ERROR: No ScoutDNS site key provided" }

# Download first, while DNS still works normally
if (!(Test-Path -Path 'C:\Axon\')) { Write-Host "Creating Path: C:\Axon\..."; New-Item -Path "C:\" -Name "Axon" -ItemType Directory -Force | Out-Null }
if ([Net.SecurityProtocolType]::Tls12) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
Write-Host "Downloading ScoutDNS..."
try {
    Invoke-WebRequest -Uri $downloadURL -OutFile $outFile -UseBasicParsing -ErrorAction Stop
} catch {
    throw "ERROR: ScoutDNS download failed: $($_.Exception.Message)"
}
if ((Get-Item $outFile).Length -eq 0) { throw "ERROR: Downloaded ScoutDNS installer is empty" }

# Remove old agents
Uninstall-App "DNS Agent"
Uninstall-App "CyberSight Agent"

# Install ScoutDNS
Write-Host "Installing ScoutDNS..."
$exit = Invoke-Msi "/i `"$outFile`" /qn /norestart INSTALLKEY=$client"
Write-Host "ScoutDNS install exit code: $exit"
if ($exit -notin 0, 3010) { throw "ERROR: ScoutDNS install failed ($exit)" }
if ($exit -eq 3010) { Write-Host "ScoutDNS installed. Reboot required to finish." -ForegroundColor Yellow }
else                { Write-Host "ScoutDNS installed successfully." -ForegroundColor Green }