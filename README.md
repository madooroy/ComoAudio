# ComoAudio

A one-page web remote for a **Como Audio Duetto** radio, for when the official app won't connect. It runs in any browser on the home network and can be added to an iPhone home screen like an app.

**Layout:** the current source is shown at the top left; **Source ▾** (or tapping the source) opens the source menu. Only the controls for the current source are shown. Power (⏻) and Saved songs (list with a heart) are in the header, mute is next to the volume slider. The page reads the radio's state on load, updates every 10 seconds and when you come back to it, and shows whether it can reach the radio.

**Per source:**
- *Internet Radio*: presets, More stations, Browse & search, Save station. A ↻ button next to the song restarts a stalled stream (a quick power off/on), and while the page is open it does this automatically if the radio reports the stream stopped for ~60 s, stuck buffering for ~2 min, or "playing" with a play position that hasn't moved for ~75 s. These waits are longer than the NAS watchdog's, so when it's running it acts first. The silent check only applies to stations the phone has seen with a moving position (never WCRB or WBUR, whose position always reads 0). At most once every 2 minutes and 3 times in 30 minutes, never while the page is restoring presets, and it checks that the radio came back on.
- *FM*: tune ◀ ▶ (using the radio's own channel step) and FM presets.
- *USB*: previous / play-pause / next, Shuffle, Repeat, and **Browse folders** to pick a folder or track on the drive.
- *Spotify*: previous / play-pause / next and an Open Spotify button.
- *Bluetooth*: previous / play-pause / next (works when the connected device allows it).
- *Aux*: volume only.
- On every source except Internet Radio, a folded **Internet radio presets** row; tapping a station switches to Internet Radio and plays it.

**Now playing:** the station and song (radio), or track, artist and album (Spotify, USB, Bluetooth), with the station logo or album art when the radio provides it. Updates every 10 seconds while the page is open.

**Presets:** in Internet Radio and FM, the radio's own presets appear as buttons; tap one to tune in. The one playing is highlighted. Presets are stored on the radio and each source has its own list; save new ones with Save station or on the radio itself.

**Browse & search stations:** in Internet Radio, "Browse & search" opens the radio's own station directory, the same menus as on its screen (My Favourites, Local, Stations by location and genre, Podcasts…). Open folders, go back, search by name, and tap a station to play it. The page drives the radio's menu, so the radio's display may move along with it.

**Save station:** while an internet radio station is playing, "Save station" offers two ways to keep it:
- *Radio presets*: stores it in one of the radio's own preset slots (so it also works from the radio's buttons). Slots already in use ask before they're replaced. Uses `netRemote.play.addPreset`; if the firmware doesn't allow that, the page says so.
- *More stations*: an unlimited list kept on the phone, shown under the presets. The Duetto can't be given a stream address, so each one remembers the route to it in the radio's directory (folders or a search) and replays it, falling back to a search by name if the directory has changed. Playing one takes a few seconds.

**Preset backup & restore:** each phone keeps a copy of the last full list of Internet Radio presets. If the radio later reports fewer presets (e.g. they were wiped), a banner lists the missing ones with a **Restore** button. Tapping it first re-reads the radio's presets (the NAS watchdog may already have put them back), then finds each station in the radio's directory and saves it back, into its original slot if that's still free (otherwise into a free slot, never over a preset you've set since), then returns to what was playing. Swapping one station for another doesn't trigger it.

**Favorites:** tap the heart next to a song to save it. The Favorites list has a "Find in Spotify" button for each song. Favorites are stored in the browser on each phone, so each phone has its own list.

## How it works

The Duetto (like other Frontier Silicon radios) has a small HTTP API called FSAPI, e.g.

```
http://<radio-ip>/fsapi/SET/netRemote.sys.audio.volume?pin=1234&value=12
```

The page calls that API directly with `fetch()`; the radio allows these cross-origin requests. It reads everything in one `GET_MULTIPLE` request, and falls back to one request per setting on firmware that doesn't support that. Presets use `netRemote.nav.presets` and `netRemote.nav.action.selectPreset`; the station browser uses `netRemote.nav.list`, `netRemote.nav.action.navigate` / `selectItem`, `netRemote.nav.searchTerm` and `netRemote.nav.status`.

## Setup

