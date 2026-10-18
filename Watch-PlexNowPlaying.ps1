<#
.SYNOPSIS
    Watches Plex for song changes on a given player and fires a native Windows
    toast notification whenever the track changes.

.DESCRIPTION
    Runs completely independently of Start-PlexWebUI.ps1 - no browser, no
    HTTPS, no web server required. Polls /status/sessions directly, the same
    way Set-PlexTrack.ps1 does, and only reacts to music tracks (video/movie
    sessions on the same player are ignored so they can't spam notifications
    or reset the "last seen" baseline).

    Talks to the Windows toast API directly (Windows.UI.Notifications), not
    via the BurntToast module. Two things drove this:
      1. BurntToast 1.1.0 has no -AppId parameter, so every toast was shown
         under the generic "Windows PowerShell" identity/icon - no way to
         rebrand it.
      2. Calling the raw WinRT API directly requires the
         [Type, Assembly, ContentType = WindowsRuntime] type-loading syntax,
         which has a known gap under PowerShell 7 (pwsh.exe) but works fine
         under Windows PowerShell 5.1 - which is what this script already
         needs to run under anyway, since that's the only launch context
         where BurntToast toasts reliably showed up from a background process
         in testing.

    A custom AppUserModelID ("Plex Now Playing", with this script's own icon)
    is registered once under HKCU:\Software\Classes\AppUserModelId on every
    run (cheap, idempotent, no admin rights needed) so the toast header no
    longer shows "Windows PowerShell".

    Must run under Windows PowerShell 5.1 (powershell.exe), NOT pwsh.exe -
    see point 2 above. Must live in the same folder as PlexTrackLib.ps1.

.PARAMETER PlexServer
    Host:port of your Plex server. Defaults to 192.168.2.11:32400.

.PARAMETER Token
    Your X-Plex-Token.

.PARAMETER Player
    Filter to the session whose Player/device name contains this text
    (case-insensitive, partial match). Defaults to "Office".

.PARAMETER PollSeconds
    How often to check for a track change. Defaults to 10 seconds.

.EXAMPLE
    .\Watch-PlexNowPlaying.ps1 -Token $env:PLEX_TOKEN

.EXAMPLE
    .\Watch-PlexNowPlaying.ps1 -Token $env:PLEX_TOKEN -Player "Living Room" -PollSeconds 5
#>

param(
    [string]$PlexServer = "jimbrownhome:32400",

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$Player = "Office",

    [int]$PollSeconds = 10,

    # Log lines are appended straight to this file (in addition to Write-Host)
    # rather than relying solely on stdout redirection from Start-Process,
    # since Write-Host output through a redirected background process can sit
    # in a buffer for a while before actually reaching disk.
    [string]$LogPath = "$env:TEMP\PlexNotifyWatcher.activity.log",

    [string]$AppId = 'PlexNowPlayingWatcher'
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\PlexTrackLib.ps1"

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
}
catch {
    Write-Host "Could not load the Windows toast notification API: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "This script needs to run under Windows PowerShell 5.1 (powershell.exe), not pwsh.exe." -ForegroundColor Yellow
    exit 1
}

$tempDir = Join-Path $env:TEMP "PlexNowPlayingToast"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
}

# A small branded icon (gold music note on a dark panel, matching the web
# UI's color scheme) - used as the registered AppId's icon, and as the toast
# AppLogo fallback when a track has no downloadable album art.
$appIconBase64 = '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'
$appIconPath = Join-Path $tempDir "app_icon.png"
[IO.File]::WriteAllBytes($appIconPath, [Convert]::FromBase64String($appIconBase64))

function Register-ToastAppId {
    param(
        [string]$AppId,
        [string]$DisplayName,
        [string]$IconPath
    )

    $keyPath = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $keyPath -Name 'DisplayName' -Value $DisplayName
    Set-ItemProperty -Path $keyPath -Name 'IconUri' -Value $IconPath
    # AARRGGBB - opaque, matching the icon's own dark panel background.
    Set-ItemProperty -Path $keyPath -Name 'IconBackgroundColor' -Value 'FF1B1E26'
}

Register-ToastAppId -AppId $AppId -DisplayName 'Plex Now Playing' -IconPath $appIconPath

function Format-StarRating {
    param(
        # 0-5 scale (Plex's internal 0-10 userRating / 2). $null means the
        # track is unrated - callers should omit the rating line entirely
        # in that case.
        $CurrentStars
    )

    if ($null -eq $CurrentStars) { return $null }

    $clamped = [Math]::Max(0, [Math]::Min(5, [double]$CurrentStars))
    # Half-star values (e.g. 3.5) must round to a whole star for display -
    # no half-star symbols are ever shown. [Math]::Round() defaults to
    # banker's rounding (round-half-to-even), which would round 2.5 down to
    # 2 instead of up to 3, so AwayFromZero is used explicitly.
    $filled = [int][Math]::Round($clamped, [MidpointRounding]::AwayFromZero)

    # Show only the N filled stars for an N-star rating - no trailing empty
    # placeholders. A 0-star rating renders as an empty string here, which
    # the caller treats the same as unrated (omits the rating entirely).
    # Uses the plain BLACK STAR glyph (not the color star emoji) so every
    # star in the string is the same font/size/weight - mixing the emoji
    # star with the plain WHITE STAR glyph looked mismatched.
    if ($filled -eq 0) { return $null }
    return [string][char]0x2605 * $filled
}

