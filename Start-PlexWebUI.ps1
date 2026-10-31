<#
.SYNOPSIS
    Local web UI for rating / skipping the currently playing Plex track.

.DESCRIPTION
    Starts a tiny local HTTP server (loopback only, no admin rights needed)
    serving a single page with:
      - Track name / artist / album / player
      - A clickable 1-5 star rating widget (whole stars only)
      - Back / Forward buttons

    Rating below 3 stars auto-skips forward, same as Set-PlexTrack.ps1.
    Shares its Plex API logic with Set-PlexTrack.ps1 via PlexTrackLib.ps1
    (must live in the same folder as this script).

    Open http://localhost:<Port>/ in a browser once it's running.
    Press Ctrl+C in the console to stop the server.

.PARAMETER PlexServer
    Host:port of your Plex server. Defaults to 192.168.2.11:32400.

.PARAMETER Token
    Your X-Plex-Token.

.PARAMETER Player
    Filter to the session whose Player/device name contains this text.
    Defaults to "Office". Pass "" to see/control across all currently
    playing tracks (only works cleanly if exactly one is playing).

.PARAMETER Port
    Local port to listen on. Defaults to 8765.

.PARAMETER OpenBrowser
    Automatically open the page in your default browser on startup.

.PARAMETER Public
    Listen on all network interfaces (so other devices on your LAN can reach
    it), instead of just localhost. Requires a one-time admin setup - see
    the .NOTES section below - otherwise HttpListener will throw an
    "Access is denied" error.

.EXAMPLE
    .\Start-PlexWebUI.ps1 -Token $env:PLEX_TOKEN -OpenBrowser

.EXAMPLE
    # Allow other devices on the LAN to reach this (after the one-time admin setup)
    .\Start-PlexWebUI.ps1 -Token $env:PLEX_TOKEN -Public

.NOTES
    One-time admin setup for -Public (run once, in an elevated PowerShell,
    adjust the port if you use something other than the default 8765):

        netsh http add urlacl url=http://+:8765/ user=Everyone
        New-NetFirewallRule -DisplayName "Plex Web UI" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow

    After that, run this script normally (no admin needed) with -Public,
    and reach it from another device on the LAN at:

        http://<this-PC-LAN-IP>:8765/

    Find this PC's LAN IP with: ipconfig
#>

