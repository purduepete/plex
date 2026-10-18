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
| `desktop\` | The earlier per-user logon launcher, kept as a reference for hidden logon tasks |
| `Plex-API-Reference.md` | Notes on the Plex HTTP API |

Every script takes `-Token`. Keep the token in the `PLEX_TOKEN` user environment variable; it is
never committed.
