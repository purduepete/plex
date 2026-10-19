# plex

PowerShell tools for the Plex Media Server on `jimbrownhome:32400`: a web UI for rating and
skipping the current track, a command-line track controller, and a now-playing toast watcher.

## Hosted web UI

The web UI runs on `jimbrownhome1` as the `\JimlerTech\SolutionDeploy-plex` scheduled task, under
`NT AUTHORITY\LOCAL SERVICE`. It starts at boot, and a 5-minute trigger restarts it if it stops.

| Access | URL |
|---|---|
| Cloudflare Access | https://plex.jimlertech.com |
| Tailscale | https://jimbrownhome1.tail8ad282.ts.net:8793 |

The listener uses internal port `18793`, because Tailscale serve owns `8793` on the tailnet address. The LAN port `18793` is blocked by the Windows firewall. Only `cloudflared` and Tailscale serve
reach it, both through `127.0.0.1`.

Host layout under `C:\ProgramData\SolutionDeploy\apps\plex`:

| Folder | Contents | LOCAL SERVICE access |
|---|---|---|
| `current` | A copy of this repo | Read |
| `secrets\plex.token` | The X-Plex-Token | Read |
| `data` | `PlexWebUI.VolumeState.json` | Modify |
| `logs\plex.log` | Output, rotated at 5 MB | Modify |

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

| Script | Purpose |
|---|---|
| `Start-PlexWebUI.ps1` | The web UI server (`HttpListener`) |
| `PlexTrackLib.ps1` | Shared Plex API calls |
| `Set-PlexTrack.ps1` | Rate, skip, or go back from the command line |
| `Watch-PlexNowPlaying.ps1` | Windows toast on track change (Windows PowerShell 5.1) |
| `PlexNotifyWatcher-ProfileSnippet.ps1` | Profile functions for the watcher |
| `Set-PlexToken.ps1` | Store a new token locally and, with `-UpdateHost`, on jimbrownhome1 |
| `desktop\` | The earlier per-user logon launcher, kept as a reference for hidden logon tasks |
| `Plex-API-Reference.md` | Notes on the Plex HTTP API |

Every script takes `-Token`. The pwsh profile loads it into `PLEX_TOKEN` from the per-user DPAPI
file `%LOCALAPPDATA%\JimlerTech\plex-token.dpapi.xml`; it is never committed.

## Rotating the token

The token was once committed to the `powershell` and `config` repos, so treat it as exposed.

1. At plex.tv, open Account > Authorized Devices and remove old sessions, or change the password
   with "sign out of all devices". Sign back in and copy the new `X-Plex-Token`.
2. In a terminal outside VS Code chat, run `.\Set-PlexToken.ps1 -UpdateHost`.
3. On each other machine that uses the profile, run `.\Set-PlexToken.ps1`.
