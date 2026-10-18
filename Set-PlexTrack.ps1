<#
.SYNOPSIS
    Rate, skip forward, or skip backward on the currently playing Plex track.

.DESCRIPTION
    Queries /status/sessions on your Plex Media Server to find the music
    track playing on a given player, then does one of:

      1. Set a rating (0-5, halves allowed) and print it. If -Rating is
         omitted, it just prints the track name and its current rating.
         If the rating you set is below 3 stars, it also skips to the
         next track.
      2. Skip forward (-Next) to the next track.
      3. Skip backward (-Previous) to the previous track.

    Shares its Plex API functions with Start-PlexWebUI.ps1 via PlexTrackLib.ps1
    (must live in the same folder as this script).

.PARAMETER PlexServer
    Host:port of your Plex server. Defaults to 192.168.2.11:32400.

.PARAMETER Token
    Your X-Plex-Token.

.PARAMETER Rating
    Star rating to apply (0-5, in 0.5 increments). If omitted (and -Next /
    -Previous are not used), the script just prints the currently playing
    track and its current rating. If the value given is < 3, the script
    also skips to the next track after rating.

.PARAMETER RatingKey
    Directly target a specific ratingKey instead of pulling from sessions.
    Useful once you already know the track you want to rate.

.PARAMETER Player
    Filter to the session whose Player/device name contains this text
    (case-insensitive, partial match). Defaults to "Office". Pass an
    empty string ("") to disable filtering and see/rate/skip across all
    currently playing tracks.

.PARAMETER Next
    Skip forward to the next track on the matched player. No rating change.

.PARAMETER Previous
    Skip backward to the previous track on the matched player. No rating change.

.EXAMPLE
    # Show the track currently playing on "Office" and its current rating
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN

.EXAMPLE
    # Rate it 5 stars
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -Rating 5

.EXAMPLE
    # Rate it 2 stars -> also auto-skips to the next track (< 3)
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -Rating 2

.EXAMPLE
    # Skip forward without changing the rating
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -Next

.EXAMPLE
    # Skip backward without changing the rating
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -Previous

.EXAMPLE
    # Target a different player, e.g. "Edge"
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -Player "Edge" -Rating 4

.EXAMPLE
    # Rate a specific track by ratingKey, skipping the session lookup
    .\Set-PlexTrack.ps1 -Token $env:PLEX_TOKEN -RatingKey 53441 -Rating 4.5
#>

[CmdletBinding(DefaultParameterSetName = 'Rate')]
param(
    [string]$PlexServer = "jimbrownhome:32400",

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(ParameterSetName = 'Rate')]
    [ValidateRange(0, 5)]
    [double]$Rating,

    [Parameter(ParameterSetName = 'Rate')]
    [int]$RatingKey,

    [string]$Player = "Office",

    [Parameter(ParameterSetName = 'Next')]
    [switch]$Next,

    [Parameter(ParameterSetName = 'Previous')]
    [switch]$Previous
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\PlexTrackLib.ps1"

# --- Main ---

# 1. RatingKey direct mode (bypasses session lookup / player filter)
if ($RatingKey) {
    if (-not $PSBoundParameters.ContainsKey('Rating')) {
        Write-Host "Provide -Rating (0-5) to set a rating for ratingKey $RatingKey." -ForegroundColor Yellow
        exit
    }

    Set-PlexRating -Server $PlexServer -Token $Token -RatingKey $RatingKey -Stars $Rating
    Write-Host "Rated ratingKey $RatingKey -> $Rating stars" -ForegroundColor Green

    if ($Rating -lt 3) {
        $machineId = Get-MachineIdentifierForRatingKey -Server $PlexServer -Token $Token -RatingKey $RatingKey
        if (Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $machineId -Direction 'Next') {
            Write-Host "Rating < 3 - skipped to next track." -ForegroundColor Cyan
        }
        else {
            Write-Host "Rating < 3, but could not skip (no player identifier or player rejected remote control)." -ForegroundColor Yellow
        }
    }
    exit
}

$tracks = Get-FilteredTracks -Server $PlexServer -Token $Token -PlayerFilter $Player

if (-not $tracks -or $tracks.Count -eq 0) {
    if ($Player) {
        Write-Host "No currently playing track matches player '$Player'." -ForegroundColor Yellow
    }
    else {
        Write-Host "No music tracks currently playing." -ForegroundColor Yellow
    }
    exit
}

if ($tracks.Count -gt 1) {
    Write-Host "Multiple tracks match - be more specific with -Player or -RatingKey:" -ForegroundColor Yellow
    $tracks | Format-Table RatingKey, Title, Artist, Album, CurrentStars, Player -AutoSize
    exit
}

$track = $tracks[0]

# 2. Skip forward
if ($Next) {
    if (Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Direction 'Next') {
        Write-Host "Skipped forward." -ForegroundColor Cyan
    }
    else {
        Write-Host "Could not skip forward (player may not accept remote control)." -ForegroundColor Yellow
    }
    exit
}

# 3. Skip backward
if ($Previous) {
    if (Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Direction 'Previous') {
        Write-Host "Skipped backward." -ForegroundColor Cyan
    }
    else {
        Write-Host "Could not skip backward (player may not accept remote control)." -ForegroundColor Yellow
    }
    exit
}

# 1. Set rating (or show it, if no value passed)
if (-not $PSBoundParameters.ContainsKey('Rating')) {
    [pscustomobject]@{
        Title  = $track.Title
        Artist = $track.Artist
        Album  = $track.Album
        Rating = $track.CurrentStars
        Player = $track.Player
    } | Format-Table -AutoSize
    exit
}

Set-PlexRating -Server $PlexServer -Token $Token -RatingKey $track.RatingKey -Stars $Rating
Write-Host "Rated ratingKey $($track.RatingKey) -> $Rating stars" -ForegroundColor Green

if ($Rating -lt 3) {
    if (Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Direction 'Next') {
        Write-Host "Rating < 3 - skipped to next track." -ForegroundColor Cyan
    }
    else {
        Write-Host "Rating < 3, but could not skip (no player identifier or player rejected remote control)." -ForegroundColor Yellow
    }
}
