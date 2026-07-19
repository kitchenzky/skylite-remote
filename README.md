## iPhone: `index.html` web app (no Mac needed)

`index.html` (same file as `skylite.html`) is a self-contained Web Bluetooth
app — works standalone on iPhone via the **Bluefy** browser (Safari has no
Web Bluetooth).

**Deploy to GitHub Pages:**
1. Push this folder to a GitHub repo (`.gitignore` already excludes the
   APK/decompile artifacts — those aren't needed to run the app).
2. Repo Settings → Pages → Deploy from branch → `main` / root. Wait ~1 min.
3. URL will be `https://<user>.github.io/<repo>/` — serves `index.html`
   automatically. HTTPS is required for Web Bluetooth; Pages gives you that.
4. On iPhone, open that URL **in Bluefy** (not Safari) → Share → Add to
   Home Screen. Launches full-screen like a native app from then on.

`manifest.json` + `icon.svg` give it a proper name/icon/splash color on the
home screen. No build step, no server code — just static files.

# BlissLights Sky Lite 2.0 — direct Bluetooth control (no app)

The official BlissLights app was pulled from the App Store and Google Play.
This talks to the Sky Lite 2.0 directly over its Bluetooth LE mesh, so you
don't need the app at all. **This is confirmed working** — on/off, presets,
and color all control a real light.

## Your light's details (fill these in once)

- **BLE address (macOS):** `2B828E3B-61A4-05CB-6FA1-24E9C6068052`
  - macOS makes this up per-Mac and it can change. If a command can't find
    the light, re-run `scan_devices.py` to get the current one.
- **Real Bluetooth MAC:** `A4C1385A60D1`
  - Hardware value, never changes. Always pass it with `--mac`.
- **Mesh credentials:** `telink_mesh0` / `123` (factory defaults; the script
  uses these automatically)

## Everyday usage

```bash
python3 control.py <address> on   --mac A4C1385A60D1
python3 control.py <address> off  --mac A4C1385A60D1
python3 control.py <address> scenes --mac A4C1385A60D1     # list presets
python3 control.py <address> scene 4 --mac A4C1385A60D1    # 4 = Nebula
python3 control.py <address> color 255 0 255 --mac A4C1385A60D1   # magenta
```

`color` takes optional extra values after R G B:
`color <r> <g> <b> [brightness 0-255] [laser 0-255] [motor 0-255]`
(laser = the green star dots, motor = rotation speed).

### Built-in presets

| ID | Effect |
|----|--------|
| 1  | Stars against nebula |
| 2  | Fading |
| 3  | Stars |
| 4  | Nebula |
| 5  | Ocean |
| 6  | Space |
| 8  | Sunrise |
| 9  | RGB auto |
| 0  | ON/OFF (manual color mode) |

## One-time setup

```bash
pip3 install bleak pycryptodome
```

Make sure Bluetooth is on and you're within ~10 ft of the light.

## Important: don't re-add this light in the BlissLights app

The light was factory-reset (hold the top button until it flashes 6 times)
so it would accept the factory mesh credentials this script uses. If you ever
re-add it inside the iPhone app, the app assigns a new random mesh name and
this script will stop working (pairing will return `0x0E`). To recover, just
factory-reset the light again (top button, 6 flashes) and it'll work here
again.

## How it works (for future reference)

The Sky Lite 2.0 uses a Telink TLSR8250 BLE mesh chip. Getting a command to
actually take effect required getting *all* of these right at once — each one
wrong causes a silent no-op:

1. **Mesh credentials** `telink_mesh0` / `123` (factory defaults, restored by
   the 6-flash reset). The app normally reprovisions each light with a random
   per-phone mesh name, which is why pairing failed before the reset.
2. **Real MAC** `A4:C1:38:5A:60:D1` — used as key material in the per-packet
   encryption nonce (macOS hides this, so it must be passed explicitly).
3. **Write-without-response** on the command characteristic (`...1912`) — the
   firmware ignores write-with-response.
4. **Projector opcode** — on/off is `{0x41, state, 0x01}`; effect switch is
   `{0x41, id, 0x00}`; color is `{0x47, R,G,B, laser, motor, bright, breathe}`.
   (The LED-strip product uses different opcodes — `0x16`/`0x11`/`0x12`.)
5. **Correct mesh address** — the light reports its own address (`0xD1`) in its
   online-status notifications; the script auto-discovers and targets it.
6. **Random 24-bit sequence number** — the firmware drops commands whose
   sequence number looks like a replay, so each session starts at a random
   value like the real app does.

All of the crypto (`telink_mesh.py`) was verified byte-for-byte against the
decompiled BlissLights Android app.

## Files

- `control.py` — the command-line tool you run.
- `telink_mesh.py` — the protocol/crypto implementation.
- `scan_devices.py` — lists nearby BLE devices (to find the light's address).
- `requirements.txt` — Python dependencies.
