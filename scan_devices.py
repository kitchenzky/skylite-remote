"""
scan_devices.py

Run this FIRST. It scans for all nearby BLE devices and prints everything
bleak can see about each one: name, address (as your OS reports it),
RSSI, advertised service UUIDs, and raw manufacturer/service data.

Two things we're hunting for here:

1. The Sky Lite 2.0 itself -- it should show up advertising the Telink
   mesh info service UUID (00010203-0405-0607-0809-0a0b0c0d1910), or at
   minimum with a recognizable name. Turn the light on/off or hold the
   button to make it advertise if it doesn't show up immediately.

2. Its REAL Bluetooth MAC address. On macOS, bleak/CoreBluetooth hides
   this and gives you a random per-machine UUID instead as the
   "address" -- but occasionally devices leak their real MAC inside
   manufacturer-specific advertising data, which this script dumps in
   full so we can go looking. This matters because telink_mesh.py's
   encryption scheme needs the real MAC as key material; without it,
   pairing will work but commands may not.

Usage:
    pip install bleak --break-system-packages   # if not already installed
    python scan_devices.py
"""

import asyncio
from bleak import BleakScanner


async def main():
    print("Scanning for 10 seconds... (turn the Sky Lite off and on, or hold")
    print("its button, if it doesn't show up)\n")
    devices = await BleakScanner.discover(timeout=10.0, return_adv=True)

    if not devices:
        print("No BLE devices found at all -- check Bluetooth is on.")
        return

    for address, (device, adv) in devices.items():
        print("=" * 70)
        print(f"Name:      {device.name!r}")
        print(f"Address:   {device.address}")
        print(f"RSSI:      {adv.rssi}")
        print(f"Services:  {adv.service_uuids}")
        if adv.manufacturer_data:
            print("Manufacturer data:")
            for company_id, data in adv.manufacturer_data.items():
                print(f"  0x{company_id:04X}: {data.hex()}  (len={len(data)})")
        if adv.service_data:
            print("Service data:")
            for uuid, data in adv.service_data.items():
                print(f"  {uuid}: {data.hex()}  (len={len(data)})")
    print("=" * 70)
    print(
        "\nLook for an entry whose name mentions the light (or that appeared\n"
        "only after you power-cycled it), and check whether the info service\n"
        "UUID 00010203-0405-0607-0809-0a0b0c0d1910 shows up in its Services\n"
        "list -- that's the strongest signal it's the Sky Lite.\n"
        "\n"
        "Paste this entire output back so we can pick the right device and\n"
        "check whether a real MAC address is hiding in the manufacturer/\n"
        "service data."
    )


if __name__ == "__main__":
    asyncio.run(main())
