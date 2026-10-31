# plex

First entry keeps the card, its header controls and playback content hidden until devices and status finish, then reveals them together over 600ms. PIN prompts and initial errors show immediately. Reduced motion disables the entrance, and later refreshes never replay it.

PowerShell tools for the Plex Media Server on `jimbrownhome:32400`: a web UI for rating and
skipping the current track, a command-line track controller, and a now-playing toast watcher.

## Hosted web UI

The web UI runs on `jimbrownhome1` as the `\JimlerTech\SolutionDeploy-plex` scheduled task, under
`NT AUTHORITY\LOCAL SERVICE`. It starts at boot and stays running. If the web UI exits with an
error, Task Scheduler restarts it up to 3 times, 1 minute apart. A healthy task shows `Running`
with last result `0x41301`.

| Access            | URL                                          |
| ----------------- | -------------------------------------------- |
| Cloudflare Access | https://plex.jimlertech.com                  |
| Tailscale         | https://jimbrownhome1.tail8ad282.ts.net:8793 |

The listener uses internal port `18793`, because Tailscale serve owns `8793` on the tailnet address. The LAN port `18793` is blocked by the Windows firewall. Only `cloudflared` and Tailscale serve
reach it, both through `127.0.0.1`.

Host layout under `C:\ProgramData\SolutionDeploy\apps\plex`:

| Folder               | Contents                     | LOCAL SERVICE access |
| -------------------- | ---------------------------- | -------------------- |
| `current`            | A copy of this repo          | Read                 |
| `secrets\plex.token` | The X-Plex-Token             | Read                 |
| `data`               | `PlexWebUI.VolumeState.json` | Modify               |
| `logs\plex.log`      | Output, rotated at 5 MB      | Modify               |

[deploy/Start-PlexHost.ps1](deploy/Start-PlexHost.ps1) is the task's entry point. It reads the
token file and starts `Start-PlexWebUI.ps1` on port 18793 with `-Public`. The URL reservation
`http://+:18793/` is granted to LOCAL SERVICE.

To deploy a change, copy the repo into `current` and restart the task:

```powershell
Copy-Item .\* \\jimbrownhome1\c$\ProgramData\SolutionDeploy\apps\plex\current -Recurse -Force
# then on jimbrownhome1, elevated:
Stop-ScheduledTask -TaskPath \JimlerTech\ -TaskName SolutionDeploy-plex; Start-ScheduledTask -TaskPath \JimlerTech\ -TaskName SolutionDeploy-plex
```

## Scripts

The web card's palette icon opens a Theme popover with square Light, Midnight and
System pills, matching Solution Directory. Midnight is the
default; System follows the OS live. Preferences persist in browser localStorage
under `plex-theme`, using `system`, `light` or `midnight`. Gold stays the accent
in every theme. Roboto Flex loads from Google Fonts with a system fallback.
Choosing a theme keeps the popover open; only the palette icon (or Escape) closes
it and returns focus to the icon. Arrows and Home/End move between pills; no
native dropdown is rendered.

Refresh and volume hints use one delegated, theme-aware tooltip. The hidden
`SHOW_TOOLTIPS` setting in `Start-PlexWebUI.ps1` is `false`, so hints stay closed
and remain screen reader descriptions. When it is `true`, hover or focus shows a
hint; Escape, scroll and click dismiss it. Unsupported volume controls
have a focusable row explaining their disabled state.

Run `npm test` for offline theme, script and tooltip regression tests. Tooltip
tests evaluate the canonical PowerShell HTML without starting a server, and check
dynamic volume status, pointer transfer, focus, dismissal and cleanup.
After updating `Start-PlexWebUI.ps1`, restart the hosted task and reload the page.
No Plex server configuration or database changes are required.

### Controlling Plexamp away from home

Track information and playback controls use separate paths. The hosted UI reads
`/status/sessions` from the home Plex server, so it can show a travelling iPhone's
current track even when controls cannot reach that phone.

Controls use Plex Companion through the home server. Remote music streaming and
access to this UI through Cloudflare do not make the phone's Companion endpoint
reachable. Plexamp's official apps have some cloud controls, but this UI does not
implement that undocumented protocol. See this
[Plex forum reproduction](https://forums.plex.tv/t/feature-request-supported-server-mediated-api-for-controlling-remote-plex-plexamp-sessions/942315)
for the same Plexamp-on-iPhone limitation.

Use Plexamp's own controls when away from home. A VPN is only a possible workaround
if the home server can actually reach the phone's advertised Companion endpoint;
turning on Tailscale alone does not establish that. Do not expose the phone's
Companion port to the public internet.

The UI reports rejected or failed command requests and only saves requested volume
after Plex accepts the request. Acceptance is not confirmation that the player
applied the command. Volume remains the last accepted request, not a live reading.

| Script                                 | Purpose                                                                         |
| -------------------------------------- | ------------------------------------------------------------------------------- |
| `Start-PlexWebUI.ps1`                  | The web UI server (`HttpListener`)                                              |
| `PlexTrackLib.ps1`                     | Shared Plex API calls                                                           |
| `Set-PlexTrack.ps1`                    | Rate, skip, or go back from the command line                                    |
| `Watch-PlexNowPlaying.ps1`             | Windows toast on track change (Windows PowerShell 5.1)                          |
| `PlexNotifyWatcher-ProfileSnippet.ps1` | Profile functions for the watcher                                               |
| `Set-PlexToken.ps1`                    | Store a new token locally and, with `-UpdateHost`, on jimbrownhome1             |
| `desktop\`                             | The earlier per-user logon launcher, kept as a reference for hidden logon tasks |
| `Plex-API-Reference.md`                | Notes on the Plex HTTP API                                                      |

Every script takes `-Token`. The pwsh profile loads it into `PLEX_TOKEN` from the per-user DPAPI
file `%LOCALAPPDATA%\JimlerTech\plex-token.dpapi.xml`; it is never committed.

## Desktop notifications

Reload the profile in any terminals opened before the scripts moved into this repo:

```powershell
. $PROFILE
Start-PlexNotifyWatcher -Client IPhone
```

The profile launcher uses the Plex server's LAN address, `192.168.2.11:32400`, so
notifications work on the home network without Tailscale. Override it with
`-PlexServer 'hostname:32400'` when needed. The launcher checks for the script and
token, and reports an error if the watcher exits during startup. Startup output is
in `%TEMP%\PlexNotifyWatcher.out.log` and `%TEMP%\PlexNotifyWatcher.err.log`;
polling and toast results are in `%TEMP%\PlexNotifyWatcher.activity.log`.

## Rotating the token

The token was once committed to the `powershell` and `config` repos, so treat it as exposed.

1. At plex.tv, open Account > Authorized Devices and remove old sessions, or change the password
   with "sign out of all devices". Sign back in and copy the new `X-Plex-Token`.
2. In a terminal outside VS Code chat, run `.\Set-PlexToken.ps1 -UpdateHost`.
3. On each other machine that uses the profile, run `.\Set-PlexToken.ps1`.
