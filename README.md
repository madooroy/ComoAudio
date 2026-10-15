# ComoAudio

A one-page web remote for a **Como Audio Duetto** radio, for when the official app won't connect. It runs in any browser on the home network and can be added to an iPhone home screen like an app.

**Controls:** power, volume, mute, and source (FM, Spotify, Internet Radio, Bluetooth, USB, Aux). It reads the radio's current state on load, refreshes when you come back to the page, and shows whether it can reach the radio.

**Now playing:** the station and song (radio), or track, artist and album (Spotify, USB, Bluetooth), with the station logo or album art when the radio provides it. Updates every 10 seconds while the page is open.

**Presets:** in Internet Radio and FM, the radio's own presets appear as buttons; tap one to tune in. The one playing is highlighted. Presets are stored on the radio (set them with the radio's remote or front panel), and each source has its own list.

**Browse & search stations:** in Internet Radio, "Browse & search stations" opens the radio's own station directory, the same menus as on its screen (My Favourites, Local, Stations by location and genre, Podcasts…). Open folders, go back, search by name, and tap a station to play it. The page drives the radio's menu, so the radio's display may move along with it.

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
