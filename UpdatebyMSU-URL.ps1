# Installs .msu/.cab updates from a URL (e.g. the Microsoft Update Catalog) on the local machine.
#
# Usage:     $u='https://.../windows11.0-kb5xxxxxx-x64_....msu';irm a.xon.ac/update|iex
# Multiple:  $u='url1','url2';irm a.xon.ac/update|iex   (installed in the order given)
# Or set the MSUurl environment variable instead of $u (several URLs: separate with commas)
#
# Must run elevated (Administrator or SYSTEM). Works over PSRemoting.
# Restarts automatically (60 s countdown) if an update needs it; cancel with: shutdown /a
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

    # wusa.exe returns access denied in remote sessions, so run it as SYSTEM from a one-off scheduled task.
    # Returns wusa's exit code.
    function Install-WithWusa($file) {
        $task     = 'Install-MSU'
        $action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wusa.exe" -Argument "`"$file`" /quiet /norestart"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
        Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName $task
            $sw   = [Diagnostics.Stopwatch]::StartNew()
            $note = 5
            do {
                Start-Sleep -Seconds 10
                $state  = (Get-ScheduledTask -TaskName $task).State
                $result = (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult
                if ($sw.Elapsed.TotalMinutes -ge $note) { Write-Host "  Still installing ($note min)"; $note += 5 }
                if ($sw.Elapsed.TotalHours -ge 3) { throw 'Timed out waiting for wusa.exe' }
            } while ($state -eq 'Running' -or $result -eq 0x41301 -or $result -eq 0x41303)   # 0x41301 running, 0x41303 not run yet
            $result
        }
        finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    }

    # $u from the caller, else the MSUurl environment variable (several URLs separated by commas or spaces)
    $urls = @($u) | Where-Object { $_ }
    if (-not $urls -and $env:MSUurl) { $urls = $env:MSUurl -split '[,;\s]+' | Where-Object { $_ } }
    if (-not $urls) { throw 'Set $u or $env:MSUurl to the update URL first, e.g. $u=''https://...msu'';irm a.xon.ac/update|iex' }

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
            $out  = & dism.exe /Online /Add-Package "/PackagePath:$file" /NoRestart /Quiet
            $code = $LASTEXITCODE
            $logs = 'C:\Windows\Logs\DISM\dism.log'
            if ($code -eq 50 -and $file -like '*.msu') {
                # Older DISM (e.g. Server 2022, Windows 10) can't apply .msu files to the running OS
                Write-Host '  DISM cannot install .msu files on this Windows version, using wusa.exe instead'
                $out  = $null
                $code = Install-WithWusa $file
                $logs = 'Event Viewer > Windows Logs > Setup'
            }

            # DISM gives signed exit codes and the task scheduler unsigned ones; hex makes them match
            switch ('{0:x8}' -f $code) {
                '00000000' { Write-Host '  Installed' }
                '00000bc2' { Write-Host '  Installed, restart required'; $restart = $true }   # 3010
                '00240006' { Write-Host '  Already installed' }
                { $_ -in '800f081e', '80240017' } { Write-Host "  Not applicable to this system (0x$_)" }
                default    { $out | Write-Host; Write-Warning "  Failed: 0x$_ (see $logs)"; $failed++ }
            }
        }
    }
    finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Restart with a countdown so this output reaches you first, and so it can still be cancelled
    if ($restart) {
        Write-Host 'Restarting in 60 seconds to finish installing (run "shutdown /a" to cancel)'
        & shutdown.exe /r /t 60 /d p:2:17 /c 'Restarting to finish installing updates'
    }
    if ($failed) { throw "$failed update(s) failed to install." }
}
