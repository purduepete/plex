<#
.SYNOPSIS
    Shared Plex "now playing" / rating / skip functions used by both
    Set-PlexTrack.ps1 (CLI) and Start-PlexWebUI.ps1 (local web UI).

.DESCRIPTION
    Dot-source this file from other scripts:
        . "$PSScriptRoot\PlexTrackLib.ps1"

    Covers both music tracks and video (movies/episodes) sessions.
#>

function New-PlexSessionItem {
    param(
        $Node,
        [string]$MediaType
    )

    $album = if ($Node.parentTitle) { $Node.parentTitle } elseif ($Node.year) { [string]$Node.year } else { $null }

    return [pscustomobject]@{
        RatingKey         = $Node.ratingKey
        Title             = $Node.title
        Artist            = $Node.grandparentTitle
        Album             = $album
        Kind              = $Node.type
        MediaType         = $MediaType
        CurrentStars      = if ($Node.userRating) { [double]$Node.userRating / 2 } else { $null }
        Player            = $Node.Player.title
        Device            = $Node.Player.device
        MachineIdentifier = $Node.Player.machineIdentifier
        State             = $Node.Player.state
        Thumb             = $Node.thumb
        ViewOffset        = if ($Node.viewOffset) { [long]$Node.viewOffset } else { 0 }
        Duration          = if ($Node.duration) { [long]$Node.duration } else { 0 }
    }
}

function Get-PlexNowPlayingTracks {
    param(
        [string]$Server,
        [string]$Token
    )

    $uri = "http://$Server/status/sessions?X-Plex-Token=$Token"
    [xml]$xml = Invoke-RestMethod -Uri $uri -Method Get

    $items = @()

    foreach ($node in $xml.MediaContainer.Track) {
        $items += New-PlexSessionItem -Node $node -MediaType 'music'
    }
    foreach ($node in $xml.MediaContainer.Video) {
        $items += New-PlexSessionItem -Node $node -MediaType 'video'
    }

    return $items
}

function Get-FilteredTracks {
    param(
        [string]$Server,
        [string]$Token,
        [string]$PlayerFilter
    )

    $tracks = Get-PlexNowPlayingTracks -Server $Server -Token $Token
    if (-not $tracks -or $tracks.Count -eq 0) {
        return @()
    }

    if ($PlayerFilter) {
        $tracks = $tracks | Where-Object {
            ($_.Player -and $_.Player -like "*$PlayerFilter*") -or
            ($_.Device -and $_.Device -like "*$PlayerFilter*")
        }
    }
    return @($tracks)
}

function Set-PlexRating {
    param(
        [string]$Server,
        [string]$Token,
        [int]$RatingKey,
        [double]$Stars
    )

    # Plex uses a 0-10 scale; -1 clears the rating.
    $plexRating = if ($Stars -le 0) { -1 } else { $Stars * 2 }
    $uri = "http://${Server}/:/rate?key=${RatingKey}&identifier=com.plexapp.plugins.library&rating=${plexRating}&X-Plex-Token=${Token}"
    Invoke-RestMethod -Uri $uri -Method Put | Out-Null
}

function Invoke-PlexSkip {
    param(
        [string]$Server,
        [string]$Token,
        [string]$MachineIdentifier,
        [ValidateSet('Next', 'Previous')]
        [string]$Direction,
        [ValidateSet('music', 'video')]
        [string]$MediaType = 'music'
    )

    if (-not $MachineIdentifier) {
        return $false
    }

    $endpoint = if ($Direction -eq 'Next') { 'skipNext' } else { 'skipPrevious' }
    $commandId = [int][double]::Parse((Get-Date -UFormat %s))
    $uri = "http://${Server}/player/playback/${endpoint}?type=${MediaType}&commandID=${commandId}&X-Plex-Token=${Token}"
    $headers = @{
        'X-Plex-Target-Client-Identifier' = $MachineIdentifier
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Get -Headers $headers | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-PlexPlaybackCommand {
    param(
        [string]$Server,
        [string]$Token,
        [string]$MachineIdentifier,
        [ValidateSet('play', 'pause')]
        [string]$Command,
        [ValidateSet('music', 'video')]
        [string]$MediaType = 'music'
    )

    if (-not $MachineIdentifier) {
        return $false
    }

    $commandId = [int][double]::Parse((Get-Date -UFormat %s))
    $uri = "http://${Server}/player/playback/${Command}?type=${MediaType}&commandID=${commandId}&X-Plex-Token=${Token}"
    $headers = @{
        'X-Plex-Target-Client-Identifier' = $MachineIdentifier
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Get -Headers $headers | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-PlexSeek {
    param(
        [string]$Server,
        [string]$Token,
        [string]$MachineIdentifier,
        [long]$OffsetMs,
        [ValidateSet('music', 'video')]
        [string]$MediaType = 'music'
    )

    if (-not $MachineIdentifier) {
        return $false
    }

    $commandId = [int][double]::Parse((Get-Date -UFormat %s))
    $uri = "http://${Server}/player/playback/seekTo?offset=${OffsetMs}&type=${MediaType}&commandID=${commandId}&X-Plex-Token=${Token}"
    $headers = @{
        'X-Plex-Target-Client-Identifier' = $MachineIdentifier
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Get -Headers $headers | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-PlexSetVolume {
    param(
        [string]$Server,
        [string]$Token,
        [string]$MachineIdentifier,
        [ValidateRange(0, 100)]
        [int]$Volume,
        [ValidateSet('music', 'video')]
        [string]$MediaType = 'music'
    )

    if (-not $MachineIdentifier) {
        return $false
    }

    $commandId = [int][double]::Parse((Get-Date -UFormat %s))
    $uri = "http://${Server}/player/playback/setParameters?volume=${Volume}&type=${MediaType}&commandID=${commandId}&X-Plex-Token=${Token}"
    $headers = @{
        'X-Plex-Target-Client-Identifier' = $MachineIdentifier
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Get -Headers $headers | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-PlexClients {
    param(
        [string]$Server,
        [string]$Token
    )

    $uri = "http://$Server/clients?X-Plex-Token=$Token"
    [xml]$xml = Invoke-RestMethod -Uri $uri -Method Get

    $clients = @()
    foreach ($node in $xml.MediaContainer.Server) {
        $clients += [pscustomobject]@{
            Name              = $node.name
            MachineIdentifier = $node.machineIdentifier
        }
    }
    return $clients | Sort-Object Name
}

function Get-MachineIdentifierForRatingKey {
    param(
        [string]$Server,
        [string]$Token,
        [int]$RatingKey
    )

    $uri = "http://$Server/status/sessions?X-Plex-Token=$Token"
    [xml]$xml = Invoke-RestMethod -Uri $uri -Method Get

    foreach ($node in $xml.MediaContainer.Track) {
        if ([int]$node.ratingKey -eq $RatingKey) {
            return $node.Player.machineIdentifier
        }
    }
    foreach ($node in $xml.MediaContainer.Video) {
        if ([int]$node.ratingKey -eq $RatingKey) {
            return $node.Player.machineIdentifier
        }
    }
    return $null
}
