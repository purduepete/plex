<#
.SYNOPSIS
    Registers a per-user scheduled task that starts Start-PlexWebUI.ps1 at login.

.DESCRIPTION
    Creates a "Plex Web UI" task in Task Scheduler under the current user with
    an At-Log-On trigger and no execution time limit, then starts it so you can
    see it work straight away.

    The task's action is Start-PlexWebUIHidden.ps1, not the web UI itself. That
    launcher spawns the server with both streams redirected and exits, which is
    what keeps a terminal window off the screen - running the console script
    directly from the task leaves a window up on any machine whose default
    terminal application is Windows Terminal.

    The web UI listens on loopback only unless you pass -Public, so no urlacl
    or firewall rule is required by default.

    Run this once on the machine you want it on. Use -Unregister to remove it.

.PARAMETER Token
    Your X-Plex-Token. Defaults to the PLEX_TOKEN environment variable. The
    value is baked into the task's argument list, which is readable by anyone
    who can open Task Scheduler as you.

.PARAMETER Player
    Player/device name filter passed through to Start-PlexWebUI.ps1.

.PARAMETER Port
    Local port for the web UI. Defaults to 8765.

.PARAMETER TaskName
    Name of the scheduled task. Defaults to "Plex Web UI".

.PARAMETER Public
    Bind to all interfaces so other devices on the LAN can reach the UI,
    instead of loopback only. Needs a one-time elevated setup (urlacl plus a
    firewall rule); this script checks for both and prints the commands if
    either is missing.

.PARAMETER NoStart
    Register the task without starting it.

.PARAMETER Unregister
    Remove the task instead of creating it.

.EXAMPLE
    .\Install-PlexWebUIStartup.ps1 -Token $env:PLEX_TOKEN -Public

.EXAMPLE
    .\Install-PlexWebUIStartup.ps1 -Unregister
#>

[CmdletBinding()]
param(
    [string]$Token = $env:PLEX_TOKEN,

    [string]$Player = "Office",

    [int]$Port = 8765,

    [string]$TaskName = "Plex Web UI",

    [switch]$Public,

    [switch]$NoStart,

    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    }
    else {
        Write-Host "No scheduled task named '$TaskName' found." -ForegroundColor Yellow
    }
    return
}

if (-not $Token) {
    throw "No Plex token supplied. Pass -Token, or set the PLEX_TOKEN user environment variable."
}

$launcherPath = Join-Path $PSScriptRoot "Start-PlexWebUIHidden.ps1"
if (-not (Test-Path $launcherPath)) {
    throw "Start-PlexWebUIHidden.ps1 not found next to this script ($launcherPath)."
}

# pwsh if it's installed, otherwise Windows PowerShell. The web UI is plain
# HttpListener, so unlike Watch-PlexNowPlaying.ps1 it has no 5.1-only WinRT
# dependency and runs fine under either.
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$exe = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell.exe).Source }

$logPath = "$env:TEMP\PlexWebUI.log"

$argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -Token `"$Token`" -Player `"$Player`" -Port $Port"
if ($Public) { $argLine += " -Public" }

$action = New-ScheduledTaskAction -Execute $exe -Argument $argLine -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Limited, not Highest: the urlacl covers -Public, so nothing here needs admin,
# and registering a Highest task from a normal prompt fails with access denied.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Starts the local Plex track control web UI at logon." | Out-Null

if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    throw "Registration of '$TaskName' failed - see the error above."
}

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  Runs:  $exe" -ForegroundColor DarkGray
Write-Host "  UI:    http://localhost:$Port/" -ForegroundColor DarkGray
Write-Host "  Log:   $logPath" -ForegroundColor DarkGray

if ($Public) {
    # The interface carrying the default route, so WSL/Hyper-V vEthernet
    # addresses don't get reported as the LAN address.
    $defaultIf = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
    $lanIp = $null
    if ($defaultIf) {
        $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultIf -ErrorAction SilentlyContinue |
            Select-Object -First 1).IPAddress
    }
    if ($lanIp) {
        Write-Host "  LAN:   http://${lanIp}:$Port/" -ForegroundColor DarkGray
    }

    $url = "http://+:$Port/"
    $haveAcl = (netsh http show urlacl url=$url) -match [regex]::Escape($url)
    $haveRule = Get-NetFirewallRule -DisplayName "Plex Web UI" -ErrorAction SilentlyContinue

    if (-not $haveAcl -or -not $haveRule) {
        Write-Host ""
        Write-Host "-Public still needs a one-time setup. Run these in an ELEVATED PowerShell:" -ForegroundColor Yellow
        if (-not $haveAcl) {
            Write-Host "  netsh http add urlacl url=$url user=Everyone" -ForegroundColor Yellow
        }
        if (-not $haveRule) {
            Write-Host "  New-NetFirewallRule -DisplayName 'Plex Web UI' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor Yellow
        }
        Write-Host "Without them HttpListener throws 'Access is denied' and the task dies on start." -ForegroundColor Yellow
    }
}

if ($NoStart) {
    Write-Host "Start it with: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
    return
}

$pidFile = "$env:TEMP\PlexWebUI.pid"
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

# The action spawns the server and exits, so the task's own state says nothing
# about whether the web UI came up. Wait for the PID the launcher writes.
$serverPid = $null
foreach ($attempt in 1..20) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $pidFile) {
        $candidate = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($candidate -and (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) {
            $serverPid = $candidate
            break
        }
    }
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName
if ($serverPid) {
    Write-Host "Started. Web UI is running as PID $serverPid (LastTaskResult $($info.LastTaskResult))." -ForegroundColor Green
}
else {
    Write-Host "Task ran (LastTaskResult $($info.LastTaskResult)) but no web UI process appeared." -ForegroundColor Red
    Write-Host "Check $env:TEMP\PlexWebUI.err.log and $logPath." -ForegroundColor Yellow
}
