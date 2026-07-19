"""
telink_mesh.py

A from-scratch Python (bleak/asyncio) port of the Telink Bluetooth Mesh
protocol, written for the BlissLights Sky Lite 2.0 galaxy projector.

Why this exists
----------------
The official BlissLights app was pulled from the App Store / Google Play.
The Sky Lite 2.0 uses a generic Telink Semiconductor BLE mesh chip
(TLSR8250) under the hood, and BlissLights' own app never changed the
factory default mesh credentials. This lets us talk to the light directly.

This implementation is NOT guesswork about the crypto -- it's a faithful
port of two independent, previously-working open-source implementations
of the *generic* Telink mesh protocol that agree with each other byte for
byte:

  - google/python-dimond (Apache-2.0) -- Python, uses bluepy (Linux-only)
  - vpaeder/telinkpp (GPL-3.0)        -- C++, uses TinyB

Both were cross-checked against real packet captures posted in a Home
Assistant community thread reverse-engineering this exact device
(https://community.home-assistant.io/t/reverse-engineering-blisslights-2-0-bluetooth-star-projector/387349)
-- the packet-counter byte pattern in the captured ciphertext lines up
exactly with what build_packet() below produces.

Known credentials (from a teardown of the BlissLights Android APK,
posted in the same thread -- file com/quhwa/mesh/constant/Constant.java):

    TELINK_MESH_FACTORY = "telink_mesh0"
    MESH_PASSWORD       = "123"

These are also literally Telink's documented factory defaults, so it's
unsurprising BlissLights never bothered to change them.

IMPORTANT CAVEAT -- read before running on a Mac
--------------------------------------------------
The encryption scheme mixes in the device's raw Bluetooth hardware MAC
address (not just as an identifier, but as literal key material for the
per-packet nonce/IV). On Linux (BlueZ), bleak exposes the *real* MAC.
On macOS (CoreBluetooth), Apple deliberately hides the real MAC and
gives you a random per-machine UUID instead. That UUID will NOT work
as a substitute for the real MAC in this protocol.

Practically, this means:
  - Pairing (establishing the shared session key) does NOT need the MAC
    and should work fine on a Mac.
  - Sending actual commands (on/off, scenes) DOES need the MAC, and may
    silently fail to affect the light on a Mac, even though the write
    call itself succeeds without an error.

If that happens, don't panic -- it doesn't mean the whole approach is
wrong, it means we need the real MAC from somewhere else (see
scan_devices.py's advertisement dump, or run this same script on Linux/
a Raspberry Pi where bleak reports the real MAC directly).
"""

from __future__ import annotations

import asyncio
import random
import sys
from dataclasses import dataclass

from Crypto.Cipher import AES
from bleak import BleakClient, BleakScanner

# --- GATT UUIDs -------------------------------------------------------
# Confirmed independently by: the HA forum thread's nRF Connect sniffing
# (which found short IDs 1911/1912/1913/1914) AND telinkpp's hardcoded
# full 128-bit UUIDs. Same device family, same UUID base.
UUID_INFO_SERVICE = "00010203-0405-0607-0809-0a0b0c0d1910"
UUID_NOTIFICATION = "00010203-0405-0607-0809-0a0b0c0d1911"
UUID_COMMAND = "00010203-0405-0607-0809-0a0b0c0d1912"
UUID_OTA = "00010203-0405-0607-0809-0a0b0c0d1913"
UUID_PAIR = "00010203-0405-0607-0809-0a0b0c0d1914"

# --- BlissLights/Quhwa command scheme (from decompiling the real APK,
# class com/quhwa/mesh/lightstrip/StripCmdManager.java) -----------------
# Unlike generic Telink demo firmware (which spreads functionality across
# many outer command codes like 0xF0/0xF1/0xF2), BlissLights' firmware
# routes EVERYTHING through a single outer command, 0xF0, and encodes the
# actual action as the FIRST BYTE of the 10-byte data payload. This was
# invisible from the encrypted BLE traffic alone -- only decompiling the
# app's Java bytecode revealed it (all of StripCmdManager's methods call
# TelinkLightService.sendCommandNoResponse(-16, deviceId, data), and -16
# as a signed byte is 0xF0 unsigned).
COMMAND_OUTER = 0xF0  # every command below is wrapped in this

