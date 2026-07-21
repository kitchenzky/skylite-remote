# Kitchenzky Sky Remote

A mobile-first Web Bluetooth remote for a BlissLights Sky Lite 2.0 projector. It connects directly to the projector without requiring the BlissLights app or a server.

**Live app:** [kitchenzky.github.io/skylite-remote](https://kitchenzky.github.io/skylite-remote/)

The interface is designed primarily for iPhone and has been tested with the [Bluefy](https://apps.apple.com/app/bluefy-web-ble-browser/id1492822055) Web Bluetooth browser. Safari does not provide the Web Bluetooth API required by this project.

## Features

- Direct Bluetooth Low Energy connection and Telink mesh login
- Remembers the permitted projector after the first selection
- Automatically falls back to the Bluetooth chooser if a remembered connection is stale
- Power control and connection-state feedback
- Ten presets, including three custom animated effects
- Manual red, green, blue and laser-dot selection
- Low, Medium and High brightness controls
- Independent rotation control
- Restores the selected output after connecting
- Safe disconnection and animated-preset recovery when Bluefy moves between foreground and background
- Full-screen, copyable diagnostic log with bounded local history
- Responsive iPhone layout and home-screen metadata

## Use it on iPhone

1. Install Bluefy from the App Store.
2. Turn on Bluetooth and place the phone near the projector.
3. Close the BlissLights app on every phone that may still be connected to the projector.
4. Open the [live app](https://kitchenzky.github.io/skylite-remote/) inside Bluefy.
5. Tap the round Bluetooth button.
6. If the device chooser appears, select **BlissLights**.
7. Wait for **Connected ✓** before using the controls.

The app remembers the authorized device. On later visits it first tries that projector directly; if Bluefy has a stale Bluetooth reference, the chooser opens so the connection can continue.

### Add it to the Home Screen

Open the live app in Bluefy, use the Share menu, and choose **Add to Home Screen**. The included `manifest.json` and `icon.svg` provide the app name, icon, portrait orientation and dark launch colors.

## Controls

### Presets

| Preset | Effect |
| --- | --- |
| Nebula + Stars | Nebula and laser stars |
| Nebula | Nebula without laser stars |
| Stars | Laser stars only |
| Ocean | Built-in ocean scene |
| Space | Built-in space scene |
| Sunrise | Built-in sunrise scene |
| Perfect Blue | Blue nebula and blue laser dots fade against one another while both remain visible |
| Cosmic Pulse | Magenta nebula with smoothly pulsing laser stars |
| RGB Pulse | Slowly and smoothly transitions through red, blue and green with rotation enabled |
| Fading | Built-in fading scene |

Custom animations stop safely when changing presets, tabs, power state or Bluetooth connection.

### Light Control

Opening **LIGHT CONTROL** switches from the current preset to the remembered custom configuration. The initial configuration is:

- Red, green and blue enabled
- Laser dots enabled
- High brightness
- Rotation ON

Changes are sent as one complete projector state so brightness, colors, laser dots and rotation remain independent.

## Diagnostic Log

Tap the circled bug icon in the upper-right corner to open diagnostics. The report records connection stages, pairing, power and output commands, lifecycle changes, animation health and projector feedback.

- Tap **COPY** and paste the report into an issue or support conversation.
- Tap **CLEAR** before reproducing a new, unrelated problem.
- The history automatically rolls over at 240 events or about 80,000 characters.
- Passwords, session keys, pairing challenges and hardware identifiers are excluded or redacted.

For a clean bug report: **CLEAR → reproduce the problem once → COPY**.

## Troubleshooting

### The first connection attempt fails

Keep the page visible and tap Connect once. The app tries the remembered projector first and opens the chooser during the same attempt if that reference is stale. If Bluefy or iOS refuses the chooser, tap Connect again and select **BlissLights**.

### `Light rejected pairing (0xe)`

The projector is probably connected to, or was provisioned by, the BlissLights app. Fully close that app on every nearby phone and retry.

If the error persists, a factory reset may be required. Hold the projector's top button until it flashes six times. This removes its existing app pairing and restores the factory mesh credentials, so use it only when necessary.

### The projector is missing from the chooser

- Move the phone closer to the projector.
- Make sure another phone or app is not connected.
- Close and reopen Bluefy.
- Unplug the projector briefly, reconnect power, and try again.

### GitHub Pages shows an older build

Wait about a minute after a push, then reload the page in Bluefy. GitHub Pages provides the HTTPS context required by Web Bluetooth.

## Compatibility and device configuration

This repository is confirmed with one BlissLights Sky Lite 2.0 using the factory Telink mesh credentials. Web Bluetooth does not expose the projector's real hardware MAC address, but the Telink packet encryption requires it. The current app therefore contains the tested projector's MAC in `REAL_MAC`.

To use the project with a different Sky Lite unit, determine that unit's real Bluetooth MAC and update `REAL_MAC` in both `index.html` and `skylite.html`. A differently provisioned projector may also need to be returned to its factory mesh credentials.

## Deployment

The web app is static and needs no build step:

1. Fork or clone the repository.
2. In GitHub, open **Settings → Pages**.
3. Choose **Deploy from a branch**.
4. Select `main` and `/ (root)`.
5. Open `https://<username>.github.io/<repository>/` after deployment completes.

`index.html` is the GitHub Pages entry point. `skylite.html` is an identical standalone copy.

## Optional macOS command-line tools

The repository also includes the original Python controller used to inspect and validate the protocol.

Install its dependencies:

```bash
python3 -m pip install -r requirements.txt
```

Find the macOS Bluetooth identifier:

```bash
python3 scan_devices.py
```

Example commands:

```bash
python3 control.py <macOS-address> on --mac <real-hardware-mac>
python3 control.py <macOS-address> off --mac <real-hardware-mac>
python3 control.py <macOS-address> scenes --mac <real-hardware-mac>
python3 control.py <macOS-address> scene 4 --mac <real-hardware-mac>
python3 control.py <macOS-address> color 255 0 255 --mac <real-hardware-mac>
```

The optional color arguments are:

```text
color <red> <green> <blue> [brightness 0-255] [laser 0-255] [motor 0-255]
```

## Repository files

- `index.html` — deployed mobile web app
- `skylite.html` — identical standalone copy of the web app
- `manifest.json` — home-screen/PWA metadata
- `icon.svg` — local app icon
- `control.py` — macOS command-line controller
- `telink_mesh.py` — Telink mesh protocol and cryptography
- `scan_devices.py` — nearby BLE device scanner
- `requirements.txt` — Python dependencies

## Protocol notes

The projector uses a Telink TLSR8250 BLE mesh. Commands require factory mesh credentials, the real hardware MAC as encryption input, write-without-response on the command characteristic, projector-specific opcodes, the discovered mesh destination and a fresh packet sequence number.

The JavaScript and Python implementations perform the Telink login and packet encryption locally. No Bluetooth command or diagnostic report is sent to a remote application server.
