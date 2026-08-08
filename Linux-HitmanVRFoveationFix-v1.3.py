#!/usr/bin/env python3
"""
HitmanVRFoveationFix v1.3 - Linux/Proton continuous-guard experiment

Direct port of RealChrizzl's Windows PowerShell v1.3 implementation.
Renderer constants, verified RVAs, signatures, lifecycle logic, timing,
write/verification logic, and restore policy are retained.

Windows-only facilities are replaced as follows:
  - Get-Process/OpenProcess/ReadProcessMemory/WriteProcessMemory -> /proc on Linux
  - named Windows mutex -> flock
  - WinForms status window -> terminal status output
  - WinForms "Turn off"/window close -> Ctrl+C/SIGTERM

No game file is modified. All renderer changes are made in the memory of the
running HITMAN process and disappear when HITMAN exits.
"""

from __future__ import annotations

import argparse
import atexit
import datetime as dt
import fcntl
import math
import os
import signal
import struct
import sys
import time
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ===========================================================================
#  VERIFIED PATH - build 3.270.1
# ===========================================================================

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
    stock: bytes
    fix: bytes
    what: str = ""


VERIFIED_CODE = [
    Site(
        0x011D8B9E,
        bytes((0x0F, 0x94, 0xC1)),
        bytes((0xB1, 0x00, 0x90)),
    ),
    Site(
        0x011D8BC1,
        bytes((0x0F, 0x94, 0xC0)),
        bytes((0xB0, 0x00, 0x90)),
    ),
    Site(
        0x012C1EAC,
        bytes((0x0F, 0xB6, 0x87, 0x1B, 0x03, 0x00, 0x00)),
        bytes((0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90)),
        "full field of view, Oculus device",
    ),
    Site(
        0x012499CC,
        bytes((0x0F, 0xB6, 0x87, 0x1B, 0x03, 0x00, 0x00)),
        bytes((0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90)),
        "full field of view, OpenVR device",
    ),
    Site(
        0x01161FE9,
        bytes((0x80, 0xB8, 0x1B, 0x03, 0x00, 0x00, 0x00)),
        bytes((0x48, 0x85, 0xE4, 0x90, 0x90, 0x90, 0x90)),
        "view count 4 - without this, geometry disappears",
    ),
]


# ===========================================================================
#  PATTERN PATH - used only when build is not the verified one
# ===========================================================================

SIGS = [
    {
        "hit": 9,
        "fix": bytes((0xB1, 0x00, 0x90)),
        "pattern": "8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00",
        "what": "two layers instead of four (writer A)",
    },
    {
        "hit": 9,
        "fix": bytes((0xB0, 0x00, 0x90)),
        "pattern": "8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00",
        "what": "two layers instead of four (writer B)",
    },
    {
        "hit": 44,
        "fix": bytes((0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90)),
        "pattern": (
            "C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 "
            "48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 "
            "48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
        ),
        "what": "full field of view, Oculus device",
    },
    {
        "hit": 44,
        "fix": bytes((0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90)),
        "pattern": (
            "50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 "
            "48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 "
            "48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
        ),
        "what": "full field of view, OpenVR device",
    },
    {
        "hit": 12,
        "fix": bytes((0x48, 0x85, 0xE4, 0x90, 0x90, 0x90, 0x90)),
        "pattern": "74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF",
        "what": "view count 4 - without this, geometry disappears",
    },
]

SIG_DEVICE_PAT = "48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"
SIG_DEVICE_REL = 3
SIG_DEVICE_DSP = 15


# --- device field offsets --------------------------------------------------

OFF_ACTIVE = 0x319
OFF_TRANS = 0x4D8
OFF_W = 0x510
OFF_H = 0x514
OFF_LAYERS = 0x520
OFF_TEX = 0x530
OFF_FOV = 0x420
OFF_SCALE = 0x490
OFF_MASK = 0x4C0