# Sub-command byte = data[0] within that 0xF0-wrapped payload.
#
# CRITICAL: the Sky Lite 2.0 star PROJECTOR and the BlissGlow LED STRIP
# use DIFFERENT sub-commands for the same actions. This was confirmed by
# decompiling Fra_MainHome.sendCmdOnOff(), which branches on
# StripUtils.isStrip(devType):
#     projector (NOT strip):  data = {0x41, state, 0x01}
#     strip:                  data = {0x16, state, 0x01}
# We were previously sending the STRIP on/off (0x16), which the projector
# silently ignores. The projector's real on/off sub-command is 0x41.
SUBCMD_PROJECTOR_ON_OFF = 0x41   # data=[0x41, state(0/1), 0x01]  -- Sky Lite
SUBCMD_PROJECTOR_CONTROL = 0x47  # data=[0x47, R,G,B, laser, motor, bright, breathe]
SUBCMD_STRIP_ON_OFF = 0x16       # data=[0x16, state(0/1), 0x01]  -- LED strip only

SUBCMD_SWITCH_SCENE = 0x11  # data=[0x11, scene_id]
SUBCMD_SET_COLOR = 0x12  # data=[0x12, index, p, R, G, B, speed?, 0, mode?, 0]
SUBCMD_SET_TIMER = 0x13  # data=[0x13, on_hour, off_hour, ...]
SUBCMD_SET_RHYTHM_COLOR = 0x14
SUBCMD_TURN_ON_OFF = 0x16  # (legacy alias; strip on/off)
SUBCMD_SET_DIY_SEGMENT = 0x17
SUBCMD_SET_DIY_OVERALL = 0x18
SUBCMD_SAVE_DIY = 0x19
SUBCMD_GET_TIMER_MODE = 0x1B
SUBCMD_GET_DEVICE_VERSION = 0x1C

# Kept for reference / fallback experimentation -- NOT what BlissLights
# actually uses, but harmless to leave defined in case a future finding
# changes the picture.
COMMAND_LIGHT_ON_OFF = 0xF0
COMMAND_LIGHT_ATTRIBUTES_SET = 0xF1
COMMAND_SCENARIO_LOAD = 0xF2
COMMAND_SCENARIO_EDIT = 0xF3
COMMAND_SCENARIO_QUERY = 0xC0
COMMAND_SCENARIO_REPORT = 0xC1
COMMAND_STATUS_QUERY = 0xDA
COMMAND_STATUS_REPORT = 0xDB
COMMAND_ONLINE_STATUS_REPORT = 0xDC

DEFAULT_MESH_NAME = "telink_mesh0"
DEFAULT_MESH_PASSWORD = "123"
DEFAULT_VENDOR = 0x0211  # Telink's own default vendor code

# From the UART debug capture in the HA forum thread (someone soldered
# into the light's serial debug pins). Pressing the physical top button
# cycles through firmware-resident "scenes" with these exact R,G,B,
# Laser,Motor values. Scene IDs are almost certainly what
# COMMAND_SCENARIO_LOAD's scenario_id selects.
# The Sky Lite 2.0's real built-in effects, extracted from the app's own
# resource arrays (scene_id_list / scene_name_list). These are the exact
# presets shown in the app's Effect menu, with their real firmware IDs.
KNOWN_SCENES = {
    1: "Stars against nebula",
    2: "Fading",
    3: "Stars",
    4: "Nebula",
    5: "Ocean",
    6: "Space",
    8: "Sunrise",
    9: "RGB auto",
    0: "ON/OFF (manual color mode)",
}


def _reverse(b: bytes) -> bytes:
    return bytes(reversed(b))


def _aes_ecb_reversed(key: bytes, data: bytes) -> bytes:
    """The Telink mesh crypto primitive: AES-128-ECB, but with both the
    key and the 16-byte data block byte-reversed before encryption, and
    the result reversed again afterwards. This quirk is present
    identically in both python-dimond and telinkpp, so it's not a bug --
    it's how the actual chip firmware does it. Confirmed against the
    decompiled real app: this matches com.telink.crypto.AES.aes_att_encryption()."""
    cipher = AES.new(_reverse(key), AES.MODE_ECB)
    encrypted = cipher.encrypt(_reverse(data))
    return _reverse(encrypted)


