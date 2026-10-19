# Add this block to your $PROFILE (same pattern as the existing webon/weboff
# shortcuts). Adjust $scriptPath and -Token if yours differ.

function Start-PlexNotifyWatcher {
    param(
        [string]$Client = 'IPhone',
        [string]$PlexServer = '192.168.2.11:32400'
    )

    $pidFile = "$env:TEMP\PlexNotifyWatcher.pid"
    if (Test-Path $pidFile) {
        $existingPid = Get-Content $pidFile
        if (Get-Process -Id $existingPid -ErrorAction SilentlyContinue) {
            Write-Host "Plex notify watcher is already running (PID $existingPid)." -ForegroundColor Yellow
            return
        }
    }

    $scriptPath = "C:\Files\Dev\main\plex\Watch-PlexNowPlaying.ps1"
    $logOut = "$env:TEMP\PlexNotifyWatcher.out.log"
    $logErr = "$env:TEMP\PlexNotifyWatcher.err.log"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Plex watcher script not found: $scriptPath"
    }
    if ([string]::IsNullOrWhiteSpace($env:PLEX_TOKEN)) {
        throw "Plex token is missing. Run C:\Files\Dev\main\plex\Set-PlexToken.ps1, then reload your profile."
    }

    # Uses Windows PowerShell 5.1 (powershell.exe), not pwsh.exe - BurntToast
    # toasts from a background process only showed up reliably under 5.1 in
    # testing, even though BurntToast itself is installed and works fine
    # under pwsh.exe when run interactively.
    $proc = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-File", "`"$scriptPath`"",
        "-Token", "`"$env:PLEX_TOKEN`"",
        "-Player", "`"$Client`"",
        "-PlexServer", "`"$PlexServer`""
    ) -WindowStyle Hidden -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru

    if ($proc.WaitForExit(1500)) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        throw "Plex notify watcher exited during startup (exit code $($proc.ExitCode)). Check $logErr and $logOut."
    }
    $proc.Id | Out-File $pidFile
    Write-Host "Plex notify watcher started for '$Client' (PID $($proc.Id))." -ForegroundColor Green
}

function Stop-PlexNotifyWatcher {
    $pidFile = "$env:TEMP\PlexNotifyWatcher.pid"
    if (-not (Test-Path $pidFile)) {
        Write-Host "Plex notify watcher is not running." -ForegroundColor Yellow
        return
    }
    $existingPid = Get-Content $pidFile
    Stop-Process -Id $existingPid -ErrorAction SilentlyContinue
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Write-Host "Plex notify watcher stopped." -ForegroundColor Green
}

Set-Alias notifyon Start-PlexNotifyWatcher
Set-Alias notifyoff Stop-PlexNotifyWatcher
