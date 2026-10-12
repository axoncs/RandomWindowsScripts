# Installs .msu/.cab updates from a URL (e.g. the Microsoft Update Catalog) on the local machine.
#
# Usage:     $u='https://.../windows11.0-kb5xxxxxx-x64_....msu';irm a.xon.ac/update|iex
# Multiple:  $u='url1','url2';irm a.xon.ac/update|iex   (installed in the order given)
#
# Must run elevated (Administrator or SYSTEM). Works over PSRemoting, unlike wusa.exe.
# Keep this file ASCII-only: Windows PowerShell 5.1 irm may mis-decode anything else.

& {
    $ErrorActionPreference = 'Stop'

    # Streams a URL to disk, printing a line every 10% (progress bars don't show in most remote shells,
    # and Invoke-WebRequest's bar makes large downloads very slow in PS 5.1)
    function Save-Url($url, $path) {
        $sw  = [Diagnostics.Stopwatch]::StartNew()
        $res = [Net.WebRequest]::Create($url).GetResponse()
        $in  = $res.GetResponseStream()
        $out = [IO.File]::Create($path)
        try {
            $total = $res.ContentLength
            $buf   = New-Object byte[] 1MB
            [long]$done = 0
            $next  = 10
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                if ($total -gt 0) {
                    $pct = [math]::Floor($done * 100 / $total)
                    if ($pct -ge $next) {
                        Write-Host ('  {0,3}%  {1:N0} of {2:N0} MB' -f $pct, ($done / 1MB), ($total / 1MB))
                        $next = $pct - ($pct % 10) + 10
                    }
                }
            }
        }
        finally { $out.Dispose(); $in.Dispose(); $res.Dispose() }
        if ($total -gt 0 -and $done -ne $total) { throw "Download incomplete: got $done of $total bytes" }
        Write-Host ('  Downloaded {0:N0} MB in {1:N0}s' -f ($done / 1MB), $sw.Elapsed.TotalSeconds)
    }

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
            Save-Url $url $path
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