SCALE_FIX_WORDS = (0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000)
SCALE_STOCK_WORDS = (0x3EDF2BF0, 0x3ECE8B44, 0x4012D426, 0x401EA625)
SCALE_FIX = struct.pack("<4I", *SCALE_FIX_WORDS)
SCALE_STOCK = struct.pack("<4I", *SCALE_STOCK_WORDS)
MASK_FIX = bytes((0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
MASK_STOCK = bytes((0x3D, 0x2D, 0x66, 0x3F, 0xDA, 0xB9, 0x4D, 0x3E))


class FixError(RuntimeError):
    pass


@dataclass
class SyncResult:
    initialized: bool = False
    fixed: bool = False
    wrote: bool = False
    error: str = ""


@dataclass
class LifecycleResult:
    last_transition: int
    need_reload: bool
    transition_changed: bool
    reset_stable: bool


class HitmanVRFoveationFix:
    def __init__(self, process_name: str, log_path: Path):
        self.process_name = process_name
        self.log_path = log_path

        # --- state, mirroring v1.3 -----------------------------------------
        self.mem_fd: Optional[int] = None
        self.game_pid = 0
        self.base = 0
        self.exe_path: Optional[Path] = None

        self.mode = ""                 # verified | scanned
        self.sites: list[Site] = []
        self.written_sites: list[Site] = []
        self.dev_slot = 0
        self.wno_off = OFF_ACTIVE
        self.patched = False

        self.dev = 0
        self.last_trans = -1
        self.need_rel = False
        self.pending_value_write = False
        self.stable_ready = 0
        self.stable_since = 0

        self.scale_stock: Optional[bytes] = None
        self.mask_stock: Optional[bytes] = None
        self.scale_touched = False
        self.mask_touched = False
        self.device_restore_uncertain = False

        self.runtime_loaded = False
        self.last_runtime_check = 0

        self.last_write_log = dt.datetime.min
        self.last_ui = ""
        self.fatal = ""
        self.stopped = False

        # Experimental continuous guard.
        self.guard_thread: Optional[threading.Thread] = None
        self.guard_stop = threading.Event()
        self.guard_device = 0

    # --- basic helpers ------------------------------------------------------

    def log(self, text: str) -> None:
        try:
            stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(f"{stamp}  {text}\n")
        except OSError:
            pass

    def show_state(self, colour: str, head: str, body: str, warn: str = "") -> None:
        key = "\n".join((colour, head, body, warn))
        if key == self.last_ui:
            return
        self.last_ui = key
        message = f"[{head}] {body}"
        if warn:
            message += f"  {warn}"
        print(message, flush=True)

    def rb(self, address: int, size: int) -> bytes:
        if self.mem_fd is None:
            raise FixError("process memory is not open")
        try:
            data = os.pread(self.mem_fd, size, address)
        except OSError as exc:
            raise FixError(f"read failed at 0x{address:X}") from exc
        if len(data) != size:
            raise FixError(f"read failed at 0x{address:X}")
        return data

    def wb(self, address: int, data: bytes) -> None:
        if self.mem_fd is None:
            raise FixError("process memory is not open")
        try:
            written = os.pwrite(self.mem_fd, data, address)
        except OSError as exc:
            raise FixError(f"write failed at 0x{address:X}") from exc
        if written != len(data):
            raise FixError(f"write failed at 0x{address:X}")
        # Windows v1.3 calls FlushInstructionCache here. x86-64 Linux/Proton
        # has coherent instruction/data caches, so there is no separate
        # userspace equivalent required for this target.

    def u8(self, address: int) -> int:
        return self.rb(address, 1)[0]

    def u16(self, address: int) -> int:
        return struct.unpack("<H", self.rb(address, 2))[0]

    def u32(self, address: int) -> int:
        return struct.unpack("<I", self.rb(address, 4))[0]

    def i64(self, address: int) -> int:
        return struct.unpack("<q", self.rb(address, 8))[0]

    # --- PE parsing / pattern search ---------------------------------------

    @staticmethod
    def read_pe(path: Path) -> tuple[int, int, bytes]:
        data = path.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        stamp = struct.unpack_from("<i", data, pe + 8)[0]
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        opt_size = struct.unpack_from("<H", data, pe + 20)[0]

        text_rva = 0
        text_off = 0
        text_size = 0

        for i in range(nsec):
            off = pe + 24 + opt_size + i * 40
            name = data[off:off + 8].rstrip(b"\0").decode("ascii", "replace")
            if name == ".text":
                text_size = struct.unpack_from("<i", data, off + 16)[0]
                text_rva = struct.unpack_from("<i", data, off + 12)[0]
                text_off = struct.unpack_from("<i", data, off + 20)[0]
                break

        if text_rva == 0:
            raise FixError("no .text section")

        return stamp, text_rva, data[text_off:text_off + text_size]

    @staticmethod
    def find_sig(hay: bytes, pattern: str) -> list[int]:
        tokens = pattern.split(" ")
        vals = [-1 if token == "??" else int(token, 16) for token in tokens]

        anchor = 0
        while anchor < len(vals) and vals[anchor] < 0:
            anchor += 1
        if anchor >= len(vals):
            return []

        first = vals[anchor]
        hits: list[int] = []
        limit = len(hay) - len(vals)

        for pos in range(limit + 1):
            if hay[pos + anchor] != first:
                continue
            ok = True
            for i, value in enumerate(vals):
                if value >= 0 and hay[pos + i] != value:
                    ok = False
                    break
            if ok:
                hits.append(pos)
                if len(hits) > 1:
                    return hits

        return hits

    # --- Linux process discovery ------------------------------------------

    @staticmethod
    def _read_proc_text(path: Path) -> str:
        try:
            return path.read_text(errors="replace")
        except OSError:
            return ""

    def find_processes(self) -> list[int]:
        """
        Linux equivalent of Get-Process -Name $ProcessName.

        Wine commonly exposes the command line as retail\\hitman3.exe even
        when /proc/<pid>/comm is truncated or differently cased.
        """
        wanted = self.process_name.lower()
        wanted_exe = wanted if wanted.endswith(".exe") else wanted + ".exe"

        matches: list[int] = []
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue

            comm = self._read_proc_text(proc / "comm").strip().lower()
            try:
                cmdline = (
                    (proc / "cmdline")
                    .read_bytes()
                    .replace(b"\0", b" ")
                    .decode(errors="replace")
                    .lower()
                )
            except OSError:
                cmdline = ""

            comm_base = comm.rsplit("/", 1)[-1]
            cmd_first = cmdline.split(" ", 1)[0]
            cmd_base = cmd_first.replace("\\", "/").rsplit("/", 1)[-1]

            if comm_base in (wanted, wanted_exe) or cmd_base in (wanted, wanted_exe):
                matches.append(int(proc.name))

        return matches

    @staticmethod
    def parse_maps(pid: int) -> list[tuple[int, int, str, int, str]]:
        rows: list[tuple[int, int, str, int, str]] = []
        with open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split(None, 5)
                if len(parts) < 5:
                    continue
                start_s, end_s = parts[0].split("-", 1)
                path = parts[5] if len(parts) == 6 else ""
                rows.append(
                    (
                        int(start_s, 16),
                        int(end_s, 16),
                        parts[1],
                        int(parts[2], 16),
                        path,
                    )
                )
        return rows

    def locate_module(self, pid: int) -> tuple[int, Path]:
        wanted = self.process_name.lower()
        wanted_exe = wanted if wanted.endswith(".exe") else wanted + ".exe"
        candidates: list[tuple[int, int, Path]] = []

        for start, _end, _perms, offset, path in self.parse_maps(pid):
            if not path:
                continue
            clean = path.replace("\\040", " ")
            base_name = clean.replace("\\", "/").rsplit("/", 1)[-1].lower()
            if base_name not in (wanted, wanted_exe):
                continue
            candidates.append((start, offset, Path(clean)))

        if not candidates:
            raise FixError("Could not locate the game executable.")

        zero_offset = [item for item in candidates if item[1] == 0]
        start, _offset, path = min(zero_offset or candidates, key=lambda item: item[0])
        return start, path

    def process_alive(self) -> bool:
        return self.game_pid > 0 and Path(f"/proc/{self.game_pid}").exists()

    # --- state helpers ------------------------------------------------------

    def reset_device_state(self, ownership_became_uncertain: bool = False) -> None:
        if ownership_became_uncertain and (self.scale_touched or self.mask_touched):
            self.device_restore_uncertain = True

        self.dev = 0
        self.last_trans = -1
        self.need_rel = False
        self.pending_value_write = False
        self.stable_ready = 0
        self.stable_since = 0
        self.scale_stock = None
        self.mask_stock = None
        self.scale_touched = False
        self.mask_touched = False
        self.runtime_loaded = False
        self.last_runtime_check = 0
        self.last_write_log = dt.datetime.min

    @staticmethod
    def advance_lifecycle(
        last_transition: int,
        need_reload: bool,
        transition: int,
        values_written: bool,
    ) -> LifecycleResult:
        changed = last_transition != transition
        if transition != 3:
            need_reload = False
        elif values_written:
            need_reload = True

        return LifecycleResult(
            last_transition=transition,
            need_reload=need_reload,
            transition_changed=changed,
            reset_stable=(changed or values_written),
        )

    def detach(self) -> None:
        self.stop_guard()
        if self.mem_fd is not None:
            try:
                os.close(self.mem_fd)
            except OSError:
                pass

        self.mem_fd = None
        self.game_pid = 0
        self.base = 0
        self.exe_path = None

        self.mode = ""
        self.sites = []
        self.written_sites = []
        self.dev_slot = 0
        self.patched = False

        self.dev = 0
        self.last_trans = -1
        self.need_rel = False
        self.pending_value_write = False
        self.stable_ready = 0
        self.stable_since = 0

        self.scale_stock = None
        self.mask_stock = None
        self.scale_touched = False
        self.mask_touched = False
        self.device_restore_uncertain = False

        self.runtime_loaded = False
        self.last_runtime_check = 0
        self.last_write_log = dt.datetime.min
        self.last_ui = ""

    # --- device access, mode aware -----------------------------------------

    def dev_plausible(self, device: int) -> bool:
        if device < 0x10000 or device > 0x7FFFFFFFFFFF:
            return False

        try:
            fov = self.rb(device + OFF_FOV, 16)
            for i in range(4):
                value = struct.unpack_from("<f", fov, i * 4)[0]
                if value < 0.2 or value > 3.0:
                    return False

            active = self.u8(device + OFF_ACTIVE)
            if active > 1:
                return False
        except Exception:
            return False

        return True

    def get_dev(self) -> int:
        # 0 = no device yet, -1 = wrong backend, otherwise device address
        if self.mode == "verified":
            manager = self.base + MANAGER_RVA

            if self.i64(manager) != self.base + MANAGER_VTABLE_RVA:
                return 0

            device = self.i64(manager + MANAGER_DEVICE_OFFSET)
            if device == 0:
                return 0

            vtable = self.i64(device)
            if vtable not in (
                self.base + OCULUS_VTABLE_RVA,
                self.base + OPENVR_VTABLE_RVA,
            ):
                return -1

            return device

        try:
            device = self.i64(self.base + self.dev_slot)
        except Exception:
            return 0

        if not self.dev_plausible(device):
            return 0

        return device

    def vr_running(self) -> bool:
        # Only true when we are confident VR is already up.
        device = self.get_dev()
        if device <= 0:
            return False
        try:
            return self.u8(device + OFF_ACTIVE) == 1
        except Exception:
            return False

    def vr_runtime_loaded(self) -> bool:
        # Linux equivalent of enumerating Process.Modules.
        try:
            maps = Path(f"/proc/{self.game_pid}/maps").read_text(errors="replace")
        except OSError:
            return False

        for line in maps.splitlines():
            module = line.rsplit("/", 1)[-1]
            lower = module.lower()
            if lower.startswith("libovrrt") or lower.startswith("openvr_api"):
                return True

        return False

    # --- attach -------------------------------------------------------------

    def try_attach(self) -> bool:
        pids = self.find_processes()

        if len(pids) == 0:
            return False

        if len(pids) > 1:
            self.fatal = (
                "More than one HITMAN process is running. "
                "Close them all and start the game once."
            )
            return False

        pid = pids[0]

        try:
            base, path = self.locate_module(pid)
        except Exception:
            return False

        try:
            stamp, text_rva, text = self.read_pe(path)
        except Exception:
            self.fatal = "Could not read the game executable."
            return False

        sites: list[Site] = []
        mode = ""
        slot = 0
        wno = 0x31B

        if stamp == VERIFIED_TIMESTAMP:
            mode = "verified"
            for item in VERIFIED_CODE:
                sites.append(
                    Site(
                        rva=item.rva,
                        stock=bytes(item.stock),
                        fix=bytes(item.fix),
                        what=item.what,
                    )
                )
            wno = VERIFIED_WNO_OFF

        else:
            mode = "scanned"

            for sig in SIGS:
                hits = self.find_sig(text, sig["pattern"])
                if len(hits) != 1:
                    self.fatal = (
                        "The code for '"
                        + sig["what"]
                        + "' could not be located uniquely in this build. "
                        "Nothing was changed. Please report this build on the project page."
                    )
                    return False

                hit = hits[0]
                fix = sig["fix"]
                stock = bytes(text[hit + sig["hit"]:hit + sig["hit"] + len(fix)])

                sites.append(
                    Site(
                        rva=text_rva + hit + sig["hit"],
                        stock=stock,
                        fix=fix,
                        what=sig["what"],
                    )
                )

            hits = self.find_sig(text, SIG_DEVICE_PAT)
            if len(hits) != 1:
                self.fatal = (
                    "The VR device reference could not be located uniquely "
                    "in this build. Nothing was changed."
                )
                return False

            at = hits[0]
            rel = struct.unpack_from("<i", text, at + SIG_DEVICE_REL)[0]
            slot = text_rva + at + 7 + rel
            wno = struct.unpack_from("<I", text, at + SIG_DEVICE_DSP)[0]

            if wno <= 0 or wno > 0x4000:
                self.fatal = "Implausible device layout in this build. Nothing was changed."
                return False

        try:
            mem_fd = os.open(f"/proc/{pid}/mem", os.O_RDWR)
        except OSError:
            self.fatal = "Access denied. Start this tool with sudo."
            return False

        self.mem_fd = mem_fd
        self.game_pid = pid
        self.base = base
        self.exe_path = path
        self.mode = mode
        self.sites = sites
        self.dev_slot = slot
        self.wno_off = wno

        self.log(f"attached pid {pid}, build {stamp}, mode {mode}")
        return True

    # --- renderer values ----------------------------------------------------

    def sync_render_values(self, device: int) -> SyncResult:
        """
        Direct port of v1.3 Sync-RenderValues.
        """
        result = SyncResult()

        fov = self.rb(device + OFF_FOV, 16)
        for i in range(4):
            value = struct.unpack_from("<f", fov, i * 4)[0]
            if (
                math.isnan(value)
                or math.isinf(value)
                or value < 0.2
                or value > 3.0
            ):
                return result

        scale = self.rb(device + OFF_SCALE, 16)
        for i in range(4):
            value = struct.unpack_from("<f", scale, i * 4)[0]
            if (
                math.isnan(value)
                or math.isinf(value)
                or value < 0.05
                or value > 20.0
            ):
                return result

        mask = self.rb(device + OFF_MASK, 8)
        for i in range(2):
            value = struct.unpack_from("<f", mask, i * 4)[0]
            if (
                math.isnan(value)
                or math.isinf(value)
                or value < -0.01
                or value > 4.0
            ):
                return result

        result.initialized = True
        scale_ok = scale == SCALE_FIX
        mask_ok = mask == MASK_FIX

        if not scale_ok:
            was_touched = self.scale_touched

            if not was_touched:
                self.scale_stock = scale

            # Claim ownership before the write, mirroring v1.3.
            self.scale_touched = True
            result.wrote = True

            try:
                self.wb(device + OFF_SCALE, SCALE_FIX)
            except Exception:
                pass

            try:
                after = self.rb(device + OFF_SCALE, 16)
            except Exception:
                self.device_restore_uncertain = True
                result.error = (
                    "Scale write could not be verified. "
                    "Close HITMAN if this repeats."
                )
                return result

            if after != SCALE_FIX:
                rolled_back = after == scale

                if not rolled_back:
                    try:
                        self.wb(device + OFF_SCALE, scale)
                        rolled_back = self.rb(device + OFF_SCALE, 16) == scale
                    except Exception:
                        rolled_back = False

                if rolled_back and not was_touched:
                    self.scale_touched = False
                    self.scale_stock = None

                if not rolled_back:
                    self.device_restore_uncertain = True

                result.error = (
                    "Scale write failed and was rolled back; retrying."
                    if rolled_back
                    else "Scale write left an unknown value. Close HITMAN."
                )
                return result

        if not mask_ok:
            was_touched = self.mask_touched

            if not was_touched:
                self.mask_stock = mask

            self.mask_touched = True
            result.wrote = True

            try:
                self.wb(device + OFF_MASK, MASK_FIX)
            except Exception:
                pass

            try:
                after = self.rb(device + OFF_MASK, 8)
            except Exception:
                self.device_restore_uncertain = True
                result.error = (
                    "Mask write could not be verified. "
                    "Close HITMAN if this repeats."
                )
                return result

            if after != MASK_FIX:
                rolled_back = after == mask

                if not rolled_back:
                    try:
                        self.wb(device + OFF_MASK, mask)
                        rolled_back = self.rb(device + OFF_MASK, 8) == mask
                    except Exception:
                        rolled_back = False

                if rolled_back and not was_touched:
                    self.mask_touched = False
                    self.mask_stock = None

                if not rolled_back:
                    self.device_restore_uncertain = True

                result.error = (
                    "Mask write failed and was rolled back; retrying."
                    if rolled_back
                    else "Mask write left an unknown value. Close HITMAN."
                )
                return result

        # Final verification, exactly as v1.3.
        try:
            result.fixed = (
                self.rb(device + OFF_SCALE, 16) == SCALE_FIX
                and self.rb(device + OFF_MASK, 8) == MASK_FIX
            )
        except Exception:
            result.error = (
                "Render values were written but the final verification read failed; retrying."
            )
            return result

        return result

    # --- code patching ------------------------------------------------------

    def apply_code(self) -> bool:
        all_fix = True
        all_stock = True

        for site in self.sites:
            current = self.rb(self.base + site.rva, len(site.fix))

            if current != site.fix:
                all_fix = False

            if current != site.stock:
                all_stock = False

        if all_fix:
            self.fatal = (
                "HITMAN was already patched before this tool attached. "
                "Close every fix window and HITMAN, then start this tool again."
            )
            return False

        if not all_stock:
            self.fatal = (
                "The game code is not in its original state. "
                "Close HITMAN, start it again, then this tool."
            )
            return False

        if self.vr_running():
            self.fatal = (
                "VR was already running when this tool attached. "
                "Close HITMAN, start this tool first, then the game."
            )
            return False

        written: list[Site] = []

        try:
            for site in self.sites:
                # Include before write: a partial write can still modify memory.
                written.append(site)
                self.wb(self.base + site.rva, site.fix)

            time.sleep(0.060)

            for site in self.sites:
                if self.rb(self.base + site.rva, len(site.fix)) != site.fix:
                    raise FixError("verification failed")

        except Exception:
            rollback_ok = True

            for site in written:
                try:
                    self.wb(self.base + site.rva, site.stock)
                    if self.rb(self.base + site.rva, len(site.stock)) != site.stock:
                        rollback_ok = False
                except Exception:
                    rollback_ok = False

            self.written_sites = []

            if rollback_ok:
                self.fatal = (
                    "A patch did not stick. The partial change was rolled back; "
                    "please restart HITMAN."
                )
            else:
                self.fatal = (
                    "A patch failed and could not be rolled back safely. "
                    "Close HITMAN now; all changes disappear when the game exits."
                )

            return False

        self.written_sites = written
        self.patched = True
        self.log("code patched")
        return True

    # --- restore ------------------------------------------------------------

    def restore(self) -> bool:
        self.stop_guard()
        if self.mem_fd is None:
            return True

        ok = not self.device_restore_uncertain

        if self.dev != 0:
            device_current = False

            try:
                device_current = self.get_dev() == self.dev
            except Exception:
                pass

            if not device_current and (self.scale_touched or self.mask_touched):
                ok = False

            if device_current and self.scale_touched:
                stock = self.scale_stock if self.scale_stock is not None else SCALE_STOCK

                try:
                    current = self.rb(self.dev + OFF_SCALE, 16)

                    if current == SCALE_FIX:
                        if self.get_dev() != self.dev:
                            raise FixError("device changed during restore")

                        self.wb(self.dev + OFF_SCALE, stock)

                        if self.rb(self.dev + OFF_SCALE, 16) != stock:
                            ok = False

                    elif current != stock:
                        ok = False

                except Exception:
                    ok = False

            if device_current and self.mask_touched:
                stock = self.mask_stock if self.mask_stock is not None else MASK_STOCK

                try:
                    current = self.rb(self.dev + OFF_MASK, 8)

                    if current == MASK_FIX:
                        if self.get_dev() != self.dev:
                            raise FixError("device changed during restore")

                        self.wb(self.dev + OFF_MASK, stock)

                        if self.rb(self.dev + OFF_MASK, 8) != stock:
                            ok = False

                    elif current != stock:
                        ok = False

                except Exception:
                    ok = False

        for site in self.written_sites:
            try:
                current = self.rb(self.base + site.rva, len(site.fix))

                if current == site.fix:
                    self.wb(self.base + site.rva, site.stock)

                    if self.rb(self.base + site.rva, len(site.stock)) != site.stock:
                        ok = False

                elif current != site.stock:
                    ok = False

            except Exception:
                ok = False

        self.log("restored" if ok else "restore incomplete - close HITMAN")
        return ok

    def guard_loop(self, device: int) -> None:
        """
        Experimental Linux-only continuous guard.

        Poll only the developer's v1.3 scale/mask fields at high frequency.
        This is deliberately separate from the 15 ms lifecycle/status loop.
        """
        scale_fix = SCALE_FIX
        mask_fix = MASK_FIX

        while not self.guard_stop.is_set() and self.process_alive():
            try:
                if self.get_dev() != device:
                    return

                scale = self.rb(device + OFF_SCALE, 16)
                if scale != scale_fix:
                    if not self.scale_touched:
                        self.scale_stock = scale
                    self.scale_touched = True
                    self.wb(device + OFF_SCALE, scale_fix)

                mask = self.rb(device + OFF_MASK, 8)
                if mask != mask_fix:
                    if not self.mask_touched:
                        self.mask_stock = mask
                    self.mask_touched = True
                    self.wb(device + OFF_MASK, mask_fix)

            except Exception:
                if not self.process_alive():
                    return

            # Roughly 0.1 ms scheduler pause. Actual Linux scheduling granularity
            # may be larger; this is an experiment, not a real-time guarantee.
            #time.sleep(0.0001) # works but way too aggressive
            time.sleep(0.001) # works

    def ensure_guard(self, device: int) -> None:
        if (
            self.guard_thread is not None
            and self.guard_thread.is_alive()
            and self.guard_device == device
        ):
            return

        self.guard_stop.set()
        if self.guard_thread is not None and self.guard_thread.is_alive():
            self.guard_thread.join(timeout=0.1)

        self.guard_stop = threading.Event()
        self.guard_device = device
        self.guard_thread = threading.Thread(
            target=self.guard_loop,
            args=(device,),
            name="hitman-foveation-guard",
            daemon=True,
        )
        self.guard_thread.start()
        self.log(f"continuous guard started for device 0x{device:X}")

    def stop_guard(self) -> None:
        self.guard_stop.set()
        if self.guard_thread is not None and self.guard_thread.is_alive():
            self.guard_thread.join(timeout=0.2)
        self.guard_thread = None
        self.guard_device = 0

    # --- main 15 ms timer-equivalent tick ----------------------------------

    def tick(self) -> None:
        if self.stopped:
            return

        if self.mem_fd is not None:
            game_closed = not self.process_alive()

            if game_closed:
                self.log("game closed")
                self.detach()
                self.fatal = ""
                self.show_state(
                    "grey",
                    "Waiting for HITMAN",
                    "The game was closed. Start it again and this tool will patch it once more.",
                )
                return

        if self.fatal:
            self.show_state("red", "Not active", self.fatal)
            return

        if self.mem_fd is None:
            if not self.try_attach():
                if self.fatal:
                    self.show_state("red", "Not active", self.fatal)
                return

        warn = ""

        if self.mode == "scanned":
            warn = (
                "Untested build - the code was located by pattern. "
                "Please check the image looks right."
            )

        ready = (
            "The game is patched. Put on your headset and start VR as usual, "
            "then load a mission."
        )

        if not self.patched:
            if not self.apply_code():
                return

            self.show_state("amber", "Ready - start VR", ready, warn)
            return

        device = self.get_dev()

        if device == -1:
            if self.dev != 0:
                self.reset_device_state(True)

            self.show_state(
                "red",
                "Unsupported backend",
                "The active VR device is neither the Oculus nor the SteamVR one "
                "this tool was verified against.",
            )
            return

        if device == 0:
            if self.dev != 0:
                self.log("VR device became unavailable")
                self.stop_guard()
                self.reset_device_state(True)

            self.show_state("amber", "Ready - start VR", ready, warn)
            return

        if device != self.dev:
            if self.dev != 0:
                self.reset_device_state(True)
            else:
                self.reset_device_state(False)

            self.dev = device
            self.log(f"VR device found at 0x{device:X}")

        self.ensure_guard(device)

        active = self.u8(device + OFF_ACTIVE)
        wno = self.u8(device + self.wno_off)
        transition = self.u32(device + OFF_TRANS)
        layers = self.u16(device + OFF_LAYERS)
        texture = self.i64(device + OFF_TEX)
        width = self.u32(device + OFF_W)
        height = self.u32(device + OFF_H)

        if self.mode == "scanned" and not self.runtime_loaded:
            runtime_now = time.perf_counter_ns()

            if self.last_runtime_check == 0:
                runtime_age_ms = float("inf")
            else:
                runtime_age_ms = (runtime_now - self.last_runtime_check) / 1_000_000.0

            if runtime_age_ms >= 500:
                self.runtime_loaded = self.vr_runtime_loaded()
                self.last_runtime_check = runtime_now

        if self.mode == "scanned" and not self.runtime_loaded:
            self.stable_ready = 0
            self.stable_since = 0
            self.last_trans = -1
            self.need_rel = False

            if active == 1:
                self.show_state(
                    "red",
                    "No VR runtime",
                    "Neither the Oculus nor the SteamVR runtime is loaded in the game.",
                )
            else:
                self.show_state("amber", "Ready - start VR", ready, warn)

            return

        if active == 1 and wno != 0:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "red",
                "Not active",
                "VR started before the patch could take effect. "
                "Close HITMAN, start this tool first, then the game.",
            )
            return

        sync = self.sync_render_values(device)

        if sync.wrote:
            self.pending_value_write = True

            # Fresh state sample after write, matching v1.3.
            active = self.u8(device + OFF_ACTIVE)
            wno = self.u8(device + self.wno_off)
            transition = self.u32(device + OFF_TRANS)
            layers = self.u16(device + OFF_LAYERS)
            texture = self.i64(device + OFF_TEX)
            width = self.u32(device + OFF_W)
            height = self.u32(device + OFF_H)

        if active == 1 and wno != 0:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "red",
                "Not active",
                "VR started before the patch could take effect. "
                "Close HITMAN, start this tool first, then the game.",
            )
            return

        life = self.advance_lifecycle(
            self.last_trans,
            self.need_rel,
            transition,
            self.pending_value_write,
        )

        if life.transition_changed:
            self.log(f"transition {self.last_trans} -> {transition}")

        self.last_trans = life.last_transition
        self.need_rel = life.need_reload
        self.pending_value_write = False

        if life.reset_stable:
            self.stable_ready = 0
            self.stable_since = 0

        if sync.wrote:
            now = dt.datetime.now()

            if (now - self.last_write_log).total_seconds() >= 1:
                self.log(
                    f"values synchronised, transition={transition}, active={active}"
                )
                self.last_write_log = now

        if sync.error:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "red",
                "Renderer write failed",
                sync.error,
                warn,
            )
            return

        if active != 1:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state("amber", "Ready - start VR", ready, warn)
            return

        if not sync.initialized or not sync.fixed:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "amber",
                "Waiting for the VR renderer",
                "The device is still initialising. "
                "The fix will arm before its render state is built.",
                warn,
            )
            return

        if transition != 3 or layers != 2 or texture == 0:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "amber",
                "Waiting for a mission",
                "VR is running in two-layer mode. "
                "Load a mission and the fix becomes active.",
                warn,
            )
            return

        if self.need_rel:
            self.stable_ready = 0
            self.stable_since = 0

            self.show_state(
                "amber",
                "Reload this mission once",
                "The fix is set, but this mission was already running when it "
                "was applied. Reload it once and the image will be sharp everywhere.",
                warn,
            )

        else:
            stable_now = time.perf_counter_ns()

            if self.stable_since == 0:
                self.stable_since = stable_now

            if self.stable_ready < 3:
                self.stable_ready += 1

            stable_ms = (stable_now - self.stable_since) / 1_000_000.0

            if self.stable_ready < 3 or stable_ms < 250:
                self.show_state(
                    "amber",
                    "Finishing the mission load",
                    "The render values are correct. "
                    "Waiting briefly to make sure they remain stable.",
                    warn,
                )
            else:
                self.show_state(
                    "green",
                    "Active",
                    f"Sharp from edge to edge. Rendering {width} x {height} "
                    "per eye in two layers instead of four.",
                    warn,
                )

    def run(self) -> int:
        self.show_state(
            "grey",
            "Waiting for HITMAN",
            "Start the game whenever you like - including straight into VR. "
            "This tool does the rest.",
        )

        # WinForms timer in v1.3 uses Interval=15.
        interval_seconds = 0.015
        next_tick = time.monotonic()

        while not self.stopped:
            try:
                self.tick()
            except Exception as exc:
                self.show_state(
                    "red",
                    "Something went wrong",
                    f"{exc}  Close HITMAN and try again.",
                )

            next_tick += interval_seconds
            delay = next_tick - time.monotonic()

            if delay > 0:
                time.sleep(delay)
            else:
                # Do not run a burst of catch-up ticks.
                next_tick = time.monotonic()

        return 0

    def stop(self, *_args) -> None:
        self.stopped = True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Linux/Proton port of HitmanVRFoveationFix v1.3"
    )
    parser.add_argument(
        "--process-name",
        default="HITMAN3",
        help="HITMAN process name (default: HITMAN3)",
    )
    args = parser.parse_args()

    if os.name != "posix" or not Path("/proc").exists():
        print("This Linux port requires procfs.", file=sys.stderr)
        return 2

    if os.geteuid() != 0:
        print(
            "This tool needs permission to read/write HITMAN's process memory.\n"
            f"Run: sudo -E python3 {Path(__file__).resolve()}",
            file=sys.stderr,
        )
        return 2

    self_dir = Path(__file__).resolve().parent
    log_path = self_dir / "foveationfix.log"

    # Linux equivalent of Local\HitmanVRFoveationFix named mutex.
    lock_path = Path("/tmp/HitmanVRFoveationFix.lock")
    lock_file = lock_path.open("w")

    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(
            "HitmanVRFoveationFix is already running in this Linux session.",
            file=sys.stderr,
        )
        return 0

    fix = HitmanVRFoveationFix(args.process_name, log_path)

    restored_once = False

    def cleanup() -> None:
        nonlocal restored_once
        if restored_once:
            return
        restored_once = True

        try:
            restored = fix.restore()
            if not restored:
                print(
                    "[Close HITMAN] A live value could not be restored safely. "
                    "Closing the game always discards every in-memory change.",
                    file=sys.stderr,
                )
        finally:
            fix.detach()

    atexit.register(cleanup)
    signal.signal(signal.SIGINT, fix.stop)
    signal.signal(signal.SIGTERM, fix.stop)

    print("HitmanVRFoveationFix v1.3 - Linux/Proton continuous-guard experiment")
    print("Leave this terminal open while you play. Press Ctrl+C to turn off and restore.")

    rc = fix.run()
    cleanup()
    fix.log("closed")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