1. **Give the radio a fixed address.** Reserve its IP in your router's DHCP settings.
2. **Edit the settings** at the top of the script in `index.html`:
   - `BASE`: the radio's address, e.g. `http://192.168.100.102/fsapi`
   - `PIN`: the radio's remote PIN (factory default `1234`)
3. **Serve it over plain HTTP on your home network.** This is hosted on a NAS. It can't be served from an HTTPS site such as GitHub Pages: browsers block an HTTPS page from calling an HTTP device ("mixed content"), and the radio only speaks HTTP.
4. Copy `index.html` and `apple-touch-icon.png` into the same folder on the web server.
5. **iPhone:** open the page in Safari → Share → *Add to Home Screen*. It opens full-screen as "Duetto".

## Notes

- **Volume** is intentionally limited to 5–20 in the slider (`min`/`max` on the `#vol` input).
- **Source numbers** (0, 1, 3, 4, 5, 6) match this radio's current firmware. If an update changes them, open
  `http://<radio-ip>/fsapi/LIST_GET_NEXT/netRemote.sys.caps.validModes/-1?pin=1234&maxItems=20`
  to see the new list and update `MODES` in `index.html`.

## Always-on stream watchdog (Synology NAS)

The page restarts a stalled stream only while it's open on a phone. `nas/duetto-watchdog.sh` does the same around the clock from the NAS: when internet radio has been stopped/failed for 30 s (or buffering for 90 s), or says it's playing but its play position (`netRemote.play.position`) hasn't moved between two checks 15 s–2 min apart (a "silent" stall), it power-cycles the radio so it reconnects, at most once every 5 minutes, and checks that it came back on (retrying, and logging if it didn't). It leaves the radio alone when it's off, on another source, or unreachable, and logs what it does to `duetto-watchdog.log` next to the script.

1. Copy `duetto-watchdog.sh` to a folder on the NAS (e.g. next to the page). In File Station, right-click it → Properties to see its full path, e.g. `/volume1/web/duetto-watchdog.sh`.
2. Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script.
3. *General*: name it "Duetto watchdog"; user: your own account (it needs write access to that folder).
4. *Schedule*: daily, every minute, during your listening hours (e.g. first run 06:00, last run 21:59). Each run takes about 30 s.
5. *Task Settings* → Run command: `sh /volume1/web/duetto-watchdog.sh` (your path).

**Presets:** when the radio comes on (after being off, a power cut, or not seen for 10+ minutes), the watchdog reads the Internet Radio presets. If they're intact it saves `duetto-presets.backup`; if they've **all** gone, it mutes the radio, finds each station in the directory, saves it back into its slot, returns to what was playing and unmutes. It also re-reads the presets hourly while the radio is on to keep the backup current. The backup is never overwritten by a shorter list; if only some presets are missing it just logs it (the page's Restore can put them back). It also logs firmware changes. Set `AUTO_RESTORE=0` to only log, or delete `duetto-presets.backup` to start the backup afresh.

**Limits:** every log line names the station. If the same station needs 3 recoveries within an hour, the watchdog switches to the preset whose name contains `FALLBACK` (default `WBUR`) instead of power-cycling again. The fallback preset is looked up in `duetto-presets.backup`. After 6 recoveries within an hour it pauses them, logging until when; as older ones pass the hour mark they resume, so the most it does is about 6 an hour.

**Stations that don't report a play position:** some streams (WCRB and WBUR here) play fine while the radio's play position stays at 0, which looks exactly like a silent stall. So the silent check only applies to stations the watchdog has seen with a moving position; it keeps that list in `duetto-watchdog.counting` and logs each station it adds. Stations in `NO_SILENT_CHECK` (default `WCRB,WBUR`; comma-separated, any part of the name) are never added. A real silent stall on such a station can't be detected, but every station is still restarted if it stops or keeps buffering. The page keeps its own copy of the list and learns its own stations on each phone.

**Outage mode:** if a second, different station also fails within the hour (for example the fallback stops too), or one station keeps failing with no other station to switch to (it is the fallback itself), the problem is the internet connection or the radio, not a station. The watchdog logs that and then restarts the radio at most every 15 minutes (`OUTAGE_GAP`), without switching stations, until a stream plays again: its position moves or, on a station that doesn't report one, it says "playing" on two checks in a row. It logs when the outage is over. Switching the radio off or to another source also ends it, and an outage older than 4 hours is dropped.

Settings (radio address, PIN, timings, limits, fallback station) are at the top of the script.