[CmdletBinding()]
param(
    [string]$PlexServer = "jimbrownhome:32400",

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$Player = "Office",

    [int]$Port = 8765,

    [switch]$OpenBrowser,

    [switch]$Public
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\PlexTrackLib.ps1"

# Plex's /status/sessions reports the rating as a snapshot taken when the
# track started playing - it does NOT live-update after a /:/rate call for
# the remainder of that playback session. So we cache the rating we just
# set, keyed by ratingKey, and prefer that over the (possibly stale) live
# session data until the track changes (different ratingKey = cache miss =
# falls back to live data automatically).
$script:RatingOverrides = @{}

# Plex doesn't reliably report a client's current volume via /status/sessions,
# and there's no "get volume" endpoint at all - confirmed against Plex's own
# forum (an unanswered decade-old thread asking exactly this: forums.plex.tv/
# t/get-client-volume-level-from-http-api/88126). So the actual live volume
# can't be pulled from a device; the best available approximation is to
# remember the last volume *we* commanded, keyed by MachineIdentifier, and
# fall back to a sensible default (50) for clients we've never touched.
#
# That cache used to live only in memory, so restarting the server (weboff/
# webon after every script update, which happens a lot) wiped it and the UI
# would show 50% again even though the device's real volume hadn't changed.
# Persisting it to disk means a restart just reloads the last-known values.
$script:VolumeStateFile = Join-Path $env:TEMP "PlexWebUI.VolumeState.json"
$script:VolumeState = @{}
if (Test-Path $script:VolumeStateFile) {
    try {
        $loaded = Get-Content $script:VolumeStateFile -Raw | ConvertFrom-Json
        if ($loaded) {
            foreach ($prop in $loaded.PSObject.Properties) {
                $script:VolumeState[$prop.Name] = [int]$prop.Value
            }
        }
    }
    catch {
        Write-Host "Could not load saved volume state: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Save-VolumeState {
    try {
        $script:VolumeState | ConvertTo-Json -Compress | Set-Content -Path $script:VolumeStateFile -Encoding UTF8
    }
    catch {
        Write-Host "Could not save volume state: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Some Plex clients never honor player/playback/setParameters?volume= at all -
# most notably Roku and LG (webOS) TVs, where volume is a physical TV/remote
# function and isn't exposed to the Plex Companion protocol. Depending on the
# client, that shows up in different Player attributes - "device" (platform,
# e.g. "Roku", "LG", "webOS"), or the friendly "title"/name (e.g. an LG model
# string like "LG_OLED77C4AUA.CUSQLJR") - so check every string we have rather
# than relying on just one field. Add more patterns here as you find them.
$script:VolumeUnsupportedDevicePatterns = @('Roku', 'LG', 'webOS')

function Test-VolumeSupported {
    param(
        [string]$Device,
        [string]$Player
    )

    foreach ($pattern in $script:VolumeUnsupportedDevicePatterns) {
        if ($Device -and $Device -like "*${pattern}*") { return $false }
        if ($Player -and $Player -like "*${pattern}*") { return $false }
    }
    return $true
}

function Get-StatusObject {
    param(
        [string]$Server,
        [string]$Token,
        [string]$PlayerFilter
    )

    $tracks = Get-FilteredTracks -Server $Server -Token $Token -PlayerFilter $PlayerFilter

    if (-not $tracks -or $tracks.Count -eq 0) {
        $message = if ($PlayerFilter) { "Nothing currently playing on player '$PlayerFilter'." } else { "Nothing currently playing." }
        return @{ found = $false; message = $message }
    }

    if ($tracks.Count -gt 1) {
        return @{ found = $false; message = "Multiple items match player '$PlayerFilter' - narrow the filter." }
    }

    $t = $tracks[0]
    $liveRating = if ($null -ne $t.CurrentStars) { [double]$t.CurrentStars } else { 0 }
    $rating = if ($script:RatingOverrides.ContainsKey([string]$t.RatingKey)) { $script:RatingOverrides[[string]$t.RatingKey] } else { $liveRating }
    $thumbUrl = if ($t.Thumb) { "/api/art?path=" + [uri]::EscapeDataString($t.Thumb) } else { $null }
    $volume = if ($script:VolumeState.ContainsKey([string]$t.MachineIdentifier)) { $script:VolumeState[[string]$t.MachineIdentifier] } else { 50 }
    $volumeSupported = Test-VolumeSupported -Device $t.Device -Player $t.Player

    return @{
        found             = $true
        title             = $t.Title
        artist            = $t.Artist
        album             = $t.Album
        rating            = $rating
        player            = $t.Player
        ratingKey         = $t.RatingKey
        machineIdentifier = $t.MachineIdentifier
        state             = $t.State
        thumbUrl          = $thumbUrl
        volumeSupported   = $volumeSupported
        mediaType         = $t.MediaType
        kind              = $t.Kind
        viewOffsetMs      = $t.ViewOffset
        durationMs        = $t.Duration
        volume            = $volume
    }
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [hashtable]$Object,
        [int]$StatusCode = 200
    )
    $json = $Object | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Confirm-PlexControl {
    param(
        [bool]$Accepted,
        [string]$Action
    )
    if (-not $Accepted) {
        throw "Plex could not send '$Action' to the selected player. Remote streaming and track information can work even when the player cannot receive controls from your home server."
    }
}

# Gold star icon (180x180 PNG) for Add-to-Home-Screen on iOS/iPadOS.
$appleTouchIconBase64 = 'iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAIAAACyr5FlAAAEF0lEQVR4nO3bwXHbMBRFUTqTtRvwTJbqyRWmp5SRCrKAh1EUPQokQeA//HsaMAhcfdCK8/bx47YAz3wbvQDERRyQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScfzj18/fo5cQCHFAIo6/ythgeKyIAxJxfGFg/I84niCUgjggEceyPBsVDI+FOLCBOBgSEnFIREMckLLHwXjYkD2ObcnTIQ5IqeNIPhheSh1HjcwB5Y0j86lXyhtHvbQZEQekpHGkHQa7JI1jr5wxZYwj50kfkDEOVCKOWgnnTbo4Ep7xYeniOCNbWLniyHa6J+WKA7sQxz6pZk+iOFKdaxOJ4sBexLFbngmUJY48J9pQljhwQIo4mo+NJHMoRRw4hjgOyjA85o8jwyleZP44cNjkcVw6NqafSZPHgTPePn7cRq9hy9yfztvn++glbLk2jrmPNoJL87r2Wgn+yXB39fZ2ulYYIW31+dR1eiFlhDTUbTP7/bZCH0303MYBv61wxRzT/9M14HsORsgBQzZtzJdg9LHLqO0a9g0pfVQauFHjvyHlFUQZ/vkZ/28rw7cgpgjbMj6OJcZGhBJkQ8ZfK/e4YoJkUYSYHKtQW9NftMePFccSb4O6Cfjgsa6Ve3mumIBZFOEmxyrslrUV+THjxrHE3rgmgj9g3Gvl3nxXTPAsitCTY2WxlfVcHscjjsVnQ18yehCbOBarbVW8HsHjneOB4yuIVxaF0+RY2W203YILyzgWq+02WuoDy2vlXuQrxjeLwnVyrMIeQNiF1bOPA9exjyPstRJ2YfXs48B1iAMScUDyjiP4vR58eS95x4FLEQck4oBkHIfFjW6xSMU4DlyNOCARByTXOIzucqOlPnCNAx0QByTigGQZh90tbrfgwjKOi9w+3yf4276GiOPLmgWJrIjjeQ30sTj+14S29/fLCBr+OLvg8k6OyuvD7kQbShrHriNP+xZidq2cH/JnjnnsT+8v1+Q4eTbZRkiWOBqea54+UsTR/DiTjBCnd44DV/7VRxhwSQ3NPDk6HMPcI2TOODqf2ax9TBjHkKOasg+bd46a2z3CCbmss8Y8kyPIjgdZRhPfRy+ggWjnUdZj+gc+9+wnR7QyVmEXVs/jnePpp9Bl930X7zo5LDa3MFrqA793Dse9Nn0LMZscjmWs7BZv8M5RPnB2O7vB5Yk8Jkf8fdzF5XEMJgdG8ZgcGII4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUAiDkjEAYk4IBEHJOKARByQiAMScUD6A/2w4mpSMEc+AAAAAElFTkSuQmCC'
$appleTouchIconBytes = [Convert]::FromBase64String($appleTouchIconBase64)

# Browser tab and Site Dock sidebar icon: the same gold star as an SVG.
$faviconSvgBytes = [System.Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="#1b1e26"/><path fill="#f5c518" d="M16 4.5l3.4 7.6 8.2.8-6.2 5.5 1.8 8.1L16 22.3l-7.2 4.2 1.8-8.1-6.2-5.5 8.2-.8z"/></svg>')

$htmlPage = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-title" content="Plex Track">
<meta name="mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#020617">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<title>Plex Track Control</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Roboto+Flex:opsz,wght@8..144,100..1000&amp;display=block">
<script>
(function () {
  var media = matchMedia('(prefers-color-scheme: dark)');
  var preference = 'midnight';
  try {
    var stored = localStorage.getItem('plex-theme');
    if (['system', 'light', 'midnight'].indexOf(stored) !== -1) preference = stored;
  } catch (e) {}
  function apply() {
    var theme = preference === 'system' ? (media.matches ? 'midnight' : 'light') : preference;
    var root = document.documentElement;
    root.dataset.theme = theme;
    root.classList.toggle('light', theme === 'light');
    root.classList.toggle('dark', theme !== 'light');
    root.classList.toggle('theme-midnight', theme === 'midnight');
    root.style.colorScheme = theme === 'light' ? 'light' : 'dark';
    root.style.backgroundColor = theme === 'light' ? '#ffffff' : '#020617';
    document.querySelector('meta[name="theme-color"]').content = theme === 'light' ? '#ffffff' : '#020617';
  }
  apply();
  media.addEventListener('change', function () { if (preference === 'system') apply(); });
  document.addEventListener('DOMContentLoaded', function () {
    var control = document.getElementById('theme');
    var picker = document.getElementById('themePicker');
    var menu = document.getElementById('themeMenu');
    var label = document.getElementById('themeValue');
    var options = Array.prototype.slice.call(menu.querySelectorAll('[data-theme-preference]'));
    function sync() {
      options.forEach(function (option) {
        var selected = option.dataset.themePreference === preference;
        option.setAttribute('aria-checked', String(selected));
        if (selected) label.textContent = option.textContent.trim();
      });
    }
    function close(restore) {
      menu.hidden = true;
      control.setAttribute('aria-expanded', 'false');
      if (restore) control.focus();
    }
    function open(index) {
      menu.hidden = false;
      control.setAttribute('aria-expanded', 'true');
      options[index === undefined ? options.findIndex(function (option) {
        return option.dataset.themePreference === preference;
      }) : index].focus();
    }
    sync();
    control.addEventListener('click', function () {
      if (menu.hidden) open(); else close(false);
    });
    control.addEventListener('keydown', function (event) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        open(event.key === 'ArrowDown' ? 0 : options.length - 1);
      }
    });
    options.forEach(function (option) {
      option.addEventListener('click', function () {
        preference = option.dataset.themePreference;
        try { localStorage.setItem('plex-theme', preference); } catch (e) {}
        apply();
        sync();
        close(true);
      });
    });
    menu.addEventListener('keydown', function (event) {
      var index = options.indexOf(document.activeElement);
      if (event.key === 'Escape') { event.preventDefault(); close(true); }
      else if (event.key === 'Tab') close(false);
      else if ((event.key === 'Enter' || event.key === ' ') && index !== -1) {
        event.preventDefault();
        options[index].click();
      }
      else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].indexOf(event.key) !== -1) {
        event.preventDefault();
        var next = event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 :
          (index + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
        options[next].focus();
      }
    });
    document.addEventListener('pointerdown', function (event) {
      if (!picker.contains(event.target)) close(false);
    });
    document.addEventListener('focusin', function (event) {
      if (!picker.contains(event.target)) close(false);
    });
  });
})();
</script>
<style>
  :root {
    color-scheme:dark;
    --bg:#020617; --panel:#0f172a; --text:#e8e8ea; --muted:#9aa0a6;
    --accent:#f5c518; --danger:#e05252; --btn:#1e293b; --btn-hover:#334155;
    --track:#334155; --star:#64748b;
  }
  :root[data-theme=light] {
    color-scheme:light;
    --bg:#ffffff; --panel:#f1f5f9; --text:#0f172a; --muted:#475569;
    --danger:#b91c1c; --btn:#e2e8f0; --btn-hover:#cbd5e1; --track:#cbd5e1; --star:#64748b;
  }
  * {
    box-sizing:border-box; -webkit-tap-highlight-color:transparent;
    -webkit-user-select:none; user-select:none; -webkit-touch-callout:none;
  }
  html, body {
    height:100%; margin:0; overflow:hidden; overscroll-behavior:none;
  }
  body {
    font-family:'Roboto Flex',ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI','Helvetica Neue',Arial,'Noto Sans',sans-serif;
    font-weight:400; -webkit-font-smoothing:antialiased;
    background:var(--bg); color:var(--text);
    display:flex; align-items:center; justify-content:center;
    height:100vh; height:100dvh;
    position:fixed; inset:0; overflow:auto;
    padding:max(20px,env(safe-area-inset-top)) max(20px,env(safe-area-inset-right)) max(20px,env(safe-area-inset-bottom)) max(20px,env(safe-area-inset-left));
    transition:background-color .3s;
    scrollbar-gutter:stable;
  }
  button,input,select,textarea { font-family:inherit; border-radius:0; }
  .app-tooltip { position:fixed; z-index:10000; box-sizing:border-box; max-width:min(320px,calc(100vw - 16px)); max-height:calc(100dvh - 16px); overflow:auto; padding:6px 9px; border:1px solid var(--track); border-radius:0; background:var(--panel); color:var(--text); font:13px/1.4 'Roboto Flex',ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI','Helvetica Neue',Arial,'Noto Sans',sans-serif; overflow-wrap:anywhere; white-space:pre-line; box-shadow:0 4px 14px #0003; }
  .app-tooltip[hidden] { display:none; }
  [data-tip]:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
  .theme-setting { display:flex; align-items:center; justify-content:space-between; margin:0 0 16px; font-size:13px; color:var(--muted); }
  .theme-picker { position:relative; }
  .theme-trigger { display:flex; align-items:center; justify-content:space-between; gap:8px; height:32px; padding:6px 8px; background:transparent; color:var(--muted); border:0; cursor:pointer; font:inherit; }
  .theme-trigger:hover,.theme-trigger[aria-expanded=true] { background:var(--btn); color:var(--text); }
  .theme-trigger svg { width:14px; height:14px; fill:none; stroke:currentColor; stroke-width:2; }
  .theme-menu { position:absolute; right:0; top:calc(100% + 4px); z-index:30; min-width:100%; max-width:calc(100vw - 40px); max-height:min(240px,40dvh); overflow:auto; padding:4px; background:var(--panel); border:1px solid var(--track); box-shadow:0 8px 24px rgba(0,0,0,.3); scrollbar-width:thin; scrollbar-color:var(--muted) var(--panel); }
  .theme-menu[hidden] { display:none; }
  .theme-menu button { display:flex; align-items:center; justify-content:space-between; gap:14px; width:100%; border:0; padding:9px 10px; background:transparent; color:var(--text); font:inherit; text-align:left; cursor:pointer; }
  .theme-menu button:hover,.theme-menu button:focus-visible { background:var(--btn-hover); }
  .theme-menu button::after { content:''; width:7px; height:12px; border:solid var(--accent); border-width:0 2px 2px 0; transform:rotate(45deg); visibility:hidden; }
  .theme-menu button[aria-checked=true]::after { visibility:visible; }
  :focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
  .card {
    position:relative;
    background:var(--panel); border-radius:0; padding:14px 30px 36px;
    width:100%; max-width:440px; box-shadow:0 20px 60px rgba(0,0,0,.4);
    text-align:center;
  }
  .reload-btn {
    width:32px; height:32px; order:-1;
    border:none; background:transparent; color:var(--muted); cursor:pointer;
    padding:6px; border-radius:0; display:flex; align-items:center;
    justify-content:center; transition:background .15s, color .15s;
    touch-action:manipulation;
  }
  .reload-btn:hover { background:var(--btn); color:var(--text); }
  .reload-btn:active { transform:scale(.92); }
  .reload-btn svg { width:18px; height:18px; fill:currentColor; }
  .reload-btn.spinning svg { animation:reload-spin 1s linear infinite; }
  @keyframes reload-spin {
    from { transform:rotate(0deg); }
    to { transform:rotate(360deg); }
  }
  /* Page loading: the overlay hides the card at once, the ring fades in after 250ms,
     and the card fades in once when the first status arrives. */
  .page-loading { position:fixed; inset:0; z-index:500; display:flex; align-items:center; justify-content:center; background:var(--bg); }
  .page-loading, [role=status] { caret-color:transparent; user-select:none; -webkit-user-select:none; }
  .spinner-wrap { display:inline-flex; animation:fade-in .6s ease-out both; }
  .spinner { display:block; width:40px; height:40px; border:3px solid var(--track); border-top-color:var(--accent); border-radius:50%; animation:reload-spin 1s linear infinite; }
  .card.data-enter { animation:fade-in .6s ease-out both; }
  body[data-first-load="loading"] .card { visibility:hidden; opacity:0; }
  body[data-first-load="ready"] .card { animation:fade-in .6s ease-out both; }
  .sr-only { position:absolute; width:1px; height:1px; padding:0; margin:-1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }
  @keyframes fade-in {
    from { opacity:0; }
    to { opacity:1; }
  }
  .art-wrap {
    width:140px; height:140px; margin:0 auto 18px; border-radius:0;
    overflow:hidden; background:var(--btn); box-shadow:0 10px 24px rgba(0,0,0,.35);
  }
  .art-wrap img {
    width:100%; height:100%; object-fit:cover; display:none;
  }
  .art-wrap img.loaded { display:block; }
  .device-picker { position:relative; display:inline-block; margin-bottom:14px; }
  .device-picker-btn {
    display:inline-flex; align-items:center; gap:6px;
    background:transparent; border:none; color:var(--muted);
    font-size:13px; letter-spacing:.08em; text-transform:uppercase;
    padding:8px 12px; border-radius:0; cursor:pointer;
    font-family:inherit; transition:background .15s, color .15s;
    max-width:280px;
  }
  .device-picker-btn span {
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:220px;
  }
  .device-picker-btn:hover, .device-picker-btn.open { background:var(--btn); color:var(--text); }
  .device-picker-btn .chevron {
    width:13px; height:13px; fill:currentColor; flex:none; transition:transform .18s ease;
  }
  .device-picker-btn.open .chevron { transform:rotate(180deg); }
  .device-menu {
    position:absolute; top:calc(100% + 6px); left:50%; transform:translateX(-50%) translateY(-6px);
    background:var(--panel); border-radius:0; box-shadow:0 16px 36px rgba(0,0,0,.5);
    min-width:200px; max-width:280px; max-height:260px; overflow-y:auto; z-index:20;
    padding:6px; text-align:left; opacity:0; pointer-events:none;
    transition:opacity .15s ease, transform .15s ease;
  }
  .device-menu.open {
    opacity:1; pointer-events:auto; transform:translateX(-50%) translateY(0);
  }
  .device-option {
    padding:11px 14px; border-radius:0; cursor:pointer; font-size:14px;
    color:var(--text); text-transform:none; letter-spacing:normal;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
    transition:background .1s;
  }
  .device-option:hover { background:var(--btn-hover); }
  .device-option.selected { background:var(--accent); color:#1b1e26; font-weight:600; }
  h1 { font-size:24px; margin:0 0 6px; word-break:break-word; }
  .sub { color:var(--muted); font-size:16px; margin-bottom:28px; min-height:20px; }
  .stars {
    display:flex; gap:18px; justify-content:center; align-items:center;
    height:56px; margin:0 auto 28px; font-size:44px; line-height:1; user-select:none;
  }
  .stars .star {
    color:var(--star); cursor:pointer; transition:color .1s ease;
    padding:14px 8px; margin:-14px -8px; /* enlarges tap target without shifting layout */
  }
  .stars .star.filled { color:var(--accent); }
  .controls { display:flex; gap:10px; justify-content:center; flex-wrap:nowrap; }
  button.nav {
    display:inline-flex; align-items:center; justify-content:center; gap:8px;
    background:var(--btn); color:var(--text); border:none; border-radius:0;
    padding:16px 14px; font-size:clamp(13px, 4vw, 17px); cursor:pointer;
    transition:background .15s; min-height:56px; touch-action:manipulation;
    flex:1 1 0; min-width:0; white-space:nowrap; overflow:hidden;
  }
  button.nav:hover { background:var(--btn-hover); }
  button.nav:active { transform:scale(.96); }
  /* Mirrors :active exactly - used when a button is triggered via keyboard
     shortcut (programmatic .click() doesn't engage :active on its own). */
  button.nav.key-active { transform:scale(.96); background:var(--btn-hover); }
  button.nav:disabled {
    opacity:0.35; cursor:not-allowed; pointer-events:none;
  }
  button.nav svg { width:20px; height:20px; flex:none; fill:currentColor; }
  /* Play/Pause used to be a fixed-width icon button (flex:0 0 auto), which made
     it noticeably narrower than Back/Forward and an easy button to fat-finger-miss.
     It now grows to fill an equal share of the row just like its siblings, so all
     three buttons are the same size and just as easy to hit. */
  button.nav-icon svg { width:26px; height:26px; }

  @media (max-width: 420px) {
    .card { padding:14px 16px 28px; }
    .stars { gap:10px; font-size:38px; }
    .controls { gap:8px; }
    button.nav { padding:14px 10px; gap:6px; }
  }
  .msg { min-height:18px; font-size:13px; color:var(--muted); margin-top:18px; }
  .msg.error { color:var(--danger); }

  .progress-wrap { margin-bottom:22px; }
  /* The visible line stays a thin 6px bar, but the actual draggable/tappable
     element is much taller (36px) with a negative margin pulling its layout
     footprint back to ~6px - same invisible-hit-area trick used on the stars,
     just via height instead of padding since box-sizing:border-box would
     otherwise cancel padding-based growth against a fixed height. */
  .progress-track {
    position:relative; height:36px; cursor:pointer; touch-action:none;
    margin:-15px 0;
  }
  .progress-track::before {
    content:''; position:absolute; left:0; right:0; top:50%;
    transform:translateY(-50%); height:6px; border-radius:6px; background:var(--track);
  }
  .progress-fill {
    position:absolute; top:50%; left:0; transform:translateY(-50%);
    height:6px; width:0%;
    background:var(--accent); border-radius:6px;
    transition:width .35s linear;
  }
  .progress-track::after {
    content:''; position:absolute; top:50%; left:var(--fill, 0%);
    width:16px; height:16px; border-radius:50%; background:var(--accent);
    transform:translate(-50%, -50%); box-shadow:0 2px 6px rgba(0,0,0,.4);
    transition:left .35s linear;
  }
  /* While actively dragging the seek thumb, position must track the finger
     exactly with no lag - the eased transition above is only wanted for
     poll-driven corrections and the 500ms auto-advance ticks. */
  .progress-track.dragging .progress-fill,
  .progress-track.dragging::after {
    transition:none;
  }
  .progress-times {
    display:flex; justify-content:flex-end; font-size:12px;
    color:var(--muted); margin-top:8px;
  }

  .volume-row {
    display:flex; align-items:center; gap:12px; margin-top:18px;
    padding:0 4px; padding-right:24px; transition:opacity .2s;
    /* Right padding matches the volume icon's width on the left, so the
       slider's visual center lands under the pause button above it. */
  }
  .volume-row.unsupported { opacity:0.35; }
  .volume-icon { width:20px; height:20px; flex:none; fill:var(--muted); }
  .vol-btn {
    /* 44px matches Apple's minimum recommended touch target - the old 32px
       was too small to hit reliably on iPad/iPhone. */
    flex:none; width:44px; height:44px; border:none; border-radius:0;
    background:var(--btn); color:var(--text);
    cursor:pointer; display:flex; align-items:center; justify-content:center;
    touch-action:manipulation; transition:background .15s;
  }
  /* SVG icons instead of +/- text glyphs: text-glyph vertical centering is at
     the mercy of font baseline metrics (visibly off-center on iPadOS Safari
     for characters like "+"/"-"), whereas an SVG centers exactly via flexbox. */
  .vol-btn svg { width:20px; height:20px; fill:currentColor; flex:none; }
  .vol-btn:hover { background:var(--btn-hover); }
  .vol-btn:active { transform:scale(.92); }
  .vol-btn:disabled { cursor:not-allowed; opacity:.5; }
  /* Same invisible-hit-area trick as the progress track: the visible line
     stays a thin 6px bar, but the draggable input itself is much taller
     (36px), with a negative margin pulling its layout footprint back down. */
  #volumeSlider {
    flex:1; -webkit-appearance:none; -moz-appearance:none; appearance:none;
    height:36px; margin:-15px 0; background:transparent; outline:none; cursor:pointer;
  }
  #volumeSlider::-webkit-slider-runnable-track {
    height:6px; border-radius:6px; background:var(--track);
  }
  #volumeSlider::-moz-range-track {
    height:6px; border-radius:6px; background:var(--track);
  }
  #volumeSlider::-webkit-slider-thumb {
    -webkit-appearance:none; width:18px; height:18px; border-radius:50%;
    background:var(--accent); box-shadow:0 2px 6px rgba(0,0,0,.4); cursor:pointer;
    margin-top:-6px;
  }
  #volumeSlider::-moz-range-thumb {
    width:18px; height:18px; border-radius:50%; border:none;
    background:var(--accent); box-shadow:0 2px 6px rgba(0,0,0,.4); cursor:pointer;
  }
  #volumeSlider:disabled { cursor:not-allowed; }
  #volumeSlider:disabled::-webkit-slider-thumb { background:var(--muted); cursor:not-allowed; }
  #volumeSlider:disabled::-moz-range-thumb { background:var(--muted); cursor:not-allowed; }

  .lock-overlay {
    position:fixed; inset:0; background:var(--bg); z-index:1000;
    display:flex; align-items:center; justify-content:center; padding:20px;
  }
  .lock-overlay.hidden { display:none; }
  .lock-box {
    background:var(--panel); border-radius:0; padding:32px 28px;
    width:260px; max-width:88vw; text-align:center;
    box-shadow:0 20px 60px rgba(0,0,0,.4);
  }
  .lock-title { font-size:16px; margin-bottom:16px; color:var(--text); }
  #pinInput {
    width:100%; font-size:24px; text-align:center; letter-spacing:10px;
    padding:12px; border-radius:0; border:none; background:var(--btn);
    color:var(--text); margin-bottom:14px; font-family:inherit;
  }
  #pinInput:focus { outline:2px solid var(--accent); }
  .lock-error { color:var(--danger); font-size:13px; min-height:18px; margin-top:10px; }
  @media(prefers-reduced-motion:reduce) { *,*::before,*::after { animation:none!important; transition:none!important; } }
  @media(max-height:760px) { body { align-items:flex-start; } }
