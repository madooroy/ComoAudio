# ComoAudio

A one-page web remote for a **Como Audio Duetto** radio, for when the official app won't connect. It runs in any browser on the home network and can be added to an iPhone home screen like an app.

**Controls:** power, volume, mute, and source (FM, Spotify, Internet Radio, Bluetooth, USB, Aux). It reads the radio's current state on load, refreshes when you come back to the page, and shows whether it can reach the radio.

## How it works

The Duetto (like other Frontier Silicon radios) has a small HTTP API called FSAPI, e.g.

```
http://<radio-ip>/fsapi/SET/netRemote.sys.audio.volume?pin=1234&value=12
```

The page calls that API directly with `fetch()`; the radio allows these cross-origin requests.

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
