# Plex Media Server API Reference

Plex doesn't publish an official, complete API spec for the local Plex Media Server
HTTP interface — everything below is compiled from community reverse-engineering
(Plexopedia, the archived Arcanemagus/plex-api wiki, and PlexAPI.dev/python-plexapi)
plus the endpoints already verified working in your own scripts (marked **[used]**).

## Basics

- **Base URL:** `http://<PMS-IP>:32400/` (32400 is the default port).
- **Auth:** almost everything requires `X-Plex-Token` as a query param or header.
  Get yours from `https://www.plexopedia.com/plex-media-server/general/plex-token/`
  or by inspecting Plex Web's network requests.
- **Response format:** XML by default. Add header `Accept: application/json` to get JSON instead.
- **Common client identity params** (mostly optional, but some clients expect them):
  `X-Plex-Platform`, `X-Plex-Platform-Version`, `X-Plex-Product`, `X-Plex-Version`,
  `X-Plex-Device`, `X-Plex-Client-Identifier`.

---

## Server / Identity

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/identity` | Unauthenticated basic server info (machineIdentifier, version). Useful before you know a remote server's token. |
| GET | `/` | Server capabilities, transcode bitrate info, myPlex auth info. |
| GET | `/:/prefs` | Get all server preferences. |
| PUT | `/:/prefs?<name>=<value>` | Set a single server preference. |
| GET | `/servers` | List of servers this instance knows about. |
| GET | `/system` | General system info. |
| GET | `/system/agents` | Metadata agents available/configured. |

---

## Sessions / Now Playing **[used]**

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/status/sessions` **[used]** | Currently playing sessions across all players — `<Track>` nodes for music, `<Video>` nodes for movies/episodes. Each has a `<Player>` child with `title`, `device`, `machineIdentifier`, `state`. This is the backbone of your web UI's "now playing" polling. |
| GET | `/status/sessions/history/all` | Playback history. |
| GET | `/transcode/sessions` | Active transcode sessions. |
| DELETE | `/transcode/sessions/<key>` | Kill a transcode session. |

**Known quirk you already hit:** `userRating` on a session node is a snapshot from
when the track started — it does not live-update after a `/:/rate` call for the rest
of that session. Hence the `$script:RatingOverrides` cache in your web UI.

---

## Clients & Remote Playback Control **[used]**

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/clients` **[used]** | Lists "controllable" registered clients (name + `machineIdentifier`). Notably does **not** include Plex Web browser sessions. |

All playback-control commands below are sent **to the Plex server**, with a header
`X-Plex-Target-Client-Identifier: <machineIdentifier>` telling the server which
client to relay the command to. Most require `type=music|photo|video` (matches what
your `-MediaType` param does) and a `commandID` (any incrementing integer — you use
a Unix timestamp, which works fine).

### Playback commands

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/player/playback/play` **[used]** | Resume/start playback. |
| GET | `/player/playback/pause` **[used]** | Pause playback. |
| GET | `/player/playback/stop` | Stop playback entirely. |
| GET | `/player/playback/skipNext` **[used]** | Skip to next item. |
| GET | `/player/playback/skipPrevious` **[used]** | Skip to previous item. |
| GET | `/player/playback/skipTo?key=<ratingKey>` | Jump directly to a specific playlist/queue item. |
| GET | `/player/playback/seekTo?offset=<ms>` **[used]** | Seek to an absolute offset in ms. |
| GET | `/player/playback/stepForward` / `/stepBack` | Nudge forward/back by a fixed chunk (client-defined, usually ~30s). |
| GET | `/player/playback/setParameters?volume=<0-100>&shuffle=<0/1>&repeat=<0/1/2>` **[used, volume only]** | Set volume/shuffle/repeat. **Volume is the one many clients silently ignore** — you've confirmed Roku and LG (webOS) TVs don't honor it, since it's a hardware/remote-only control on those platforms. Desktop/mobile/web Plex apps are more likely to support it. |
| GET | `/player/playback/setStreams?audioStreamID=&subtitleStreamID=&videoStreamID=` | Switch audio/subtitle/video track mid-playback. |
| GET | `/player/playback/playMedia?key=<metadata key>&machineIdentifier=<server id>&address=<ip>&port=<port>` | Tell a client to start playing a specific library item from scratch. |
| GET | `/player/playback/refreshPlayQueue?playQueueID=<id>` | Refresh a client's play queue. |