</style>
</head>
<body data-first-load="loading">
  <div class="lock-overlay" id="lockOverlay">
    <div class="lock-box">
      <div class="lock-title">Enter PIN</div>
      <input type="password" id="pinInput" inputmode="numeric" pattern="[0-9]*" maxlength="8" autocomplete="off">
      <button type="button" class="nav" id="pinSubmit" style="width:100%; justify-content:center;">Unlock</button>
      <div class="lock-error" id="lockError">&nbsp;</div>
    </div>
  </div>

  <div class="page-loading" id="pageLoading"></div>

  <div class="card">
    <div class="theme-setting"><span id="themeLabel" hidden>Theme</span>
      <div class="theme-picker" id="themePicker">
        <button type="button" id="theme" class="theme-trigger" aria-labelledby="themeLabel themeValue" aria-haspopup="menu" aria-expanded="false" aria-controls="themeMenu">
          <span id="themeValue">Midnight</span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>
        </button>
        <div id="themeMenu" class="theme-menu" role="menu" aria-labelledby="themeLabel" hidden>
          <button type="button" role="menuitemradio" aria-checked="false" tabindex="-1" data-theme-preference="system">System</button>
          <button type="button" role="menuitemradio" aria-checked="false" tabindex="-1" data-theme-preference="light">Light</button>
          <button type="button" role="menuitemradio" aria-checked="true" tabindex="-1" data-theme-preference="midnight">Midnight</button>
        </div>
      </div>
    <button type="button" class="reload-btn" id="reloadBtn" aria-label="Refresh" data-tip="Refresh">
      <svg viewBox="0 0 24 24"><path d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
    </button>
    </div>
    <div class="art-wrap">
      <img id="albumArt" src="" alt="">
    </div>
    <div class="device-picker" id="devicePicker">
      <button type="button" class="device-picker-btn" id="deviceBtn">
        <span id="deviceLabel">-</span>
        <svg class="chevron" viewBox="0 0 24 24"><path d="M7 10l5 5 5-5z"/></svg>
      </button>
      <div class="device-menu" id="deviceMenu"></div>
    </div>
    <h1 id="title">&nbsp;</h1>
    <div class="sub" id="artistAlbum">&nbsp;</div>

    <div class="progress-wrap">
      <div class="progress-track" id="progressTrack">
        <div class="progress-fill" id="progressFill"></div>
      </div>
      <div class="progress-times">
        <span id="timeTotal">0:00</span>
      </div>
    </div>

    <div class="stars" id="stars">
      <span class="star" data-index="1">&#9733;</span>
      <span class="star" data-index="2">&#9733;</span>
      <span class="star" data-index="3">&#9733;</span>
      <span class="star" data-index="4">&#9733;</span>
      <span class="star" data-index="5">&#9733;</span>
    </div>

    <div class="controls">
      <button class="nav" id="prevBtn">
        <svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm3.5 6l8.5 6V6z"/></svg>
        Back
      </button>
      <button class="nav nav-icon" id="playPauseBtn" aria-label="Play/Pause">
        <svg id="iconPlay" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>
        <svg id="iconPause" viewBox="0 0 24 24" style="display:none"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>
      </button>
      <button class="nav" id="nextBtn">
        Forward
        <svg viewBox="0 0 24 24"><path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z"/></svg>
      </button>
    </div>

    <div class="volume-row" id="volumeRow">
      <svg class="volume-icon" viewBox="0 0 24 24"><path d="M3 10v4h4l5 5V5L7 10H3zm13.5 2A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>
      <button type="button" class="vol-btn" id="volDownBtn" aria-label="Decrease volume">
        <svg viewBox="0 0 24 24"><path d="M19 13H5v-2h14v2z"/></svg>
      </button>
      <input type="range" id="volumeSlider" min="0" max="100" step="1" value="50" aria-label="Volume" data-tip="Volume">
      <button type="button" class="vol-btn" id="volUpBtn" aria-label="Increase volume">
        <svg viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
      </button>
    </div>

    <div class="msg" id="msg">&nbsp;</div>
  </div>

