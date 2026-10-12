# Installs .msu/.cab updates from a URL (e.g. the Microsoft Update Catalog) on the local machine.
#
# Usage:     $u='https://.../windows11.0-kb5xxxxxx-x64_....msu';irm a.xon.ac/update|iex
# Multiple:  $u='url1','url2';irm a.xon.ac/update|iex   (installed in the order given)
#
# Must run elevated (Administrator or SYSTEM). Works over PSRemoting, unlike wusa.exe.
# Keep this file ASCII-only: Windows PowerShell 5.1 irm may mis-decode anything else.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar in PS 5.1

    $urls = @($u) | Where-Object { $_ }
    if (-not $urls) { throw 'Set $u to the update URL first, e.g. $u=''https://...msu'';irm a.xon.ac/update|iex' }

    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This must run elevated (Administrator or SYSTEM).'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $dir = Join-Path $env:SystemRoot 'Temp\MSU'
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $dir -ItemType Directory -Force | Out-Null

    $restart = $false
    $failed  = 0
    try {
        # Download everything first so DISM can find checkpoint prerequisites in the same folder
        $files = foreach ($url in $urls) {
            $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath)
            if ($name -notmatch '\.(msu|cab)$') { throw "Not an .msu or .cab URL: $url" }
            $path = Join-Path $dir $name
            Write-Host "Downloading $name"
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
            $path
        }

        foreach ($file in $files) {
            $name = Split-Path $file -Leaf
            $kb   = if ($name -match '(kb\d+)') { $Matches[1].ToUpper() }
            if ($kb -and (Get-HotFix -Id $kb -ErrorAction SilentlyContinue)) {
                Write-Host "$kb is already installed, skipping"
                continue
            }

            Write-Host "Installing $name"
            & dism.exe /Online /Add-Package "/PackagePath:$file" /NoRestart /Quiet
            switch ($LASTEXITCODE) {
                0           { Write-Host '  Installed' }
                3010        { Write-Host '  Installed, restart required'; $restart = $true }
                -2146498530 { Write-Host '  Not applicable to this system (0x800f081e)' }
                default     { Write-Warning ('  Failed: 0x{0:x8} (see C:\Windows\Logs\DISM\dism.log)' -f $LASTEXITCODE); $failed++ }
            }
        }
    }
    finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($restart) { Write-Host 'A restart is required to finish installing.' }
    if ($failed)  { throw "$failed update(s) failed to install." }
}