def _aes_ecb_no_final_reverse(key: bytes, data: bytes) -> bytes:
    """Matches the real app's com.telink.crypto.AES.encrypt(key, data)
    2-arg form: reverse(key) + reverse(data) -> AES-ECB encrypt, but
    WITHOUT reversing the result afterwards (unlike _aes_ecb_reversed /
    aes_att_encryption above). Confirmed from decompiling AES.java --
    getSessionKey() and login() both use this exact variant, and mixing
    it up with the always-reverses version was the root cause of the
    pairing packet being built wrong."""
    cipher = AES.new(_reverse(key), AES.MODE_ECB)
    return cipher.encrypt(_reverse(data))


def _pad16(s: bytes) -> bytes:
    return s + b"\x00" * (16 - len(s))


class TelinkMeshLight:
    def __init__(
        self,
        address: str,
        mesh_name: str = DEFAULT_MESH_NAME,
        mesh_password: str = DEFAULT_MESH_PASSWORD,
        vendor: int = DEFAULT_VENDOR,
        real_mac_hex: str | None = None,
        mac_byte_order: str = "as-is",
        dst: int = 0,
    ):
        self.address = address
        self.mesh_name = _pad16(mesh_name.encode())
        self.mesh_password = _pad16(mesh_password.encode())
        self.vendor = vendor & 0xFFFF
        self.dst = dst & 0xFFFF
        self.discovered_addr = None  # filled in from online-status notifications
        # Match the real app: it seeds sequenceNumber to Integer.MAX_VALUE,
        # which on first use resets to a RANDOM 24-bit value (1..16777215).
        # Starting at 1 (as we did before) makes commands look like stale
        # replays to the light's firmware, which silently drops them --
        # this was why perfectly-formed commands had no visible effect.
        self.packet_count = random.randint(1, 0xFFFFFE)
        self.shared_key = None
        self.client: BleakClient | None = None

        # See module docstring's MAC caveat. Preferred path: the device's
        # BLE advertisement leaked its own real MAC in manufacturer data
        # (spotted via scan_devices.py -- look for 6 bytes appearing
        # right before/near an ASCII "addr" marker). Pass it in as
        # real_mac_hex, e.g. "1102d1605a38". mac_byte_order controls
        # whether we use those bytes as-is or reversed -- try "as-is"
        # first, and "reversed" if commands don't take effect.
        if real_mac_hex:
            mac_bytes = bytes.fromhex(real_mac_hex.replace(":", "").replace(" ", ""))
            if len(mac_bytes) != 6:
                raise ValueError(f"real_mac_hex must be 6 bytes (12 hex chars), got {len(mac_bytes)}")
            if mac_byte_order == "reversed":
                mac_bytes = bytes(reversed(mac_bytes))
            self.reverse_mac = bytes(reversed(mac_bytes))
            print(f"Using explicit real MAC {mac_bytes.hex()} (order={mac_byte_order}) for crypto.")
        else:
            self.reverse_mac = self._derive_reverse_mac(address)

    @staticmethod
    def _derive_reverse_mac(address: str) -> bytes:
        parts = address.split(":")
        if len(parts) == 6 and all(len(p) == 2 for p in parts):
            mac_bytes = bytes(int(p, 16) for p in parts)
            return bytes(reversed(mac_bytes))
        print(
            "WARNING: '%s' doesn't look like a real BLE MAC address "
            "(colon-separated hex). This is expected on macOS, which "
            "hides the real MAC. Falling back to 00:00:00:00:00:00 -- "
            "pairing should still work, but command packets may be "
            "silently rejected by the light. Pass --mac to control.py "
            "if you know the real MAC (see scan_devices.py output)." % address
        )
        return b"\x00" * 6

    def _combine_name_and_password(self) -> bytes:
        return bytes(a ^ b for a, b in zip(self.mesh_name, self.mesh_password))

    def _key_encrypt(self, key: bytes) -> bytes:
        data = self._combine_name_and_password()
        return _aes_ecb_reversed(key, data)

    def _generate_shared_key(self, data1: bytes, data2: bytes) -> bytes:
        key = self._combine_name_and_password()
        data = data1[:8] + data2[:8]
        return _aes_ecb_reversed(key, data)

    def _encrypt_packet(self, packet: bytearray) -> bytearray:
        auth_nonce = bytearray(16)
        auth_nonce[0:4] = self.reverse_mac[0:4]
        auth_nonce[4] = 0x01
        auth_nonce[5:8] = packet[0:3]
        auth_nonce[8] = 0x0F
        # bytes 9-15 stay zero

        authenticator = bytearray(_aes_ecb_reversed(self.shared_key, bytes(auth_nonce)))
        for i in range(15):
            authenticator[i] ^= packet[i + 5]

        mac = _aes_ecb_reversed(self.shared_key, bytes(authenticator))
        packet[3] = mac[0]
        packet[4] = mac[1]

        iv = bytearray(16)
        iv[1:5] = self.reverse_mac[0:4]
        iv[5] = 0x01
        iv[6:9] = packet[0:3]
        # bytes 9-15 stay zero

        stream = _aes_ecb_reversed(self.shared_key, bytes(iv))
        for i in range(15):
            packet[i + 5] ^= stream[i]

        return packet

    def _decrypt_packet(self, packet: bytearray) -> bytearray:
        # Ported EXACTLY from the decompiled LightController.onNotify +
        # AES.decrypt(3-arg). getSecIVS(macBytes) = mac[0:3]+zeros, then
        # nonceSource[3:8] = packet[0:5], then the keystream block is
        # aes_att_encryption(key, 0x00 + nonceSource + zeros). Our earlier
        # version was missing that leading 0x00 byte, so it produced
        # garbage plaintext (which is why decoded notifications looked
        # nonsensical). packet[7:20] is the encrypted region.
        nonce_source = bytearray(8)
        nonce_source[0:3] = self.reverse_mac[0:3]
        nonce_source[3:8] = packet[0:5]

        block_in = bytearray(16)
        block_in[1:9] = nonce_source  # note the leading 0x00 at index 0
        stream = _aes_ecb_reversed(self.shared_key, bytes(block_in))

        out = bytearray(packet)
        for i in range(len(packet) - 7):
            out[i + 7] ^= stream[i & 15]
        return out

    def _build_packet(self, command: int, data: bytes) -> bytearray:
        packet = bytearray(20)
        # 24-bit little-endian sequence number (the app uses all 3 bytes;
        # we previously only wrote 2, which combined with starting at 1
        # made packets look like replays).
        packet[0] = self.packet_count & 0xFF
        packet[1] = (self.packet_count >> 8) & 0xFF
        packet[2] = (self.packet_count >> 16) & 0xFF
        self.packet_count += 1
        if self.packet_count > 0xFFFFFF:
            self.packet_count = 1
        # dst/mesh target id. Per Telink SDK convention 0 = "the device
        # I'm directly GATT-connected to" and 0xFFFF = "broadcast to
        # everything on the mesh". Some custom firmware doesn't honor
        # the "0 = self" shortcut, so this is configurable for testing.
        # Prefer the address the light told us about in its online-status
        # report (self.discovered_addr) over whatever default/broadcast dst
        # we were configured with -- addressing the node directly is the
        # most reliable way to get it to act.
        effective_dst = self.discovered_addr if self.discovered_addr is not None else self.dst
        packet[5] = effective_dst & 0xFF
        packet[6] = (effective_dst >> 8) & 0xFF
        packet[7] = command & 0xFF
        packet[8] = self.vendor & 0xFF
        packet[9] = (self.vendor >> 8) & 0xFF
        for i, b in enumerate(data[:10]):
            packet[10 + i] = b
        return self._encrypt_packet(packet)

    async def connect(self):
        print(f"Connecting to {self.address} ...")
        self.client = BleakClient(self.address)
        await self.client.connect()
        if not self.client.is_connected:
            raise RuntimeError("BLE connect() reported failure")
        print("BLE link established. Starting mesh login handshake...")

        import os

        # Ported EXACTLY from the decompiled login() method
        # (com.telink.bluetooth.light.LightController). Our earlier
        # version had the AES key/data arguments swapped here (used
        # combined_key as the AES key and our random as the data --
        # backwards from what the real app does), which meant the
        # "proof of credentials" value we sent the device could never
        # match what it expected, regardless of mesh name/password being
        # right. That's the most likely reason pairing was flaky/rejected.
        our_random = os.urandom(8)
        combined = self._combine_name_and_password()  # v2_1
        key_material = our_random + b"\x00" * 8  # v4_0: KEY for this AES call
        # v2_0 = AES.encrypt(key=v4_0, data=v2_1) -- note key/data order
        v2_0 = _aes_ecb_no_final_reverse(key_material, combined)
        # real code reverses all 8 of v2_0[8:16] before sending
        enc_tail = bytes(reversed(v2_0[8:16]))
        pairing_packet = bytes([0x0C]) + our_random + enc_tail

        await self.client.write_gatt_char(UUID_PAIR, pairing_packet, response=True)
        await asyncio.sleep(0.3)
        response = await self.client.read_gatt_char(UUID_PAIR)
        print(f"Pairing response (raw): {bytes(response).hex()}")

        # From the real Telink SDK (LightController$LoginCommandCallback):
        # if response[0] == Opcode.BLE_GATT_OP_PAIR_ENC_FAIL (0x0E), the
        # device rejected our mesh name/password outright -- this is the
        # ground-truth signal for "wrong credentials", straight from the
        # official app's own logic, not a guess. Check this BEFORE the
        # length check -- a real rejection can come back as just this
        # single byte with no trailing data, which isn't itself an error.
        if len(response) >= 1 and response[0] == 0x0E:
            raise RuntimeError(
                "*** DEVICE REJECTED OUR MESH NAME/PASSWORD (response byte 0 "
                "= 0x0E, BLE_GATT_OP_PAIR_ENC_FAIL). This means "
                f"'{self.mesh_name.rstrip(chr(0).encode())}' / "
                f"'{self.mesh_password.rstrip(chr(0).encode())}' are NOT the "
                "credentials this specific device is currently using right "
                "now. Try again after fully closing any other app/phone "
                "connected to the light -- Telink mesh peripherals only "
                "allow one connection at a time and can send this rejection "
                "if something else has an active or stale connection. ***"
            )

        if len(response) < 9:
            raise RuntimeError(
                f"Pairing response too short ({len(response)} bytes) -- "
                "device may not be in a pairable state, or this isn't a "
                "Telink mesh device."
            )

        print(f"Pairing accepted (response byte 0 = 0x{response[0]:02X}, not a rejection).")

        self.shared_key = self._generate_shared_key(our_random, response[1:9])
        print("Mesh login handshake complete -- shared session key derived.")

        await self.client.start_notify(UUID_NOTIFICATION, self._on_notify)
        await self.client.write_gatt_char(UUID_NOTIFICATION, bytes([0x01]), response=True)
        # Give the light a moment to push its online-status report, which
        # tells us its real mesh address (see _on_notify).
        await asyncio.sleep(1.0)

    def _on_notify(self, _sender, data: bytearray):
        try:
            decrypted = self._decrypt_packet(bytearray(data))
            src = decrypted[5] | (decrypted[6] << 8)
            opcode = decrypted[7]
            params = bytes(decrypted[10:20])
            print(
                f"[notify] decrypted={bytes(decrypted).hex()} "
                f"src_addr=0x{src:04X} opcode=0x{opcode:02X} params={params.hex()}"
            )
            # For an online-status report (opcode 0xDC) the payload carries
            # the device's own mesh address. Per the decompiled
            # OnlineStatusNotificationParser, this is a SINGLE byte at
            # params[0] (not two), e.g. 0xD1.
            if opcode in (0xDC, 0xDB):
                dev_addr = params[0]
                if dev_addr not in (0, 0xFF):
                    self.discovered_addr = dev_addr
                    print(f"[notify] --> light reports its mesh address = 0x{dev_addr:02X} ({dev_addr})")
        except Exception as e:
            print(f"[notify] failed to decrypt: {e}, raw={bytes(data).hex()}")

    async def send_packet(self, command: int, data: bytes = b""):
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("Not connected -- call connect() first")
        packet = self._build_packet(command, data)
        # IMPORTANT: confirmed via a real PacketLogger capture of the
        # actual working BlissLights app -- it writes command packets
        # using ATT "Write Command" (opcode 0x52, write WITHOUT response),
        # never "Write Request" (0x12). bleak's response=True maps to
        # Write Request. The device's generic BLE/GATT stack happily ACKs
        # a Write Request at the protocol level (no error raised here),
        # but the firmware's actual command parser apparently is only
        # wired to "write command" events on this characteristic -- so a
        # Write Request silently never reaches the code that controls the
        # light, even though it "succeeds". This was the most likely
        # explanation for "no error, but nothing happens."
        effective_dst = self.discovered_addr if self.discovered_addr is not None else self.dst
        await self.client.write_gatt_char(UUID_COMMAND, bytes(packet), response=False)
        print(f"Sent command=0x{command:02X} data={data.hex()} to dst=0x{effective_dst:04X} -> {bytes(packet).hex()} (write-without-response)")

    async def set_power(self, on: bool):
        # Ported from Fra_MainHome.sendCmdOnOff() -- the PROJECTOR branch
        # (StripUtils.isStrip(devType) == false):
        #   byte[] v2 = new byte[3];
        #   v2[0] = 65;   // 0x41  <-- projector on/off, NOT the strip's 0x16
        #   v2[1] = p8;   // state, 0 = off / 1 = on
        #   v2[2] = 1;
        #   sendCommandNoResponse(-16 /* 0xF0 */, meshAddress, v2);
        await self.send_packet(COMMAND_OUTER, bytes([SUBCMD_PROJECTOR_ON_OFF, 1 if on else 0, 0x01]))

    async def load_scenario(self, scenario_id: int, speed: int = 0, brightness: int = 100):
        # Ported from Fra_MainHome.sendCmdChangeSec() -- PROJECTOR branch:
        #   byte[] v2 = new byte[3];
        #   v2[0] = 65;        // 0x41  (same outer sub-cmd as on/off!)
        #   v2[1] = sceneId;
        #   v2[2] = 0;         // <-- 0 here means "switch effect"; on/off
        #                      //     uses 0x01 in this slot instead.
        #   sendCommandNoResponse(-16, meshAddress, v2);
        await self.send_packet(
            COMMAND_OUTER, bytes([SUBCMD_PROJECTOR_ON_OFF, scenario_id & 0xFF, 0x00])
        )

    async def set_color(
        self,
        r: int,
        g: int,
        b: int,
        brightness: int = 255,
        laser: int = 0,
        motor: int = 0,
        breathe: int = 0,
    ):
        # Ported from Fra_MainHome.sendCmdControlLED() -- the projector's
        # real manual-control command:
        #   byte[] v1 = new byte[8];
        #   v1[0] = 71;   // 0x47
        #   v1[1] = red; v1[2] = green; v1[3] = blue;
        #   v1[4] = laser;   // green laser dots intensity
        #   v1[5] = motor;   // rotation speed
        #   v1[6] = bright;  // overall brightness
        #   v1[7] = breathe; // breathing effect on/off
        #   sendCommandNoResponse(-16, meshAddress, v1);
        data = bytes(
            [
                SUBCMD_PROJECTOR_CONTROL,
                r & 0xFF,
                g & 0xFF,
                b & 0xFF,
                laser & 0xFF,
                motor & 0xFF,
                brightness & 0xFF,
                breathe & 0xFF,
            ]
        )
        await self.send_packet(COMMAND_OUTER, data)

    async def disconnect(self):
        if self.client is not None:
            await self.client.disconnect()


async def find_device(timeout: float = 8.0):
    """Scan for any BLE device advertising the Telink mesh info service."""
    print(f"Scanning for {timeout}s for Telink mesh devices...")
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    candidates = []
    for address, (device, adv) in devices.items():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        if UUID_INFO_SERVICE.lower() in uuids:
            candidates.append(device)
            print(f"  FOUND candidate: {device.name!r} @ {device.address} (rssi={adv.rssi})")
    if not candidates:
        print(
            "  No devices advertising the Telink mesh service UUID were found.\n"
            "  Some BLE stacks don't surface service UUIDs in scan responses --\n"
            "  try scan_devices.py for a full dump of everything nearby instead."
        )
    return candidates


if __name__ == "__main__":
    async def main():
        candidates = await find_device()
        if not candidates:
            sys.exit(1)
        light = TelinkMeshLight(candidates[0].address)
        await light.connect()
        print("\nConnected + paired. Try: python control.py <address> on")

    asyncio.run(main())