<script>
(function () {
// Shared delegated tooltips also cover playback status changes.
(function appTooltips() {
  var tip = document.createElement('div');
  tip.id = 'app-tooltip';
  tip.className = 'app-tooltip';
  tip.setAttribute('role', 'tooltip');
  tip.hidden = true;
  document.body.appendChild(tip);
  var target = null, timer;
  function hide() {
    clearTimeout(timer);
    if (target) {
      var ids = (target.getAttribute('aria-describedby') || '').split(/\s+/).filter(function(id) { return id && id !== tip.id; });
      if (ids.length) target.setAttribute('aria-describedby', ids.join(' '));
      else target.removeAttribute('aria-describedby');
    }
    target = null;
    tip.hidden = true;
  }
  function place() {
    var box = target.getBoundingClientRect(), rect = tip.getBoundingClientRect();
    var width = document.documentElement.clientWidth, height = window.innerHeight;
    tip.style.left = Math.max(8, Math.min(box.left + box.width / 2 - rect.width / 2, width - rect.width - 8)) + 'px';
    var top = box.bottom + 6;
    if (top + rect.height > height - 8) top = box.top - rect.height - 6;
    tip.style.top = Math.max(8, Math.min(top, height - rect.height - 8)) + 'px';
  }
  function show(next) {
    clearTimeout(timer);
    if (!next.dataset.tip || !next.isConnected) { hide(); return; }
    if (target !== next) hide();
    target = next;
    tip.textContent = target.dataset.tip;
    var ids = (target.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean);
    if (ids.indexOf(tip.id) === -1) ids.push(tip.id);
    target.setAttribute('aria-describedby', ids.join(' '));
    tip.hidden = false;
    place();
  }
  document.addEventListener('pointerover', function(event) {
    if (event.pointerType === 'touch') return;
    if (tip.contains(event.target)) { clearTimeout(timer); return; }
    var next = event.target.closest && event.target.closest('[data-tip]');
    if (next) show(next);
  });
  document.addEventListener('pointerout', function(event) {
    if (!target || (!target.contains(event.target) && !tip.contains(event.target))) return;
    var next = event.relatedTarget;
    if (next && (target.contains(next) || tip.contains(next))) return;
    clearTimeout(timer);
    timer = setTimeout(hide, 180);
  });
  document.addEventListener('focusin', function(event) {
    var next = event.target.closest && event.target.closest('[data-tip]');
    if (next) show(next); else hide();
  });
  document.addEventListener('focusout', function(event) {
    if (target && target.contains(event.target)) hide();
  });
  document.addEventListener('click', hide, true);
  document.addEventListener('keydown', function(event) { if (event.key === 'Escape') hide(); });
  window.addEventListener('scroll', hide, true);
  window.addEventListener('resize', hide);
  window.addEventListener('pagehide', hide);
  new MutationObserver(function() {
    if (!target) return;
    if (!target.isConnected || !target.dataset.tip) hide();
    else if (tip.textContent !== target.dataset.tip) show(target);
  }).observe(document.body, {subtree:true, childList:true, attributes:true, attributeFilter:['data-tip']});
})();
// End shared tooltips.
  var starEls = Array.prototype.slice.call(document.querySelectorAll('#stars .star'));
  var starsContainer = document.getElementById('stars');
  var msgEl = document.getElementById('msg');
  var titleEl = document.getElementById('title');
  var artistAlbumEl = document.getElementById('artistAlbum');
  var devicePickerEl = document.getElementById('devicePicker');
  var deviceBtnEl = document.getElementById('deviceBtn');
  var deviceLabelEl = document.getElementById('deviceLabel');
  var deviceMenuEl = document.getElementById('deviceMenu');
  var iconPlay = document.getElementById('iconPlay');
  var iconPause = document.getElementById('iconPause');
  var albumArtEl = document.getElementById('albumArt');
  var progressTrackEl = document.getElementById('progressTrack');
  var progressFillEl = document.getElementById('progressFill');
  var timeTotalEl = document.getElementById('timeTotal');
  var volumeSliderEl = document.getElementById('volumeSlider');
  var volumeRowEl = document.getElementById('volumeRow');
  var volDownBtnEl = document.getElementById('volDownBtn');
  var volUpBtnEl = document.getElementById('volUpBtn');
  var prevBtnEl = document.getElementById('prevBtn');
  var nextBtnEl = document.getElementById('nextBtn');
  var playPauseBtnEl = document.getElementById('playPauseBtn');
  var lockOverlayEl = document.getElementById('lockOverlay');
  var pinInputEl = document.getElementById('pinInput');
  var pinSubmitEl = document.getElementById('pinSubmit');
  var lockErrorEl = document.getElementById('lockError');
  var selectedPlayer = '';
  var currentRating = 0;
  var currentState = 'playing';
  var currentArtUrl = '';
  var durationMs = 0;
  var viewOffsetMs = 0;
  var lastPollAt = Date.now();
  var lastProgressRatingKey = null;
  var pendingProgressOffset = null; // an unconfirmed big jump, awaiting agreement from the next poll
  var isDraggingProgress = false;
  var isDraggingVolume = false;

  // --- PIN gate (a friction gate for casual use, not real security -
  // anyone hitting the API routes directly still bypasses it) ---
  var PIN = '2112';
  if (localStorage.getItem('plexUiUnlocked') === 'true') {
    lockOverlayEl.classList.add('hidden');
  }
  function tryUnlock() {
    if (pinInputEl.value === PIN) {
      localStorage.setItem('plexUiUnlocked', 'true');
      lockOverlayEl.classList.add('hidden');
    } else {
      lockErrorEl.textContent = 'Incorrect PIN';
      pinInputEl.value = '';
      pinInputEl.focus();
    }
  }
  pinSubmitEl.addEventListener('click', tryUnlock);
  pinInputEl.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { tryUnlock(); }
  });

  starEls.forEach(function (el) {
    var idx = parseInt(el.getAttribute('data-index'), 10);
    el.addEventListener('mouseenter', function () { paintStars(idx); });
    el.addEventListener('click', function () { rate(idx); });
  });
  starsContainer.addEventListener('mouseleave', function () { paintStars(currentRating); });

  function paintStars(value) {
    var rounded = Math.round(value);
    starEls.forEach(function (el) {
      var idx = parseInt(el.getAttribute('data-index'), 10);
      el.classList.toggle('filled', idx <= rounded);
    });
  }

  var msgTimer = null;

  function setMessage(text, isError) {
    msgEl.textContent = text || ' ';
    msgEl.className = isError ? 'msg error' : 'msg';

    if (msgTimer) {
      clearTimeout(msgTimer);
      msgTimer = null;
    }
    if (text) {
      msgTimer = setTimeout(function () {
        msgEl.textContent = ' ';
        msgEl.className = 'msg';
      }, 2000);
    }
  }

  function paintPlayState(state) {
    currentState = state;
    var isPlaying = state === 'playing';
    iconPlay.style.display = isPlaying ? 'none' : '';
    iconPause.style.display = isPlaying ? '' : 'none';
  }

  function setArt(url) {
    if (url === currentArtUrl) { return; }
    currentArtUrl = url;
    if (!url) {
      albumArtEl.classList.remove('loaded');
      albumArtEl.removeAttribute('src');
      return;
    }
    albumArtEl.classList.remove('loaded');
    albumArtEl.onload = function () { albumArtEl.classList.add('loaded'); };
    albumArtEl.onerror = function () { albumArtEl.classList.remove('loaded'); };
    albumArtEl.src = url;
  }

  function formatTime(ms) {
    if (!ms || ms < 0) { ms = 0; }
    var totalSec = Math.floor(ms / 1000);
    var h = Math.floor(totalSec / 3600);
    var m = Math.floor((totalSec % 3600) / 60);
    var s = totalSec % 60;
    var mm = h > 0 ? String(m).padStart(2, '0') : String(m);
    var ss = String(s).padStart(2, '0');
    return h > 0 ? (h + ':' + mm + ':' + ss) : (mm + ':' + ss);
  }

  function setProgressUI(offsetMs) {
    var pct = durationMs > 0 ? Math.max(0, Math.min(100, (offsetMs / durationMs) * 100)) : 0;
    progressFillEl.style.width = pct + '%';
    progressTrackEl.style.setProperty('--fill', pct + '%');
    timeTotalEl.textContent = formatTime(durationMs);
  }

  function seekFraction(e) {
    var rect = progressTrackEl.getBoundingClientRect();
    var x = e.clientX - rect.left;
    return Math.max(0, Math.min(1, rect.width ? x / rect.width : 0));
  }

  // Drag-to-seek deliberately avoids setPointerCapture: WebKit/iOS Safari has
  // long-standing bugs where a captured pointer can fail to release cleanly
  // (e.g. if a gesture gets interrupted by an OS-level swipe), which then
  // silently swallows touches everywhere else on the page - including taps on
  // Back/Play-Pause/Forward. Using document-level listeners that only exist
  // for the duration of an active drag, with an explicit pointercancel
  // handler, sidesteps that class of bug entirely.
  function onProgressPointerMove(e) {
    if (!isDraggingProgress) { return; }
    setProgressUI(seekFraction(e) * durationMs);
  }
  function cleanupProgressDrag() {
    document.removeEventListener('pointermove', onProgressPointerMove);
    document.removeEventListener('pointerup', onProgressPointerUp);
    document.removeEventListener('pointercancel', onProgressPointerCancel);
    progressTrackEl.classList.remove('dragging');
  }
  function onProgressPointerUp(e) {
    if (!isDraggingProgress) { return; }
    isDraggingProgress = false;
    cleanupProgressDrag();
    var targetMs = Math.round(seekFraction(e) * durationMs);
    viewOffsetMs = targetMs;
    lastPollAt = Date.now();
    setProgressUI(targetMs);
    fetch(apiUrl('/api/seek') + '&offset=' + targetMs, { method: 'POST' })
      .then(readApiResponse)
      .then(function (data) {
        // Plex often reports a transient "buffering/paused" state for a moment
        // right after a seek. Seeking doesn't change play/pause intent, so keep
        // whatever the icon already showed and let the next regular poll (which
        // happens after Plex has settled) correct it if it's genuinely different.
        if (data && data.found) { data.state = currentState; }
        render(data);
      })
      .catch(function (e) { setMessage('Seek failed: ' + e, true); });
  }
  function onProgressPointerCancel() {
    if (!isDraggingProgress) { return; }
    isDraggingProgress = false;
    cleanupProgressDrag();
    // Gesture was interrupted (not a clean release) - resync to the server's
    // real position instead of committing a possibly-wrong seek.
    refresh();
  }
  progressTrackEl.addEventListener('pointerdown', function (e) {
    if (!durationMs) { return; }
    isDraggingProgress = true;
    progressTrackEl.classList.add('dragging');
    setProgressUI(seekFraction(e) * durationMs);
    document.addEventListener('pointermove', onProgressPointerMove);
    document.addEventListener('pointerup', onProgressPointerUp);
    document.addEventListener('pointercancel', onProgressPointerCancel);
  });

  var VOLUME_STEP = 2;

  // The /api/volume route does 3 sequential live round trips to Plex
  // (look up the session, send the command, re-fetch status), so a single
  // commit can take a while. Distinct rapid presses (e.g. fast-tapping L)
  // land too far apart to coalesce via the debounce alone, so without this
  // guard several requests end up in flight at once - and since nothing
  // guarantees the device/Plex applies them in the order they were sent,
  // the volume could visibly bounce around. This queue guarantees at most
  // one /api/volume request is ever in flight: new values while one is
  // pending just replace the queued value, and whatever's newest gets sent
  // the moment the in-flight one finishes.
  var volumeCommitSeq = 0;
  var volumeCommitInFlight = false;
  var volumeQueueTimer = null;
  var volumePendingVal = null;

  function sendVolumeCommit(val) {
    volumeCommitInFlight = true;
    var seq = ++volumeCommitSeq;
    fetch(apiUrl('/api/volume') + '&value=' + val, { method: 'POST' })
      .then(readApiResponse)
      .then(function (data) {
        volumeCommitInFlight = false;
        if (seq === volumeCommitSeq) { isDraggingVolume = false; render(data, { skipProgress: true }); }
        flushPendingVolumeCommit();
      })
      .catch(function (e) {
        volumeCommitInFlight = false;
        if (seq === volumeCommitSeq) { isDraggingVolume = false; setMessage('Volume failed: ' + e, true); }
        flushPendingVolumeCommit();
      });
  }

  function flushPendingVolumeCommit() {
    if (volumePendingVal !== null) {
      var next = volumePendingVal;
      volumePendingVal = null;
      sendVolumeCommit(next);
    }
  }

  function commitVolume(val) {
    val = Math.max(0, Math.min(100, val));
    isDraggingVolume = true;
    volumeSliderEl.value = val;
    volumePendingVal = val;
    if (volumeQueueTimer) { clearTimeout(volumeQueueTimer); }
    volumeQueueTimer = setTimeout(function () {
      volumeQueueTimer = null;
      if (!volumeCommitInFlight) { flushPendingVolumeCommit(); }
      // else: leave it queued - sendVolumeCommit's own completion handler
      // will flush it the moment the in-flight request finishes.
    }, 150);
  }

  function stageVolume(delta) {
    commitVolume(parseInt(volumeSliderEl.value, 10) + delta);
  }

  volumeSliderEl.addEventListener('input', function () { isDraggingVolume = true; });
  volumeSliderEl.addEventListener('change', function () {
    commitVolume(parseInt(volumeSliderEl.value, 10));
    volumeSliderEl.blur(); // return keyboard focus to the page, not the slider
  });

  volDownBtnEl.addEventListener('click', function () {
    if (volumeSliderEl.disabled) { return; }
    commitVolume(parseInt(volumeSliderEl.value, 10) - VOLUME_STEP);
  });
  volUpBtnEl.addEventListener('click', function () {
    if (volumeSliderEl.disabled) { return; }
    commitVolume(parseInt(volumeSliderEl.value, 10) + VOLUME_STEP);
  });

  setInterval(function () {
    if (isDraggingProgress || !durationMs || currentState !== 'playing') { return; }
    var displayOffset = Math.min(durationMs, viewOffsetMs + (Date.now() - lastPollAt));
    setProgressUI(displayOffset);
  }, 500);

  function setTransportEnabled(enabled) {
    prevBtnEl.disabled = !enabled;
    nextBtnEl.disabled = !enabled;
    playPauseBtnEl.disabled = !enabled;
  }

  function render(data, opts) {
    var skipProgress = !!(opts && opts.skipProgress);
    if (!data.found) {
      titleEl.textContent = 'Nothing playing';
      artistAlbumEl.textContent = '';
      currentRating = 0;
      paintStars(0);
      setArt('');
      durationMs = 0;
      viewOffsetMs = 0;
      setProgressUI(0);
      volumeSliderEl.disabled = true;
      volDownBtnEl.disabled = true;
      volUpBtnEl.disabled = true;
      volumeRowEl.classList.add('unsupported');
      volumeSliderEl.dataset.tip = '';
      volumeRowEl.dataset.tip = 'Volume unavailable while nothing is playing';
      volumeRowEl.tabIndex = 0;
      if (!isDraggingVolume) { volumeSliderEl.value = 50; }
      setTransportEnabled(false);
      return;
    }
    setTransportEnabled(true);
    titleEl.textContent = data.title;
    var subParts = [];
    if (data.artist) { subParts.push(data.artist); }
    if (data.album) { subParts.push(data.album); }
    artistAlbumEl.textContent = subParts.join(' — ');
    currentRating = data.rating || 0;
    paintStars(currentRating);
    paintPlayState(data.state || 'playing');
    setArt(data.thumbUrl || '');

    durationMs = data.durationMs || 0;
    // Volume commits re-fetch status as a side effect (to build their JSON
    // response) but that fetch happens off the regular 8s poll cadence and,
    // worse, can land while the device is mid-command and briefly reports a
    // transitional (non-'playing') state - which used to bypass the anti-
    // jitter guard below entirely and made adjusting volume visibly kick
    // the progress bar. Volume responses now skip progress sync completely;
    // the next real poll (at most 8s later) reconciles it if needed.
    if (!isDraggingProgress && !skipProgress) {
      var polledOffset = data.viewOffsetMs || 0;
      var trackChanged = data.ratingKey !== lastProgressRatingKey;
      lastProgressRatingKey = data.ratingKey;

      if (trackChanged || currentState !== 'playing') {
        // Unambiguous signal - a new track started, or playback isn't
        // actively running - trust the poll immediately.
        pendingProgressOffset = null;
        viewOffsetMs = polledOffset;
        lastPollAt = Date.now();
        setProgressUI(viewOffsetMs);
      } else {
        var displayedNow = Math.min(durationMs, viewOffsetMs + (Date.now() - lastPollAt));
        var delta = Math.abs(polledOffset - displayedNow);
        if (delta <= 5000) {
          // Ordinary reporting lag/jitter (Plex's timeline checkpoints don't
          // land on the same 8s cadence we poll on) - not worth reacting to
          // in either direction. Keep the local extrapolation running.
          pendingProgressOffset = null;
        } else {
          // A big single-poll deviation is more often a bad/stale reading
          // (e.g. a session's viewOffset briefly missing, which we read as
          // 0 and would otherwise look like a hard jump to the start) than
          // a real external seek. Don't act on it until the *next* poll
          // reports something close to the same position, confirming it's
          // real rather than one-off noise.
          if (pendingProgressOffset !== null && Math.abs(pendingProgressOffset - polledOffset) <= 3000) {
            pendingProgressOffset = null;
            viewOffsetMs = polledOffset;
            lastPollAt = Date.now();
            setProgressUI(viewOffsetMs);
          } else {
            pendingProgressOffset = polledOffset;
          }
        }
      }
    }
    var volSupported = data.volumeSupported !== false;
    volumeSliderEl.disabled = !volSupported;
    volDownBtnEl.disabled = !volSupported;
    volUpBtnEl.disabled = !volSupported;
    volumeRowEl.classList.toggle('unsupported', !volSupported);
    volumeSliderEl.dataset.tip = volSupported ? 'Volume' : '';
    volumeRowEl.dataset.tip = volSupported ? '' : 'Volume control not supported on this device';
    volumeRowEl.tabIndex = volSupported ? -1 : 0;
    if (!volSupported) {
      if (!isDraggingVolume) { volumeSliderEl.value = 50; }
    } else if (!isDraggingVolume && typeof data.volume === 'number') {
      volumeSliderEl.value = data.volume;
    }
  }

  function apiUrl(path) {
    return path + '?player=' + encodeURIComponent(selectedPlayer || '');
  }

  function readApiResponse(response) {
    return response.json().then(function (data) {
      if (!response.ok) {
        throw new Error(data.message || ('Request failed (HTTP ' + response.status + ')'));
      }
      return data;
    });
  }

  function closeDeviceMenu() {
    deviceMenuEl.classList.remove('open');
    deviceBtnEl.classList.remove('open');
  }

  function selectPlayer(name) {
    selectedPlayer = name;
    deviceLabelEl.textContent = name;
    Array.prototype.forEach.call(deviceMenuEl.querySelectorAll('.device-option'), function (el) {
      el.classList.toggle('selected', el.textContent === name);
    });
    closeDeviceMenu();
    refresh();
  }

  deviceBtnEl.addEventListener('click', function (e) {
    e.stopPropagation();
    var isOpen = deviceMenuEl.classList.toggle('open');
    deviceBtnEl.classList.toggle('open', isOpen);
  });

  document.addEventListener('click', function (e) {
    if (!devicePickerEl.contains(e.target)) {
      closeDeviceMenu();
    }
  });

  function loadPlayers() {
    return fetch('/api/players')
      .then(readApiResponse)
      .then(function (data) {
        var players = data.players || [];
        deviceMenuEl.innerHTML = '';
        players.forEach(function (name) {
          var opt = document.createElement('div');
          opt.className = 'device-option';
          opt.textContent = name;
          opt.addEventListener('click', function () { selectPlayer(name); });
          deviceMenuEl.appendChild(opt);
        });
        var preferred = data.default || 'Office';
        // Preserve whatever device the user already has selected across a
        // reload, as long as it's still in the list - don't silently bounce
        // them back to the default device every time the list refreshes.
        var keepCurrent = selectedPlayer && players.indexOf(selectedPlayer) !== -1;
        var initial = keepCurrent ? selectedPlayer : (players.indexOf(preferred) !== -1 ? preferred : (players[0] || '-'));
        selectedPlayer = initial;
        deviceLabelEl.textContent = initial;
        Array.prototype.forEach.call(deviceMenuEl.querySelectorAll('.device-option'), function (el) {
          el.classList.toggle('selected', el.textContent === initial);
        });
      })
      .catch(function (e) { setMessage('Could not load devices: ' + e, true); finishPageLoading(true); });
  }

  function refresh() {
    return fetch(apiUrl('/api/status'))
      .then(readApiResponse)
      .then(render)
      .catch(function (e) { setMessage('Could not reach Plex: ' + e, true); finishPageLoading(true); });
  }

  function rate(value) {
    // Optimistic update: paint immediately, don't wait on the round trip.
    currentRating = value;
    paintStars(value);
    setMessage('Rating…');

    fetch(apiUrl('/api/rate'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rating: value })
    })
      .then(readApiResponse)
      .then(function (data) {
        render(data);
        setMessage(value < 3 ? ('Rated ' + value + ' ★ - skipped forward') : ('Rated ' + value + ' ★'));
      })
      .catch(function (e) { setMessage('Rate failed: ' + e, true); });
  }

  document.getElementById('prevBtn').addEventListener('click', function () {
    fetch(apiUrl('/api/previous'), { method: 'POST' })
      .then(readApiResponse)
      .then(render)
      .catch(function (e) { setMessage('Skip failed: ' + e, true); });
  });

  document.getElementById('nextBtn').addEventListener('click', function () {
    fetch(apiUrl('/api/next'), { method: 'POST' })
      .then(readApiResponse)
      .then(render)
      .catch(function (e) { setMessage('Skip failed: ' + e, true); });
  });

  document.getElementById('playPauseBtn').addEventListener('click', function () {
    // Optimistic flip so the icon changes instantly.
    var wasPlaying = currentState === 'playing';
    paintPlayState(wasPlaying ? 'paused' : 'playing');

    fetch(apiUrl('/api/playpause'), { method: 'POST' })
      .then(readApiResponse)
      .then(render)
      .catch(function (e) { setMessage('Play/pause failed: ' + e, true); });
  });

  // Keyboard shortcuts: space = play/pause, j = back, k = forward, l = volume up, h = volume down.
  // Ignored while typing in a text field (e.g. the PIN box) or while locked.
  // Note: the volume <input type="range"> keeps keyboard focus after you drag
  // or click it, so the "don't hijack typing" guard below only excludes real
  // text-entry inputs - a focused range slider must NOT block shortcuts, or
  // j/k silently stop working the moment you've touched the volume slider.
  // Programmatic .click() calls don't trigger the native :active CSS state,
  // so keyboard-shortcut presses need their own brief "pressed" flash that
  // mirrors button.nav:active (see .key-active in the stylesheet).
  function flashKeyActive(btn) {
    if (!btn || btn.disabled) { return; }
    btn.classList.add('key-active');
    setTimeout(function () { btn.classList.remove('key-active'); }, 150);
  }

  document.addEventListener('keydown', function (e) {
    var target = e.target;
    if (target && target.closest('#themePicker')) { return; }
    var tag = (target && target.tagName) || '';
    var isTextEntry = (tag === 'INPUT' && target.type !== 'range') || tag === 'TEXTAREA' || tag === 'SELECT';
    if (isTextEntry) { return; }
    if (lockOverlayEl && !lockOverlayEl.classList.contains('hidden')) { return; }

    if (e.code === 'Space' || e.key === ' ') {
      e.preventDefault();
      var playPauseBtn = document.getElementById('playPauseBtn');
      flashKeyActive(playPauseBtn);
      playPauseBtn.click();
    } else if (e.key === 'j' || e.key === 'J') {
      e.preventDefault();
      var prevBtn = document.getElementById('prevBtn');
      flashKeyActive(prevBtn);
      prevBtn.click();
    } else if (e.key === 'k' || e.key === 'K') {
      e.preventDefault();
      var nextBtn = document.getElementById('nextBtn');
      flashKeyActive(nextBtn);
      nextBtn.click();
    } else if (e.key === 'l' || e.key === 'L') {
      e.preventDefault();
      if (!volumeSliderEl.disabled) { stageVolume(VOLUME_STEP); }
    } else if (e.key === 'h' || e.key === 'H') {
      e.preventDefault();
      if (!volumeSliderEl.disabled) { stageVolume(-VOLUME_STEP); }
    }
  });

  document.getElementById('reloadBtn').addEventListener('click', function () {
    var btn = this;
    if (btn.classList.contains('spinning')) { return; }
    btn.classList.add('spinning');
    loadPlayers().then(refresh).then(function () { btn.classList.remove('spinning'); });
  });

  var pageLoadingEl = document.getElementById('pageLoading');
  var pageRingTimer = setTimeout(function () {
    pageLoadingEl.innerHTML = '<div class="spinner-wrap" role="status"><span class="spinner" aria-hidden="true"></span><span class="sr-only">Loading now playing</span></div>';
  }, 250);
  function finishPageLoading(failed) {
    if (document.body.dataset.firstLoad !== 'loading') { return; }
    clearTimeout(pageRingTimer);
    pageLoadingEl.remove();
    document.body.dataset.firstLoad = failed ? 'error' : 'ready';
  }

  if (!lockOverlayEl.classList.contains('hidden')) { finishPageLoading(true); }
  loadPlayers().then(refresh).then(finishPageLoading);
  setInterval(refresh, 8000);
})();
</script>
</body>
</html>
'@

