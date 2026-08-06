#!/usr/bin/env python3
"""
HitmanVRFoveationFix for Linux/Proton (experimental port of v1.2).

Run this BEFORE starting HITMAN World of Assassination, then leave it running.
It patches the Windows HITMAN3.exe process in memory through /proc/<pid>/mem.
Nothing is modified on disk. Closing the tool restores the bytes when possible.

This port retains the original project's verified RVAs, byte signatures, device
layout checks, and restore behaviour. Linux-specific process access and status
output replace Win32 APIs and WinForms.
"""

from __future__ import annotations

import argparse
import atexit
import datetime as dt
import os
import signal
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

VERSION = "1.2-linux-exp1"

# Verified Windows build 3.270.1
VERIFIED_TIMESTAMP = 1781013974
MANAGER_RVA = 0x03225D20
MANAGER_VTABLE_RVA = 0x01EF5398
MANAGER_DEVICE_OFFSET = 0x141A0
OCULUS_VTABLE_RVA = 0x01F016C0
OPENVR_VTABLE_RVA = 0x01EFE020
VERIFIED_WNO_OFF = 0x31B

@dataclass
class Site:
    rva: int
    stock: Optional[bytes]
    fix: bytes
    what: str = ""

VERIFIED_CODE = [
    Site(0x011D8B9E, bytes.fromhex("0F 94 C1"), bytes.fromhex("B1 00 90")),
    Site(0x011D8BC1, bytes.fromhex("0F 94 C0"), bytes.fromhex("B0 00 90")),
    Site(0x012C1EAC, bytes.fromhex("0F B6 87 1B 03 00 00"), bytes.fromhex("B8 01 00 00 00 90 90")),
    Site(0x012499CC, bytes.fromhex("0F B6 87 1B 03 00 00"), bytes.fromhex("B8 01 00 00 00 90 90")),
    Site(0x01161FE9, bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90")),
]

SIGS = [
    (9, bytes.fromhex("B1 00 90"), "8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00", "two layers instead of four (writer A)"),
    (9, bytes.fromhex("B0 00 90"), "8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00", "two layers instead of four (writer B)"),
    (44, bytes.fromhex("B8 01 00 00 00 90 90"), "C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00", "full field of view, Oculus device"),
    (44, bytes.fromhex("B8 01 00 00 00 90 90"), "50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00", "full field of view, OpenVR device"),
    (12, bytes.fromhex("48 85 E4 90 90 90 90"), "74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF", "view count 4; geometry fix"),
]
SIG_DEVICE_PAT = "48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"
SIG_DEVICE_REL = 3
SIG_DEVICE_DSP = 15

OFF_ACTIVE = 0x319
OFF_TRANS = 0x4D8
OFF_W = 0x510
OFF_H = 0x514
OFF_LAYERS = 0x520
OFF_TEX = 0x530
OFF_FOV = 0x420
OFF_SCALE = 0x490
OFF_MASK = 0x4C0
SCALE_FIX = struct.pack("<4I", 0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000)
SCALE_STOCK = struct.pack("<4I", 0x3EDF2BF0, 0x3ECE8B44, 0x4012D426, 0x401EA625)
MASK_FIX = bytes.fromhex("00 00 00 00 00 00 00 00")
MASK_STOCK = bytes.fromhex("3D 2D 66 3F DA B9 4D 3E")

class FixError(RuntimeError):
    pass

class LinuxFix:
    def __init__(self, names: list[str], interval: float, log_path: Path):
        self.names = [n.lower() for n in names]
        self.interval = interval
        self.log_path = log_path
        self.pid = 0
        self.mem_fd: Optional[int] = None
        self.base = 0
        self.exe_path: Optional[Path] = None
        self.mode = ""
        self.sites: list[Site] = []
        self.dev_slot = 0
        self.wno_off = OFF_ACTIVE
        self.patched = False
        self.dev = 0
        self.tex = 0
        self.vals_ok = False
        self.need_reload = False
        self.scale_stock: Optional[bytes] = None
        self.mask_stock: Optional[bytes] = None
        self.last_status = ""
        self.running = True

    def log(self, text: str) -> None:
        try:
            stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(f"{stamp}  {text}\n")
        except OSError:
            pass

    def status(self, state: str, body: str = "") -> None:
        msg = f"[{state}] {body}" if body else f"[{state}]"
        if msg != self.last_status:
            print(msg, flush=True)
            self.last_status = msg

    @staticmethod
    def _read_text(path: Path) -> str:
        try:
            return path.read_text(errors="replace")
        except OSError:
            return ""

    def find_processes(self) -> list[int]:
        found: list[int] = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            pid = int(entry.name)
            comm = self._read_text(entry / "comm").strip().lower()
            try:
                cmd = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").lower()
            except OSError:
                cmd = ""
            if any(name == comm or name in cmd for name in self.names):
                found.append(pid)
        return found

    @staticmethod
    def parse_maps(pid: int) -> list[tuple[int, int, str, int, str]]:
        rows = []
        with open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split(None, 5)
                if len(parts) < 5:
                    continue
                start_s, end_s = parts[0].split("-", 1)
                path = parts[5] if len(parts) == 6 else ""
                rows.append((int(start_s, 16), int(end_s, 16), parts[1], int(parts[2], 16), path))
        return rows

    def locate_module(self, pid: int) -> tuple[int, Path]:
        candidates = []
        for start, _end, _perms, offset, path in self.parse_maps(pid):
            low = path.lower()
            if not path or not any(low.endswith("/" + n) or low.endswith(n) for n in self.names):
                continue
            candidates.append((start, offset, Path(path.replace("\\040", " "))))
        if not candidates:
            raise FixError("Could not locate HITMAN3.exe in the process memory map.")
        zero = [c for c in candidates if c[1] == 0]
        start, _offset, path = min(zero or candidates, key=lambda c: c[0])
        return start, path

    def rb(self, address: int, size: int) -> bytes:
        if self.mem_fd is None:
            raise FixError("Process memory is not open.")
        try:
            data = os.pread(self.mem_fd, size, address)
        except OSError as e:
            raise FixError(f"Read failed at 0x{address:X}: {e.strerror}") from e
        if len(data) != size:
            raise FixError(f"Short read at 0x{address:X}: expected {size}, got {len(data)}")
        return data

    def wb(self, address: int, data: bytes) -> None:
        if self.mem_fd is None:
            raise FixError("Process memory is not open.")
        try:
            written = os.pwrite(self.mem_fd, data, address)
        except OSError as e:
            raise FixError(f"Write failed at 0x{address:X}: {e.strerror}") from e
        if written != len(data):
            raise FixError(f"Short write at 0x{address:X}: expected {len(data)}, got {written}")

    def u8(self, a: int) -> int: return self.rb(a, 1)[0]
    def u16(self, a: int) -> int: return struct.unpack("<H", self.rb(a, 2))[0]
    def u32(self, a: int) -> int: return struct.unpack("<I", self.rb(a, 4))[0]
    def i64(self, a: int) -> int: return struct.unpack("<q", self.rb(a, 8))[0]

    @staticmethod
    def read_pe(path: Path) -> tuple[int, int, bytes]:
        b = path.read_bytes()
        if b[:2] != b"MZ":
            raise FixError("Game executable is not a PE file.")
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        if b[pe:pe+4] != b"PE\0\0":
            raise FixError("Invalid PE header in game executable.")
        nsec = struct.unpack_from("<H", b, pe + 6)[0]
        stamp = struct.unpack_from("<I", b, pe + 8)[0]
        opt_size = struct.unpack_from("<H", b, pe + 20)[0]
        for i in range(nsec):
            o = pe + 24 + opt_size + i * 40
            name = b[o:o+8].split(b"\0", 1)[0]
            if name == b".text":
                size = struct.unpack_from("<I", b, o + 16)[0]
                rva = struct.unpack_from("<I", b, o + 12)[0]
                off = struct.unpack_from("<I", b, o + 20)[0]
                return stamp, rva, b[off:off+size]
        raise FixError("No .text section found in game executable.")

    @staticmethod
    def find_sig(hay: bytes, pattern: str) -> list[int]:
        vals: list[Optional[int]] = [None if x == "??" else int(x, 16) for x in pattern.split()]
        anchor = next((i for i, v in enumerate(vals) if v is not None), None)
        if anchor is None:
            return []
        first = vals[anchor]
        hits = []
        limit = len(hay) - len(vals)
        for p in range(limit + 1):
            if hay[p + anchor] != first:
                continue
            if all(v is None or hay[p+i] == v for i, v in enumerate(vals)):
                hits.append(p)
                if len(hits) > 1:
                    break
        return hits

    def attach(self) -> bool:
        pids = self.find_processes()
        if not pids:
            return False
        if len(pids) > 1:
            raise FixError(f"More than one matching HITMAN process is running: {pids}")
        pid = pids[0]
        base, exe = self.locate_module(pid)
        stamp, text_rva, text = self.read_pe(exe)

        if stamp == VERIFIED_TIMESTAMP:
            mode = "verified"
            sites = [Site(s.rva, s.stock, s.fix, s.what) for s in VERIFIED_CODE]
            slot = 0
            wno = VERIFIED_WNO_OFF
        else:
            mode = "scanned"
            sites = []
            for hit_off, fix, pattern, what in SIGS:
                hits = self.find_sig(text, pattern)
                if len(hits) != 1:
                    raise FixError(f"The code for '{what}' was not found uniquely in this build; nothing changed.")
                sites.append(Site(text_rva + hits[0] + hit_off, None, fix, what))
            hits = self.find_sig(text, SIG_DEVICE_PAT)
            if len(hits) != 1:
                raise FixError("The VR device reference was not found uniquely; nothing changed.")
            at = hits[0]
            rel = struct.unpack_from("<i", text, at + SIG_DEVICE_REL)[0]
            slot = text_rva + at + 7 + rel
            wno = struct.unpack_from("<I", text, at + SIG_DEVICE_DSP)[0]
            if not (0 < wno <= 0x4000):
                raise FixError("Implausible device layout in this build; nothing changed.")

        try:
            fd = os.open(f"/proc/{pid}/mem", os.O_RDWR)
        except PermissionError as e:
            raise FixError("Access denied opening process memory. Run this script with sudo.") from e

        self.pid, self.mem_fd, self.base, self.exe_path = pid, fd, base, exe
        self.mode, self.sites, self.dev_slot, self.wno_off = mode, sites, slot, wno
        self.log(f"attached pid {pid}, build {stamp}, mode {mode}, base 0x{base:X}")
        self.status("attached", f"PID {pid}; {'verified build' if mode == 'verified' else 'untested build located by signatures'}")
        return True

    def process_alive(self) -> bool:
        return self.pid > 0 and Path(f"/proc/{self.pid}").exists()

    def detach(self) -> None:
        if self.mem_fd is not None:
            try: os.close(self.mem_fd)
            except OSError: pass
        self.pid = 0; self.mem_fd = None; self.base = 0; self.exe_path = None
        self.mode = ""; self.sites = []; self.dev_slot = 0; self.patched = False
        self.dev = 0; self.tex = 0; self.vals_ok = False; self.need_reload = False
        self.scale_stock = None; self.mask_stock = None

    def get_dev(self) -> int:
        if self.mode == "verified":
            mgr = self.base + MANAGER_RVA
            if self.i64(mgr) != self.base + MANAGER_VTABLE_RVA:
                return 0
            d = self.i64(mgr + MANAGER_DEVICE_OFFSET)
            if d == 0:
                return 0
            vt = self.i64(d)
            if vt not in (self.base + OCULUS_VTABLE_RVA, self.base + OPENVR_VTABLE_RVA):
                return -1
            return d
        try:
            d = self.i64(self.base + self.dev_slot)
        except FixError:
            return 0
        return d if self.dev_plausible(d) else 0

    def dev_plausible(self, d: int) -> bool:
        if not (0x10000 <= d <= 0x7FFFFFFFFFFF):
            return False
        try:
            fov = struct.unpack("<4f", self.rb(d + OFF_FOV, 16))
            return all(0.2 <= x <= 3.0 for x in fov) and self.u8(d + OFF_ACTIVE) <= 1
        except FixError:
            return False

    def vr_running(self) -> bool:
        d = self.get_dev()
        return d > 0 and self.u8(d + OFF_ACTIVE) == 1

    def runtime_loaded(self) -> bool:
        try:
            text = Path(f"/proc/{self.pid}/maps").read_text(errors="replace").lower()
        except OSError:
            return False
        return "libovrrt" in text or "openvr_api" in text

    def apply_code(self) -> None:
        for s in self.sites:
            if s.stock is None:
                s.stock = self.rb(self.base + s.rva, len(s.fix))
        current = [self.rb(self.base + s.rva, len(s.fix)) for s in self.sites]
        if all(cur == s.fix for cur, s in zip(current, self.sites)):
            self.patched = True
            return
        if not all(cur == s.stock for cur, s in zip(current, self.sites)):
            raise FixError("Game code is not in its original state. Restart HITMAN and the tool.")
        if self.vr_running():
            raise FixError("VR was already running. Start this tool before HITMAN/VR.")
        for s in self.sites:
            self.wb(self.base + s.rva, s.fix)
        time.sleep(0.06)
        for s in self.sites:
            if self.rb(self.base + s.rva, len(s.fix)) != s.fix:
                raise FixError("A code patch did not stick. Restart HITMAN.")
        self.patched = True
        self.log("code patched")

    def restore(self) -> None:
        if self.mem_fd is None or not self.process_alive():
            return
        try:
            if self.vals_ok and self.dev:
                for address, data in ((self.dev + OFF_SCALE, self.scale_stock or SCALE_STOCK),
                                      (self.dev + OFF_MASK, self.mask_stock or MASK_STOCK)):
                    try: self.wb(address, data)
                    except FixError: pass
            if self.patched:
                for s in self.sites:
                    if s.stock is not None:
                        try: self.wb(self.base + s.rva, s.stock)
                        except FixError: pass
            self.log("restored")
        except Exception:
            pass

    def tick(self) -> None:
        if self.mem_fd is None:
            if not self.attach():
                self.status("waiting", "Start HITMAN after this tool.")
                return
        if not self.process_alive():
            self.log("game closed")
            self.detach()
            self.status("waiting", "HITMAN closed; start it again to reapply.")
            return
        if not self.patched:
            self.apply_code()
            warn = " Untested game build." if self.mode == "scanned" else ""
            self.status("ready", "Game code patched; start VR and load a mission." + warn)
            return

        d = self.get_dev()
        if d == -1:
            raise FixError("Active VR device is neither the supported Oculus nor OpenVR device.")
        if d == 0:
            self.status("ready", "Game patched; waiting for VR.")
            return
        self.dev = d

        active = self.u8(d + OFF_ACTIVE)
        wno = self.u8(d + self.wno_off)
        trans = self.u32(d + OFF_TRANS)
        layers = self.u16(d + OFF_LAYERS)
        tex = self.i64(d + OFF_TEX)
        width = self.u32(d + OFF_W)
        height = self.u32(d + OFF_H)

        if active != 1:
            self.status("ready", "Game patched; waiting for VR.")
            return
        if self.mode == "scanned" and not self.runtime_loaded():
            raise FixError("Neither the Oculus nor OpenVR runtime appears loaded in the process.")
        if wno != 0:
            raise FixError("VR started before the patch took effect. Restart HITMAN with this tool already running.")

        if tex != self.tex:
            self.tex = tex; self.need_reload = False; self.vals_ok = False

        try:
            fov = struct.unpack("<4f", self.rb(d + OFF_FOV, 16))
            fov_ok = all(0.2 <= x <= 3.0 for x in fov)
        except FixError:
            fov_ok = False

        if fov_ok:
            s_ok = self.rb(d + OFF_SCALE, 16) == SCALE_FIX
            m_ok = self.rb(d + OFF_MASK, 8) == MASK_FIX
            if not (s_ok and m_ok):
                if self.scale_stock is None:
                    self.scale_stock = self.rb(d + OFF_SCALE, 16)
                    self.mask_stock = self.rb(d + OFF_MASK, 8)
                self.wb(d + OFF_SCALE, SCALE_FIX)
                self.wb(d + OFF_MASK, MASK_FIX)
                if trans == 3:
                    self.need_reload = True
                self.vals_ok = True
                self.log(f"values written, transition={trans}")

        warn = " Untested game build; verify the image looks correct." if self.mode == "scanned" else ""
        if trans != 3 or layers != 2 or tex == 0:
            self.status("waiting", "VR is in two-layer mode; load a mission." + warn)
        elif self.need_reload:
            self.status("reload", "Reload this mission once so the new values take effect." + warn)
        else:
            self.status("active", f"Sharp edge-to-edge; rendering {width} x {height} per eye in two layers." + warn)

    def run(self) -> int:
        self.status("waiting", "Start HITMAN after this tool.")
        while self.running:
            try:
                self.tick()
            except FixError as e:
                self.status("error", str(e))
                self.log(f"error: {e}")
                return 1
            except KeyboardInterrupt:
                break
            time.sleep(self.interval)
        return 0

    def stop(self, *_args) -> None:
        self.running = False


def main() -> int:
    parser = argparse.ArgumentParser(description="Linux/Proton port of HitmanVRFoveationFix v1.2")
    parser.add_argument("--process-name", action="append", dest="names",
                        help="process name to match; may be repeated")
    parser.add_argument("--interval", type=float, default=0.25, help="poll interval in seconds")
    parser.add_argument("--log", type=Path, default=Path(__file__).with_name("foveationfix-linux.log"))
    args = parser.parse_args()

    if os.name != "posix" or not Path("/proc").exists():
        print("This script requires Linux with procfs.", file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("This tool needs process-memory access. Run it with sudo, for example:", file=sys.stderr)
        print(f"  sudo -E python3 {Path(__file__).resolve()}", file=sys.stderr)
        return 2

    names = args.names or ["HITMAN3.exe", "HITMAN3"]
    fix = LinuxFix(names, max(args.interval, 0.05), args.log)
    atexit.register(lambda: (fix.restore(), fix.detach()))
    signal.signal(signal.SIGINT, fix.stop)
    signal.signal(signal.SIGTERM, fix.stop)
    print(f"HitmanVRFoveationFix {VERSION} — Linux/Proton experimental port")
    print("Leave this terminal open. Press Ctrl+C to restore and exit.")
    rc = fix.run()
    fix.restore()
    fix.detach()
    return rc

if __name__ == "__main__":
    raise SystemExit(main())
