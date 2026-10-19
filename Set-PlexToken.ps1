<#
.SYNOPSIS
    Store a new Plex token for the local profile and the jimbrownhome1 host.

.DESCRIPTION
    Prompts for the token without echoing it. Saves it as a DPAPI-encrypted file for the
    current Windows user, which the pwsh profile loads into $env:PLEX_TOKEN. With -UpdateHost
    it also overwrites secrets\plex.token on the host and restarts the web UI task.

    Run it after rotating the token at plex.tv (Account > Authorized Devices, or change the
    password with "sign out of all devices"). Run it in a terminal outside VS Code chat so the
    prompt never lands in a transcript.

.EXAMPLE
    .\Set-PlexToken.ps1 -UpdateHost
#>
[CmdletBinding()]
param(
    [switch]$UpdateHost,
    [string]$ComputerName = 'jimbrownhome1'
)
$ErrorActionPreference = 'Stop'

$secure = Read-Host 'New Plex token' -AsSecureString
if ($secure.Length -lt 10) { throw 'That does not look like a Plex token.' }

$dir = Join-Path $env:LOCALAPPDATA 'JimlerTech'
New-Item -ItemType Directory $dir -Force | Out-Null
$file = Join-Path $dir 'plex-token.dpapi.xml'
$secure | Export-Clixml $file
Write-Host "Saved for $env:USERNAME on $env:COMPUTERNAME. Open a new pwsh to load it."

if ($UpdateHost) {
    $plain = [Net.NetworkCredential]::new('', $secure).Password
    $target = "\\$ComputerName\c$\ProgramData\SolutionDeploy\apps\plex\secrets\plex.token"
    [IO.File]::WriteAllText($target, $plain)
    $plain = $null
    $cim = New-CimSession $ComputerName -SessionOption (New-CimSessionOption -Protocol Dcom)
    try {
        Stop-ScheduledTask -CimSession $cim -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-plex'
        Start-Sleep 5
        Start-ScheduledTask -CimSession $cim -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-plex'
    } finally { Remove-CimSession $cim }
    Write-Host "Updated $ComputerName and restarted SolutionDeploy-plex."
}
