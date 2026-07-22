# Kitchenzky Sky Remote

A personal mobile remote for a BlissLights Sky Lite 2.0 projector. The project now has two editions: a native iPhone app using CoreBluetooth and a mobile Web Bluetooth version hosted on GitHub Pages.

No BlissLights app or remote application server is required. Bluetooth login, Telink packet encryption and projector commands are handled locally on the phone.

## Project editions

| Edition | Branch | Bluetooth transport | Best use |
| --- | --- | --- | --- |
| Native iPhone app | [`feature/native-ios`](https://github.com/kitchenzky/skylite-remote/tree/feature/native-ios) | Apple CoreBluetooth | Primary personal app; automatic reconnection and native background animation |
| Web app | [`main`](https://github.com/kitchenzky/skylite-remote/tree/main) | Web Bluetooth in Bluefy | Install-free fallback and GitHub Pages deployment |

**Live web app:** [kitchenzky.github.io/skylite-remote](https://kitchenzky.github.io/skylite-remote/)

The branches are intentionally separate. GitHub Pages deploys only `main`; native iOS development stays on `feature/native-ios` so Xcode and Capacitor files cannot disturb the stable web build.

## Features

- Direct Bluetooth Low Energy connection and Telink mesh login
- Remembers the selected projector
- Power control and connection-state feedback
- Ten presets, including four custom animated effects
- Manual red, green, blue and laser-dot selection
- Low, Medium and High brightness controls
- Independent rotation control
- Restores the selected output after connecting
- Full-screen diagnostic history with COPY, CLEAR and native sharing
- Responsive iPhone interface with local icons and assets
- No analytics, cloud account or application server

## Native iPhone app

The native edition is the recommended version for personal use. It keeps the existing interface while replacing Bluefy's Web Bluetooth layer with a Swift CoreBluetooth transport.

### Native advantages

- Reconnects automatically to the previously selected projector
- Does not show a browser Bluetooth chooser on every connection
- Keeps the Bluetooth session while the app moves to the background
- Runs Perfect Blue, Cosmic Pulse, RGB Pulse and Heartbeat from a native Swift animation engine
- Shares a complete diagnostic `.txt` report through the iOS Share Sheet, including AirDrop
- Uses an app icon baked into the installed application

iOS may eventually suspend or terminate any background app. Animated presets continue while the app is backgrounded and the Bluetooth session is retained, but force-quitting the app stops app-driven animation.

### Requirements

- A Mac with Xcode and iOS platform support installed
- An iPhone connected to the Mac
- An Apple ID added to Xcode
- Developer Mode enabled on the iPhone
- The projector nearby and not connected to the BlissLights app

A free Apple Personal Team is sufficient for private installation. Personal Team builds normally need to be rebuilt and reinstalled periodically when their development signing expires.

### Build and install

Clone the native branch:

```bash
git clone --branch feature/native-ios https://github.com/kitchenzky/skylite-remote.git skylite-remote-ios
cd skylite-remote-ios
npm install
npm run sync:ios
open ios/App/App.xcodeproj
```

In Xcode:

1. Select the **App** target.
2. Open **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Select your Personal Team.
5. Connect and select your iPhone as the run destination.
6. Press **Run**.

To install a later version, pull the native branch, run `npm run sync:ios`, then build and run from Xcode again.

### Native app icon

The source icon is stored at:

```text
ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png
```

Use a square 1024×1024 PNG without transparency. iOS applies the Home Screen corner shape automatically.

## Web app

The web edition is a static site and requires no build step. On iPhone it must be opened in a browser that implements Web Bluetooth; it has been tested with [Bluefy](https://apps.apple.com/app/bluefy-web-ble-browser/id1492822055). Safari does not provide the Web Bluetooth API required by this edition.

### Connect through Bluefy

1. Install Bluefy from the App Store.
2. Turn on Bluetooth and place the phone near the projector.
3. Fully close the BlissLights app on every nearby phone.
4. Open the [live web app](https://kitchenzky.github.io/skylite-remote/) inside Bluefy.
5. Tap the round Bluetooth button.
6. Select **BlissLights** if the chooser appears.
7. Wait for **Connected ✓**.

The web edition remembers an authorized device when Bluefy permits it. If the stored browser reference is stale, it falls back to the Bluetooth chooser.

Bluefy may suspend JavaScript or disconnect Bluetooth while inactive. The native edition is the solution for reliable background custom animations.

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
| RGB Pulse | Stacks and blends red, blue and green through smooth ten-second transitions, with two-second full-color holds and rotation enabled |
| Heartbeat | Two red nebula pulses over 1.2 seconds, followed by 2.8 seconds with the red nebula vanished; laser stars and rotation remain on throughout the four-second loop |

Custom animations continue through normal iOS backgrounding and stop safely when changing presets, tabs, power state or Bluetooth connection.

### Light Control

Opening **LIGHT CONTROL** switches from the current preset to the remembered custom configuration. Its initial state is:

- Red, green and blue enabled
- Laser dots enabled
- High brightness
- Rotation ON

Changes are sent as a complete projector state so brightness, colors, laser dots and rotation remain independent.

## Diagnostic Log

Tap the circled bug icon in the upper-right corner of the app.

- **Send** opens the native iOS Share Sheet and prepares a `.txt` report for AirDrop or another destination.
- **COPY** copies the complete report.
- **CLEAR** immediately removes only diagnostic history; projector settings and the remembered device are preserved.
- History rolls over at 240 events or approximately 80,000 characters.
- Passwords, session keys, pairing challenges and hardware identifiers are excluded or redacted.

For a clean report: **CLEAR → reproduce the problem once → Send or COPY**.

## Compatibility and device configuration

The project is confirmed with one BlissLights Sky Lite 2.0 using factory Telink mesh credentials. Telink packet encryption requires the projector's real hardware MAC address. The configured unit's address is stored as `REAL_MAC` in `index.html` and `skylite.html`.

To use another Sky Lite unit, determine its real Bluetooth MAC and update `REAL_MAC` in both files. A projector previously provisioned by another app may also need to be returned to its factory mesh credentials.

## Troubleshooting

### `Light rejected pairing (0xe)`

The projector is probably connected to, or provisioned by, the BlissLights app. Fully close that app on every nearby phone and retry.

If the error persists, a factory reset may be required. Hold the projector's top button until it flashes six times. This removes its existing app pairing and restores factory mesh credentials, so use it only when necessary.

### The projector is not found

- Move the phone closer to the projector.
- Make sure another phone or app is not connected.
- Unplug the projector briefly, reconnect power and retry.
- In Bluefy, close and reopen the browser before trying again.

### GitHub Pages shows an older build

Wait about a minute after pushing `main`, then reload the page in Bluefy. Native-branch commits do not trigger the Pages deployment.

## Web deployment

The web app is deployed from `main` and the repository root:

1. Open **Settings → Pages** in GitHub.
2. Choose **Deploy from a branch**.
3. Select `main` and `/ (root)`.
4. Open `https://<username>.github.io/<repository>/` after deployment completes.

`index.html` is the GitHub Pages entry point. `skylite.html` is kept as an identical standalone copy.

## Optional macOS command-line controller

The repository includes the original Python controller used to inspect and validate the protocol:

```bash
python3 -m pip install -r requirements.txt
python3 scan_devices.py
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

## Repository layout

Files shared by both editions:

- `index.html` — interface and application logic
- `skylite.html` — identical standalone copy
- `manifest.json` and `icon.svg` — web home-screen metadata and icon
- `control.py`, `telink_mesh.py` and `scan_devices.py` — optional Python controller

Additional files on `feature/native-ios`:

- `ios/App/App.xcodeproj` — native Xcode project
- `ios/App/App/SkyBluetoothPlugin.swift` — CoreBluetooth and native animation engine
- `ios/App/App/SkySharePlugin.swift` — diagnostic file sharing
- `capacitor.config.json` — native shell configuration
- `scripts/prepare-native.mjs` — prepares local web assets for Capacitor
- `package.json` — native sync commands and Capacitor dependencies

## Protocol and privacy

The projector uses a Telink TLSR8250 BLE mesh. Commands require mesh login, the real hardware MAC as encryption input, projector-specific opcodes, the discovered mesh destination and fresh packet sequence numbers.

The JavaScript, Swift and Python implementations perform login and encryption locally. No Bluetooth command or diagnostic report is automatically sent to a remote server.