### Navigation commands (control the client's on-screen UI, not media playback)

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/player/navigation/home` | Go to home screen. |
| GET | `/player/navigation/back` | Navigate back one screen. |
| GET | `/player/navigation/moveUp` / `moveDown` / `moveLeft` / `moveRight` | Move UI selection. |
| GET | `/player/navigation/select` | Select the currently highlighted element. |
| GET | `/player/navigation/contextMenu` | Open context menu. |
| GET | `/player/navigation/toggleOSD` | Toggle on-screen display during playback. |
| GET | `/player/navigation/music` | Jump to the now-playing music panel. |
| GET | `/player/navigation/pageUp` / `pageDown` | Scroll a full page. |
| GET | `/player/navigation/nextLetter` / `previousLetter` | Jump alphabetically (useful in long lists). |

---

## Rating & Watched State **[used]**

| Method | Endpoint | What it does |
|---|---|---|
| PUT | `/:/rate?key=<ratingKey>&identifier=com.plexapp.plugins.library&rating=<0-10>` **[used]** | Set star rating. Note the 0-10 scale internally — your scripts multiply stars × 2. |
| GET | `/:/scrobble?key=<ratingKey>&identifier=com.plexapp.plugins.library` | Mark item as watched. |
| GET | `/:/unscrobble?key=<ratingKey>&identifier=com.plexapp.plugins.library` | Mark item as unwatched. |
| GET | `/:/progress?key=<ratingKey>&time=<ms>&identifier=com.plexapp.plugins.library` | Manually set an item's `viewOffset` (partial-watch progress), without actually seeking a live player. |

---

## Library Browsing

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/library/sections` | List all libraries ("sections" internally — e.g. Movies, TV Shows, Music). |
| GET | `/library/sections/<id>/all` | All items in a section. Supports advanced filtering (see below). |
| GET | `/library/sections/<id>/refresh` | Trigger a rescan of that library. |
| GET | `/library/sections/<id>/firstCharacter` | List of alphabet index characters for that section. |
| DELETE | `/library/sections/<id>` | Delete a library section. |
| POST | `/library/sections` | Add a new library section. |
| GET | `/library/metadata/<ratingKey>` | Full metadata for a specific item. |
| GET | `/library/onDeck` | "Continue watching" items. |
| GET | `/library/recentlyAdded` | Recently added items. |
| GET | `/search?query=<string>` | Search across the whole server. |

**Advanced filtering** (on `/library/sections/<id>/all`): query params like
`year=2010`, `year>=1990`, `year!=2012`, `genre=Action`. Multiple params AND together.

---

## Playlists

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/playlists` | List all playlists. |
| GET | `/playlists/<id>` | Get a single playlist. |
| POST | `/playlists?title=<name>&type=<audio/video/photo>&uri=<item uri>` | Create a playlist. |
| PUT | `/playlists/<id>` | Update playlist metadata. |
| DELETE | `/playlists/<id>` | Delete a playlist. |
| GET | `/playlists/<id>/items` | Get items in a playlist. |
| PUT | `/playlists/<id>/items?uri=<item uri>` | Add an item. |
| DELETE | `/playlists/<id>/items/<itemID>` | Remove one item. |
| DELETE | `/playlists/<id>/items` | Clear all items. |

---

## Images / Transcoding

| Method | Endpoint | What it does |
|---|---|---|
| GET | `/photo/:/transcode?url=<path>&width=<w>&height=<h>` **[used, via `/api/art` proxy]** | Resize/transcode a poster/thumbnail image. Your web UI's `/api/art` route proxies through this so the browser never needs the Plex token directly. |
| GET | `/video/:/transcode/universal/decision?path=<path>&protocol=http` | Ask whether a video needs transcoding for a given client profile. |
| GET/POST | `/video/:/transcode/universal/start.m3u8` | Start an HLS transcode stream. |
| GET | `/video/:/transcode/universal/ping?session=<id>` | Keep a transcode session alive. |
| GET | `/video/:/transcode/universal/stop?session=<id>` | Stop a transcode session. |

---

## Maintenance & Scheduled Tasks

| Method | Endpoint | What it does |
|---|---|---|
| PUT | `/library/sections/all/refresh` | Force a metadata refresh across every library. |
| PUT | `/library/optimize` | Run "Optimize Database". |
| PUT | `/library/emptytrash` | Empty trash for a section. |
| PUT | `/library/clean/bundles` | Clean old bundles. |
| GET | `/butler` | List scheduled maintenance tasks. |
| POST | `/butler` | Run all scheduled tasks now. |
| DELETE | `/butler` | Stop all running scheduled tasks. |
| POST/DELETE | `/butler/<TaskName>` | Run/stop a specific task (e.g. `BackupDatabase`, `CleanOldBundles`, `RefreshLibraries`, `DeepMediaAnalysis`). |

---

## Plex.tv (account-level, not your local server)

These hit `https://plex.tv/api/...` instead of your PMS directly — used for
account/device management rather than media control:

| Method | Endpoint | What it does |
|---|---|---|
| GET | `https://plex.tv/api/resources` | List all servers/devices tied to your account. |
| GET | `https://plex.tv/users/account` | Account details. |
| GET | `https://plex.tv/api/home/users` | Managed/home users on the account. |

---

## What your scripts already use, at a glance

`PlexTrackLib.ps1` currently wraps: `/status/sessions`, `/:/rate`,
`/player/playback/{skipNext,skipPrevious,play,pause,seekTo,setParameters}`, and
`/clients`. Everything else in this document is available if you ever want to
extend the tool further — e.g. `/library/onDeck` for a "what's next" screen,
`/:/scrobble` to mark something watched from the web UI, or the Butler task
endpoints to trigger a library rescan remotely.

---

Sources:
- [Plex API Documentation - Plexopedia](https://www.plexopedia.com/plex-media-server/api/)
- [Plex Web API Overview - Arcanemagus/plex-api wiki](https://github.com/Arcanemagus/plex-api/wiki/Plex-Web-API-Overview)
- [Media Player (playback/navigation commands) - Arcanemagus/plex-api wiki](https://github.com/Arcanemagus/plex-api/wiki/Media-Player)
- [PlexAPI.dev Documentation](https://plexapi.dev/Intro)
