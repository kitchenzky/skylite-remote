"""
control.py

Command-line controller for the BlissLights Sky Lite 2.0, talking
directly over Bluetooth LE (no app required). See telink_mesh.py for
the protocol implementation and important caveats (especially around
macOS hiding the real Bluetooth MAC address).

Usage:
    python control.py <address> on [--mac AABBCCDDEEFF] [--mac-order as-is|reversed]
    python control.py <address> off [--mac ...]
    python control.py <address> scene <id> [--mac ...]     # id from `scenes` list
    python control.py <address> color <r> <g> <b> [bright 0-255] [laser 0-255] [motor 0-255] [--mac ...]
    python control.py <address> scenes        # lists the built-in presets

<address> is whatever scan_devices.py printed for the light (on macOS
this will look like a UUID, not a MAC -- that's expected).

--mac is the light's REAL Bluetooth MAC, if you found one hiding in its
advertisement data via scan_devices.py (12 hex characters, no colons
needed). This is required for commands to actually work on a Mac.

Example:
    python control.py 1A2B3C4D-1234-5678-9ABC-1234567890AB on --mac 1102d1605a38
    python control.py 1A2B3C4D-1234-5678-9ABC-1234567890AB scene 10 --mac 1102d1605a38
"""

import asyncio
import sys

from telink_mesh import TelinkMeshLight, KNOWN_SCENES


def _extract_flag(args, flag, default=None):
    if flag in args:
        idx = args.index(flag)
        value = args[idx + 1]
        del args[idx : idx + 2]
        return value
    return default


async def main():
    args = sys.argv[1:]
    real_mac = _extract_flag(args, "--mac")
    mac_order = _extract_flag(args, "--mac-order", "as-is")
    # Default to 0xFFFF = mesh broadcast ("all nodes"). Telink firmware
    # reliably acts on broadcast-addressed vendor commands, whereas dst=0
    # ("the node I'm directly connected to") is honored inconsistently.
    dst_str = _extract_flag(args, "--dst", "0xffff")
    dst = int(dst_str, 0)  # accepts "0", "65535", or "0xffff"

    if len(args) < 2:
        print(__doc__)
        sys.exit(1)

    address = args[0]
    action = args[1].lower()

    if action in ("scenes", "presets"):
        print("Built-in Sky Lite presets (from the app's own resources):")
        for sid, desc in KNOWN_SCENES.items():
            print(f"  {sid:2d}: {desc}")
        print("\nUse:  python control.py <address> scene <id> --mac <MAC>")
        return

    light = TelinkMeshLight(address, real_mac_hex=real_mac, mac_byte_order=mac_order, dst=dst)
    try:
        await light.connect()

        if action == "on":
            await light.set_power(True)
        elif action == "off":
            await light.set_power(False)
        elif action in ("scene", "preset"):
            scene_id = int(args[2], 0)
            await light.load_scenario(scene_id)
        elif action == "color":
            r, g, b = int(args[2]), int(args[3]), int(args[4])
            brightness = int(args[5]) if len(args) > 5 else 255
            laser = int(args[6]) if len(args) > 6 else 0
            motor = int(args[7]) if len(args) > 7 else 0
            await light.set_color(r, g, b, brightness, laser, motor)
        else:
            print(f"Unknown action: {action}")
            print(__doc__)
            sys.exit(1)

        # give the light a moment to react + send back any notification
        await asyncio.sleep(1.5)

    finally:
        await light.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