$bindHost = if ($Public) { '+' } else { 'localhost' }
$prefix = "http://${bindHost}:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch {
    Write-Host "Could not start listener on $prefix : $($_.Exception.Message)" -ForegroundColor Red
    if ($Public) {
        Write-Host "If this is 'Access is denied', run this once in an elevated PowerShell:" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
        Write-Host "  New-NetFirewallRule -DisplayName ""Plex Web UI"" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor Yellow
    }
    exit 1
}

if ($Public) {
    $lanIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress
    Write-Host "Plex track control running on port $Port (player filter: '$Player')" -ForegroundColor Green
    Write-Host "Reachable on this LAN at:" -ForegroundColor Green
    foreach ($ip in $lanIPs) { Write-Host "  http://${ip}:$Port/" -ForegroundColor Green }
}
else {
    Write-Host "Plex track control running at $prefix (player filter: '$Player')" -ForegroundColor Green
}
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

if ($OpenBrowser) {
    Start-Process "http://localhost:$Port/"
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        try {
            # Any request can override the default player via ?player=..., which
            # is how the browser's device dropdown switches targets live without
            # needing the server restarted.
            $playerFilter = $request.QueryString['player']
            if (-not $playerFilter) { $playerFilter = $Player }

            $controlPaths = @('/api/rate', '/api/next', '/api/previous', '/api/playpause', '/api/seek', '/api/volume')
            if ($request.Url.AbsolutePath -in $controlPaths) {
                $controlTracks = @(Get-FilteredTracks -Server $PlexServer -Token $Token -PlayerFilter $playerFilter)
                if ($controlTracks.Count -ne 1) {
                    throw "Select exactly one playing device before sending a control."
                }
            }

            switch ($request.Url.AbsolutePath) {
                '/' {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($htmlPage)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }

                '/apple-touch-icon.png' {
                    $response.ContentType = "image/png"
                    $response.ContentLength64 = $appleTouchIconBytes.Length
                    $response.OutputStream.Write($appleTouchIconBytes, 0, $appleTouchIconBytes.Length)
                }

                '/favicon.svg' {
                    $response.ContentType = "image/svg+xml"
                    $response.ContentLength64 = $faviconSvgBytes.Length
                    $response.OutputStream.Write($faviconSvgBytes, 0, $faviconSvgBytes.Length)
                }

                '/api/art' {
                    $artPath = $request.QueryString['path']
                    if ($artPath) {
                        try {
                            $imgUri = "http://${PlexServer}${artPath}?X-Plex-Token=${Token}"
                            $wc = New-Object System.Net.WebClient
                            $imgBytes = $wc.DownloadData($imgUri)
                            $response.ContentType = "image/jpeg"
                            $response.ContentLength64 = $imgBytes.Length
                            $response.OutputStream.Write($imgBytes, 0, $imgBytes.Length)
                        }
                        catch {
                            $response.StatusCode = 404
                        }
                    }
                    else {
                        $response.StatusCode = 400
                    }
                }

                '/api/players' {
                    # Union of registered controllable clients (from /clients) and
                    # whatever's actually playing right now (from /status/sessions).
                    # Plex Web browser sessions usually don't register as
                    # controllable, so without the second half they'd never show
                    # up here even while actively playing something.
                    $clients = Get-PlexClients -Server $PlexServer -Token $Token
                    $activeSessions = Get-PlexNowPlayingTracks -Server $PlexServer -Token $Token
                    $names = @()
                    $names += $clients | ForEach-Object { $_.Name }
                    $names += $activeSessions | ForEach-Object { $_.Player }
                    $names = @($names | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
                    Write-JsonResponse -Response $response -Object @{ players = $names; default = $Player }
                }

                '/api/status' {
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/rate' {
                    $reader = New-Object IO.StreamReader($request.InputStream)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json
                    $tracks = $controlTracks

                    if ($tracks -and $tracks.Count -eq 1) {
                        $track = $tracks[0]
                        $stars = [double]$body.rating
                        Set-PlexRating -Server $PlexServer -Token $Token -RatingKey $track.RatingKey -Stars $stars

                        # Remember what we just set - Plex's /status/sessions won't
                        # reflect this until the track changes, so Get-StatusObject
                        # needs this cache to report the correct live value.
                        $script:RatingOverrides[[string]$track.RatingKey] = $stars

                        if ($stars -lt 3) {
                            # Track is about to change - skip, give Plex a moment to advance.
                            $accepted = Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Direction 'Next' -MediaType $track.MediaType
                            Confirm-PlexControl -Accepted $accepted -Action 'skip after rating (rating saved)'
                            Start-Sleep -Milliseconds 900
                        }
                    }

                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/next' {
                    $tracks = $controlTracks
                    if ($tracks -and $tracks.Count -eq 1) {
                        $accepted = Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $tracks[0].MachineIdentifier -Direction 'Next' -MediaType $tracks[0].MediaType
                        Confirm-PlexControl -Accepted $accepted -Action 'next'
                        Start-Sleep -Milliseconds 900
                    }
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/previous' {
                    $tracks = $controlTracks
                    if ($tracks -and $tracks.Count -eq 1) {
                        $accepted = Invoke-PlexSkip -Server $PlexServer -Token $Token -MachineIdentifier $tracks[0].MachineIdentifier -Direction 'Previous' -MediaType $tracks[0].MediaType
                        Confirm-PlexControl -Accepted $accepted -Action 'previous'
                        Start-Sleep -Milliseconds 900
                    }
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/playpause' {
                    $tracks = $controlTracks
                    if ($tracks -and $tracks.Count -eq 1) {
                        $track = $tracks[0]
                        $command = if ($track.State -eq 'playing') { 'pause' } else { 'play' }
                        $accepted = Invoke-PlexPlaybackCommand -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Command $command -MediaType $track.MediaType
                        Confirm-PlexControl -Accepted $accepted -Action $command
                        Start-Sleep -Milliseconds 400
                    }
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/seek' {
                    $offsetMs = [long]$request.QueryString['offset']
                    $tracks = $controlTracks
                    if ($tracks -and $tracks.Count -eq 1) {
                        $track = $tracks[0]
                        $accepted = Invoke-PlexSeek -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -OffsetMs $offsetMs -MediaType $track.MediaType
                        Confirm-PlexControl -Accepted $accepted -Action 'seek'
                        Start-Sleep -Milliseconds 300
                    }
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                '/api/volume' {
                    $vol = [int]$request.QueryString['value']
                    if ($vol -lt 0) { $vol = 0 }
                    if ($vol -gt 100) { $vol = 100 }
                    $tracks = $controlTracks
                    if ($tracks -and $tracks.Count -eq 1) {
                        $track = $tracks[0]
                        if (Test-VolumeSupported -Device $track.Device -Player $track.Player) {
                            $accepted = Invoke-PlexSetVolume -Server $PlexServer -Token $Token -MachineIdentifier $track.MachineIdentifier -Volume $vol -MediaType $track.MediaType
                            Confirm-PlexControl -Accepted $accepted -Action 'volume'
                            $script:VolumeState[[string]$track.MachineIdentifier] = $vol
                            Save-VolumeState
                        }
                        else {
                            throw "Volume control is not supported on this device."
                        }
                    }
                    $status = Get-StatusObject -Server $PlexServer -Token $Token -PlayerFilter $playerFilter
                    Write-JsonResponse -Response $response -Object $status
                }

                default {
                    $response.StatusCode = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            }
        }
        catch {
            Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Yellow
            try {
                Write-JsonResponse -Response $response -Object @{ found = $false; message = $_.Exception.Message } -StatusCode 500
            }
            catch { }
        }
        finally {
            $response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