function Show-Toast {
    param(
        [string]$AppId,
        [string]$Title,
        [string]$Body,
        [string]$ImagePath,
        # Appended to the title line (to the right of the song name) rather
        # than right-aligned in a separate column. A <group>/<subgroup>
        # layout was tried for true right-alignment, but it forced explicit
        # hint-style sizing that didn't match the toast's normal default
        # font, caused clipping on longer titles (a two-column layout halves
        # the available title width), and disrupted line ordering (a plain
        # top-level <text> gets auto-promoted above any <group> as the
        # toast's "header" line). Appending to the plain title <text> keeps
        # the exact default title styling/order with none of that
        # complexity.
        [string]$RatingLine
    )

    # Non-breaking spaces (not regular spaces, which some toast renderers
    # collapse) create a clear visible gap so the stars read as a separate
    # element instead of blending into the title text.
    $gap = [string][char]0x00A0 * 4
    $titleText = if ($RatingLine) { "$Title$gap$RatingLine" } else { $Title }
    $escapedTitle = [System.Security.SecurityElement]::Escape($titleText)
    $escapedBody = [System.Security.SecurityElement]::Escape($Body)
    $imageXml = if ($ImagePath) { "<image placement=`"appLogoOverride`" src=`"$ImagePath`"/>" } else { '' }

    [xml]$toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$escapedTitle</text>
      <text>$escapedBody</text>
      $imageXml
    </binding>
  </visual>
</toast>
"@

    $xmlDoc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xmlDoc.LoadXml($toastXml.OuterXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

function Get-ThumbLocalPath {
    param(
        [string]$Server,
        [string]$Token,
        [string]$ThumbPath,
        [string]$RatingKey
    )

    if (-not $ThumbPath) { return $null }

    try {
        $uri = "http://${Server}${ThumbPath}?X-Plex-Token=${Token}"
        # Name the file per-track (not a single reused filename) so Windows'
        # toast image cache can't show a stale thumbnail from the last song.
        $localPath = Join-Path $tempDir "art_${RatingKey}.jpg"
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($uri, $localPath)
        $webClient.Dispose()
        return $localPath
    }
    catch {
        return $null
    }
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = "$(Get-Date -Format 'HH:mm:ss') $Message"
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LogPath -Value $line -ErrorAction Stop } catch { }
}

Write-Log "Watching for song changes on player '$Player' every $PollSeconds seconds. Press Ctrl+C to stop." -Color Cyan
Write-Log "Using AppId: $AppId"

try {
    Show-Toast -AppId $AppId -Title 'Plex notify watcher started' -Body "Watching '$Player' for song changes." -ImagePath $appIconPath
    Write-Log "Startup test toast sent." -Color Cyan
}
catch {
    Write-Log "Startup test toast FAILED: $($_.Exception.Message)" -Color Red
}

$lastRatingKey = $null
$hadTrackLastPoll = $false
$isFirstPoll = $true

while ($true) {
    try {
        $tracks = Get-FilteredTracks -Server $PlexServer -Token $Token -PlayerFilter $Player
        $tracks = @($tracks | Where-Object { $_.MediaType -eq 'music' })

        if ($tracks.Count -eq 1) {
            $track = $tracks[0]

            if (-not $lastRatingKey) {
                Write-Log "Baseline set (no notification): '$($track.Title)' by $($track.Artist)"
            }
            elseif ($track.RatingKey -ne $lastRatingKey) {
                Write-Log "Track changed -> '$($track.Title)' by $($track.Artist) - sending toast" -Color Green

                $subParts = @()
                if ($track.Artist) { $subParts += $track.Artist }
                if ($track.Album) { $subParts += $track.Album }
                $subtitle = $subParts -join ' - '

                $artPath = Get-ThumbLocalPath -Server $PlexServer -Token $Token -ThumbPath $track.Thumb -RatingKey $track.RatingKey
                $iconForToast = if ($artPath) { $artPath } else { $appIconPath }
                $ratingLine = Format-StarRating -CurrentStars $track.CurrentStars

                try {
                    Show-Toast -AppId $AppId -Title $track.Title -Body $subtitle -ImagePath $iconForToast -RatingLine $ratingLine
                    Write-Log "Toast sent for '$($track.Title)'." -Color Green
                }
                catch {
                    Write-Log "Toast FAILED for '$($track.Title)': $($_.Exception.Message)" -Color Red
                }
            }

            $lastRatingKey = $track.RatingKey
            $hadTrackLastPoll = $true
        }
        else {
            if ($hadTrackLastPoll -or $isFirstPoll) {
                Write-Log "Nothing matching (player '$Player', music only, $($tracks.Count) session(s) found) - baseline cleared."
            }
            # Nothing playing, ambiguous match, or a non-music session - reset
            # the baseline so the next music track always triggers a fresh
            # notification instead of silently being treated as "unchanged".
            $lastRatingKey = $null
            $hadTrackLastPoll = $false
        }
    }
    catch {
        Write-Log "Poll error: $($_.Exception.Message)" -Color Yellow
    }

    $isFirstPoll = $false
    Start-Sleep -Seconds $PollSeconds
}
