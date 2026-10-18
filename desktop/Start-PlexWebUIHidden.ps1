<#
.SYNOPSIS
    Spawns Start-PlexWebUI.ps1 as a hidden background process, then exits.

.DESCRIPTION
    Start-PlexWebUI.ps1 is a console script, so anything that keeps it in the
    foreground owns a console window. Windows Terminal ignores the hidden
    window style that Task Scheduler passes, which is why running the web UI
    directly from a scheduled task left a terminal on screen at logon.

    Redirecting both of the child's streams to files takes the CreateProcess
    path instead, and the long-lived process never gets a drawn console. This
    is the same call the webon/weboff profile shortcuts use.

    Writes the child's PID to the same file the profile shortcuts read, so
    weboff still stops a server that was started at logon.

.PARAMETER Token
    Your X-Plex-Token. Defaults to the PLEX_TOKEN environment variable.

.PARAMETER Player
    Player/device name filter passed through to Start-PlexWebUI.ps1.

.PARAMETER Port
    Local port for the web UI. Defaults to 8765.

.PARAMETER Public
    Bind to all interfaces so other devices on the LAN can reach the UI.

.EXAMPLE
    .\Start-PlexWebUIHidden.ps1 -Token $env:PLEX_TOKEN -Public
#>

[CmdletBinding()]
param(
    [string]$Token = $env:PLEX_TOKEN,

    [string]$Player = "Office",

    [int]$Port = 8765,

    [switch]$Public,

    [string]$PidFile = "$env:TEMP\PlexWebUI.pid",

    [string]$LogPath = "$env:TEMP\PlexWebUI.log",

    [string]$ErrorLogPath = "$env:TEMP\PlexWebUI.err.log"
)

$ErrorActionPreference = "Stop"

if (-not $Token) {
    throw "No Plex token supplied. Pass -Token, or set the PLEX_TOKEN user environment variable."
}

$scriptPath = Join-Path (Split-Path $PSScriptRoot) "Start-PlexWebUI.ps1"
if (-not (Test-Path $scriptPath)) {
    throw "Start-PlexWebUI.ps1 not found next to this script ($scriptPath)."
}

if (Test-Path $PidFile) {
    $existingPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Host "Plex web UI already running (PID $existingPid)." -ForegroundColor Yellow
        return
    }
}

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$exe = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell.exe).Source }

$argList = @(
    '-NoProfile', '-NoLogo', '-File', $scriptPath,
    '-Token', $Token, '-Player', $Player, '-Port', $Port
)
if ($Public) { $argList += '-Public' }

$proc = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $LogPath -RedirectStandardError $ErrorLogPath

Set-Content -Path $PidFile -Value $proc.Id
Write-Host "Plex web UI started (PID $($proc.Id), hidden). Logs: $LogPath" -ForegroundColor Green
