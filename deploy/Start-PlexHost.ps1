#Requires -Version 7
<#
.SYNOPSIS
    Runs the Plex web UI on jimbrownhome1 as LOCAL SERVICE.

.DESCRIPTION
    Started by the \JimlerTech\plex scheduled task. Reads the Plex token from
    <AppRoot>\secrets\plex.token so it never appears on a command line, keeps
    the volume state file under <AppRoot>\data, and appends output to
    <AppRoot>\logs\plex.log. The port is reached through Cloudflare and
    Tailscale only (public port 8793, internal port 18793); the Windows
    firewall blocks the internal port on the LAN.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = 'C:\ProgramData\SolutionDeploy\apps\plex',
    # Tailscale serve owns the tailnet address on 8793, and HttpListener's + prefix binds every address,
    # so the listener uses an internal port that Tailscale serve and cloudflared forward to.
    [int]$Port = 18793,
    [string]$Player = 'Office',
    [string]$PlexServer = 'jimbrownhome:32400'
)
$ErrorActionPreference = 'Stop'

$tokenFile = Join-Path $AppRoot 'secrets\plex.token'
$dataDir = Join-Path $AppRoot 'data'
$log = Join-Path $AppRoot 'logs\plex.log'

$token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
if (-not $token) { throw "Empty token file: $tokenFile" }

# Start-PlexWebUI.ps1 keeps its volume state in $env:TEMP.
$env:TEMP = $dataDir
$env:TMP = $dataDir

if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 5MB) {
    Move-Item -LiteralPath $log -Destination "$log.1" -Force
}
"$([DateTimeOffset]::Now.ToString('o')) starting pid $PID on port $Port" | Add-Content -LiteralPath $log

& (Join-Path $PSScriptRoot '..\Start-PlexWebUI.ps1') -Token $token -Player $Player -Port $Port -PlexServer $PlexServer -Public *>> $log
exit $LASTEXITCODE
