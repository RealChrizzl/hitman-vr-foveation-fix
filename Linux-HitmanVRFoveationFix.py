#!/usr/bin/env python3
# Linux port developed with assistance from ChatGPT.
"""
HitmanVRFoveationFix v1.6.2 - Linux/Proton port

Based on RealChrizzl's Windows/PowerShell v1.6.1 implementation.

Linux v1.6.2 keeps the Windows v1.6.1 renderer behaviour unchanged and adds
Linux-specific simplified launch and packaging improvements: the Python file
is now directly executable, self-elevates through sudo when needed, keeps the
logfile owned by the invoking user, and carries the v1.6.1 unknown-build scan
optimisations.

v1.6 removes the save/reload mask race at its source:
  - Two renderer-code patches make HITMAN generate zero foveation-mask values
    itself whenever the renderer recalculates them.
  - Scale and mask device fields are no longer written by the tool.
  - The ~1 ms renderer guard and its ownership/rollback/reload machinery are
    removed.
  - Scale remains a read-only initialization/plausibility gate; mask becomes a
    read-only correctness check and must be zero once initialized.
  - Refraction readiness is proven by the outer owner path; CopyA/CopyB remain
    independently validated runtime-coverage diagnostics.

Linux-specific implementation:
  - /proc/<pid>/mem for process memory
  - ptrace for atomic thread suspension/context verification
  - remote mmap/mprotect for the private executable wrapper cave
  - terminal status output instead of WinForms
  - flock single-instance lock under /run

No game file is modified. All renderer/code changes are made in the running
process and disappear when HITMAN exits.
"""

from __future__ import annotations

import argparse
import atexit
import ctypes
import datetime as dt
import errno
import fcntl
import hashlib
import math
import os
import signal
import stat
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

FIX_VERSION = "1.6.2"
UPSTREAM_VERSION = "1.6.1"

# ===========================================================================
# VERIFIED PATH - HITMAN build 3.270.1
# ===========================================================================

VERIFIED_TIMESTAMP = 1781013974
VERIFIED_SHA256 = "B4FB04F460FD67E67F21264D7AD0D64BC081FBA62EC71E36B898D04DB9E8620D"

MANAGER_RVA = 0x03225D20
MANAGER_VTABLE_RVA = 0x01EF5398
MANAGER_DEVICE_OFFSET = 0x141A0
OCULUS_VTABLE_RVA = 0x01F016C0
OPENVR_VTABLE_RVA = 0x01EFE020
VERIFIED_WNO_OFF = 0x31B

OFF_ACTIVE = 0x319
OFF_TRANS = 0x4D8
OFF_W = 0x510
OFF_H = 0x514
OFF_LAYERS = 0x520
OFF_TEX = 0x530
OFF_FOV = 0x420
OFF_SCALE = 0x490
OFF_MASK = 0x4C0

MASK_FIX = bytes.fromhex("00 00 00 00 00 00 00 00")


@dataclass
class Site:
    name: str
    rva: int
    stock: bytes
    fix: bytes = b""


@dataclass
class HookDesc:
    name: str
    kind: str
    rva: int
    target_rva: int
    continuation_rva: int
    unit_offset: int
    stock: bytes
    counter_offset: int = 0


@dataclass
class HookSite(Site):
    kind: str = ""
    wrapper_address: int = 0
    wrapper: bytes = b""


VERIFIED_WNO_WRITERS = [
    Site("v1.3 WNO writer A", 0x011D8B9E, bytes.fromhex("0F 94 C1"), bytes.fromhex("B1 00 90")),
    Site("v1.3 WNO writer B", 0x011D8BC1, bytes.fromhex("0F 94 C0"), bytes.fromhex("B0 00 90")),
]
VERIFIED_PRIMARY_DEPTH_CB = [
    Site("v1.3 depth flag Oculus", 0x012C1EAC,
         bytes.fromhex("0F B6 87 1B 03 00 00"),
         bytes.fromhex("B8 01 00 00 00 90 90")),
    Site("v1.3 depth flag OpenVR", 0x012499CC,
         bytes.fromhex("0F B6 87 1B 03 00 00"),
         bytes.fromhex("B8 01 00 00 00 90 90")),
]
VERIFIED_VIEW_COUNT = Site(
    "v1.3 view count", 0x01161FE9,
    bytes.fromhex("80 B8 1B 03 00 00 00"),
    bytes.fromhex("48 85 E4 90 90 90 90"),
)

VERIFIED_VIEW_COUNT_2 = Site(
    "v1.5 view count 2", 0x01162E3C,
    bytes.fromhex("80 B9 1B 03 00 00 00"),
    bytes.fromhex("48 85 E4 90 90 90 90"),
)

VERIFIED_MASK_SOURCE = [
    Site("mask b zero at source", 0x011CDAC1,
         bytes.fromhex("F3 0F 59 C0"), bytes.fromhex("0F 57 C0 90")),
    Site("mask a zero at source", 0x011CDAC9,
         bytes.fromhex("F3 0F 59 D2"), bytes.fromhex("0F 57 D2 90")),
]

REFRACTION_DEPTH_ZERO = Site(
    "CopyRefractionDepth base slice zero", 0x0128FF20,
    bytes.fromhex("8B 6E 20"), bytes.fromhex("31 ED 90"))
CAMERA_STATE_4 = Site(
    "extended camera state", 0x011B4625,
    bytes.fromhex("44 38 B9 1B 03 00 00"), bytes.fromhex("48 85 E4 90 90 90 90"))
ASSAO_DEPTH_4 = Site(
    "four-view ASSAO depth preparation", 0x012886DA,
    bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90"))
CAMERA_RECORDS_4 = Site(
    "four-view camera records", 0x0129297E,
    bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90"))
OCCLUDER_STATE_4 = [
    Site("occluder matrix preprocess", 0x01298B1D,
         bytes.fromhex("44 38 A8 1B 03 00 00"), bytes.fromhex("48 85 E4 90 90 90 90")),
    Site("occluder matrix restore", 0x0129987C,
         bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90")),
]
SSR_FRUSTA_4 = Site(
    "four-view SSR frusta", 0x0129DE92,
    bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90"))
CORE_DRAW_GATES_4 = [
    Site("core DrawGate A", 0x01296BEF,
         bytes.fromhex("40 38 B0 1B 03 00 00"), bytes.fromhex("48 85 E4 90 90 90 90")),
    Site("core DrawGate B", 0x0129706C,
         bytes.fromhex("80 B8 1B 03 00 00 00"), bytes.fromhex("48 85 E4 90 90 90 90")),
]
CULL_SCATTER_4 = Site(
    "CullScatter instance multiplier four", 0x0127AABB,
    bytes.fromhex("41 8B 46 14 41 8B 0C 86"),
    bytes.fromhex("B9 04 00 00 00 90 90 90"))
MESH_COUNT_HOOK = Site(
    "transparent indexed-mesh instance multiplier", 0x0121C91A,
    bytes.fromhex("8B 41 14 41 8B E9 45 8B F0 8B F2 48 8B D9 8B 3C 81"))
WATER_PASS_CALL = Site(
    "DrawWaterRefractive camera call", 0x011B83CA,
    bytes.fromhex("48 8D 84 24 E0 01 00 00 48 89 5C 24 28 48 89 44 24 20 E8 7F 5E 0C 00"))
SPRITE_COUNT_GUARD = Site(
    "unrelated particle-lighting instance multiplier", 0x012EB2B4,
    bytes.fromhex("48 8B CB 44 8D 42 14 0F B7 74 C7 32 8B 43 14 0F AF 34 83"))

TRANSPARENT_PASS_CALL = HookDesc(
    "DrawRefractiveAndTransparent camera call", "Outer", 0x011B892A, 0x01290220,
    0x011B893C, 0x000,
    bytes.fromhex("48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 E4 78 0D 00"))
COPY_DEPTH_CALL_A = HookDesc(
    "CopyRefractionDepth call A", "CopyA", 0x01290BA2, 0x0128FE20,
    0x01290BB7, 0x400,
    bytes.fromhex("4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 69 F2 FF FF"),
    0x60)
COPY_DEPTH_CALL_B = HookDesc(
    "CopyRefractionDepth call B", "CopyB", 0x01291386, 0x0128FE20,
    0x0129139B, 0x600,
    bytes.fromhex("4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 85 EA FF FF"),
    0x80)

HOOK_KINDS = ("Outer", "CopyA", "CopyB")
HOOK_DESCS_VERIFIED = [COPY_DEPTH_CALL_A, COPY_DEPTH_CALL_B, TRANSPARENT_PASS_CALL]

VERIFIED_CODE = VERIFIED_WNO_WRITERS + VERIFIED_PRIMARY_DEPTH_CB + [VERIFIED_VIEW_COUNT, VERIFIED_VIEW_COUNT_2] + VERIFIED_MASK_SOURCE

CORE_VIEW_EXTENSION = [CAMERA_RECORDS_4] + CORE_DRAW_GATES_4 + OCCLUDER_STATE_4
LEGACY_TESTKIT3_SITES = [REFRACTION_DEPTH_ZERO, CAMERA_STATE_4, ASSAO_DEPTH_4, SSR_FRUSTA_4] + CORE_VIEW_EXTENSION
ALL_PROFILE_SITES = [VERIFIED_VIEW_COUNT, CULL_SCATTER_4] + LEGACY_TESTKIT3_SITES

# v1.4 keeps all earlier experimental profile sites stock except the selected
# v1.3 base sites and the three dynamic hook call blocks.
selected_rvas = {s.rva for s in VERIFIED_CODE}
VERIFIED_GUARDS = [s for s in ALL_PROFILE_SITES + [WATER_PASS_CALL, SPRITE_COUNT_GUARD, MESH_COUNT_HOOK]
                   if s.rva not in selected_rvas]

# Exact verified contexts from upstream v1.4.
VERIFIED_DIAGNOSTIC_CONTEXTS = [
    (0x012499A0, bytes.fromhex("50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 57 66 FD FF FF 4B 14 0F B6 87 1B 03 00 00")),
    (0x012C1E80, bytes.fromhex("C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 77 E1 F5 FF FF 4B 14 0F B6 87 1B 03 00 00")),
    (0x01296BEA, bytes.fromhex("B9 03 00 00 00 40 38 B0 1B 03 00 00 41 0F 44 CF 44 3B C9 0F 83")),
    (0x01297067, bytes.fromhex("B9 03 00 00 00 80 B8 1B 03 00 00 00 41 0F 44 C9 3B F1 0F 83")),
    (0x0128FF16, bytes.fromhex("48 8B B0 E0 00 00 00 8B 47 14 8B 6E 20 44 8B FD 8D 4D FF 03 4E 24 83 3C 87 01 44 0F 46 F9 48 85 DB")),
    (0x011B4619, bytes.fromhex("48 8B 0D A0 58 08 02 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84 6C 01 00 00 FF 90 30 01 00 00 0F 10 40 40")),
    (0x01292963, bytes.fromhex("BB 04 00 00 00 48 8B 05 51 75 FA 01 0F 28 3D EA 19 9B 00 B9 02 00 00 00 0F 28 EE 80 B8 1B 03 00 00 00 0F 29 B5 E0 07 00 00 0F 10 96 90 02 00 00 0F 44 D9 89 9D A0 0B 00 00 0F 29 95 F0 07")),
    (0x012886DA, bytes.fromhex("80 B8 1B 03 00 00 00 0F 84 32 03 00 00 F3 44 0F 10 05 F8 49 32 03")),
    (0x01298B11, bytes.fromhex("48 8B 05 A8 13 FA 01 B9 03 00 00 00 44 38 A8 1B 03 00 00 0F 44 CF 44 3B C1 73 79 41 8D 50 01 41 8B C0 8B")),
    (0x01299870, bytes.fromhex("48 8B 05 49 06 FA 01 B9 03 00 00 00 80 B8 1B 03 00 00 00 0F 44 CB 44 3B E9 73 4D 41 8D 55 01 41 8B CD 48")),
    (0x0129DE80, bytes.fromhex("48 8B 05 39 C0 F9 01 B9 02 00 00 00 41 BE 04 00 00 00 80 B8 1B 03 00 00 00 44 0F 44 F1 44 0F 28 25 6B C7 CB 00")),
    (0x0127AAAB, bytes.fromhex("74 0E F3 0F 10 84 24 28 01 00 00 F3 0F 11 04 38 41 8B 46 14 41 8B 0C 86 8B 82 60 61 00 00 89 8C 24 28 01 00 00 49 3B C0 74 0E F3 0F 10 84 24 28")),
    (0x0121C90A, bytes.fromhex("48 89 74 24 18 48 89 7C 24 20 41 56 48 83 EC 30 8B 41 14 41 8B E9 45 8B F0 8B F2 48 8B D9 8B 3C 81 E8 80 64 00 00 48 8B 8B F8 16 00 00 E8 24 40 FC FF 48 8B 8B 00 17 00 00")),
    (0x01290220, bytes.fromhex("4C 89 4C 24 20 48 89 4C 24 08 55 53 56 57 41 54 41 56 41 57 48 81 EC B0 01 00 00")),
    (0x01291BC2, bytes.fromhex("0F 28 BD 30 01 00 00 44 0F 28 85 20 01 00 00 44 0F 28 8D 10 01 00 00 48 8D A5 50 01 00 00 41 5F 41 5E 41 5C 5F 5E 5B 5D C3")),
    (0x0127E260, bytes.fromhex("4C 89 4C 24 20 4C 89 44 24 18 41 55 41 57")),
    (0x0127FA73, bytes.fromhex("48 81 C4 78 02 00 00 41 5F 41 5D C3")),
    (0x011B892A, bytes.fromhex("48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 E4 78 0D 00 48 8D 8C 24 60 02 00 00")),
    (0x011B83CA, bytes.fromhex("48 8D 84 24 E0 01 00 00 48 89 5C 24 28 48 89 44 24 20 E8 7F 5E 0C 00 48 85 DB 74 45")),
    (0x01290B90, bytes.fromhex("48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 69 F2 FF FF 48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D D8 92 FA 01 4C 8D 0D B1 F3 C6 00")),
    (0x01291374, bytes.fromhex("48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 85 EA FF FF 48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00 4C 8B 40 60 4D 85 C0")),
    (0x012EB2A4, bytes.fromhex("80 00 00 00 BA 01 00 00 00 4C 8B 4F 20 48 03 C0 48 8B CB 44 8D 42 14 0F B7 74 C7 32 8B 43 14 0F AF 34 83 E8 14 47 F3 FF 4C 8B 83 38 0F 00 00 33 C9 4D 85 C0 74 05 4D 8B 00 EB 03")),
    (0x0128FE20, bytes.fromhex("48 89 5C 24 10 48 89 6C 24 18 56 57 41 54 41 56 41 57 48 81 EC A0 00 00 00 48 8B 05 60 A0 FA 01")),
]

# Pattern path
SIGS = [
    (9, bytes.fromhex("B1 00 90"), "8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00",
     "two layers instead of four (writer A)"),
    (9, bytes.fromhex("B0 00 90"), "8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00",
     "two layers instead of four (writer B)"),
    (44, bytes.fromhex("B8 01 00 00 00 90 90"),
     "C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00",
     "full field of view, Oculus device"),
    (44, bytes.fromhex("B8 01 00 00 00 90 90"),
     "50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00",
     "full field of view, OpenVR device"),
    (12, bytes.fromhex("48 85 E4 90 90 90 90"),
     "74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF",
     "view count 4 - without this, geometry disappears"),
    (9, bytes.fromhex("48 85 E4 90 90 90 90"),
     "49 8B 8D A0 41 01 00 74 1A 80 B9 1B 03 00 00 00 BF 02 00 00",
     "view count 4, second site - without this, one eye keeps an oval mask"),
    (14, bytes.fromhex("0F 57 C0 90"),
     "F3 0F 10 41 30 F3 0F 5E 41 18 F3 0F 5E D1 F3 0F 59 C0 41 0F 28 C8 F3 0F 59 D2 F3 0F 11 81 B4 00 00 00 F3 0F 10 41 44 F3 0F 58 C0 F3 0F 11 91 B0 00 00 00 0F 11 99 80 00 00 00 41 0F 28 D8 41 0F 28 D0",
     "mask b zero at source - the black centre circle"),
    (22, bytes.fromhex("0F 57 D2 90"),
     "F3 0F 10 41 30 F3 0F 5E 41 18 F3 0F 5E D1 F3 0F 59 C0 41 0F 28 C8 F3 0F 59 D2 F3 0F 11 81 B4 00 00 00 F3 0F 10 41 44 F3 0F 58 C0 F3 0F 11 91 B0 00 00 00 0F 11 99 80 00 00 00 41 0F 28 D8 41 0F 28 D0",
     "mask a zero at source - the overlay pass"),
]

HOOK_SIGS = [
    dict(name="DrawRefractiveAndTransparent camera call", kind="Outer", hit=0, length=18,
         call_offset=13, unit_offset=0x000, counter_offset=0,
         pattern="48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 ?? ?? ?? ?? 48 8D 8C 24 60 02 00 00"),
    dict(name="CopyRefractionDepth call A", kind="CopyA", hit=18, length=21,
         call_offset=16, unit_offset=0x400, counter_offset=0x60,
         pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D ?? ?? ?? ?? 4C 8D 0D ?? ?? ?? ??"),
    dict(name="CopyRefractionDepth call B", kind="CopyB", hit=18, length=21,
         call_offset=16, unit_offset=0x600, counter_offset=0x80,
         pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00 4C 8B 40 60 4D 85 C0"),
]

SIG_DEVICE_PAT = "48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"
SIG_DEVICE_REL = 3
SIG_DEVICE_DSP = 15


class FixError(RuntimeError):
    pass


@dataclass
class LifecycleResult:
    last_transition: int
    transition_changed: bool
    reset_stable: bool


# ===========================================================================
# x86-64 ptrace helpers
# ===========================================================================

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
PTRACE_PEEKTEXT = 1
PTRACE_POKETEXT = 4
PTRACE_CONT = 7
PTRACE_GETREGS = 12
PTRACE_SETREGS = 13
PTRACE_ATTACH = 16
PTRACE_DETACH = 17
PTRACE_SETOPTIONS = 0x4200
PTRACE_O_EXITKILL = 0x00100000
WAIT_WALL = 0x40000000

SYS_MMAP = 9
SYS_MPROTECT = 10
PROT_READ = 1
PROT_WRITE = 2
PROT_EXEC = 4
MAP_PRIVATE = 2
MAP_ANONYMOUS = 0x20


class UserRegsStruct(ctypes.Structure):
    _fields_ = [
        ("r15", ctypes.c_ulonglong), ("r14", ctypes.c_ulonglong),
        ("r13", ctypes.c_ulonglong), ("r12", ctypes.c_ulonglong),
        ("rbp", ctypes.c_ulonglong), ("rbx", ctypes.c_ulonglong),
        ("r11", ctypes.c_ulonglong), ("r10", ctypes.c_ulonglong),
        ("r9", ctypes.c_ulonglong), ("r8", ctypes.c_ulonglong),
        ("rax", ctypes.c_ulonglong), ("rcx", ctypes.c_ulonglong),
        ("rdx", ctypes.c_ulonglong), ("rsi", ctypes.c_ulonglong),
        ("rdi", ctypes.c_ulonglong), ("orig_rax", ctypes.c_ulonglong),
        ("rip", ctypes.c_ulonglong), ("cs", ctypes.c_ulonglong),
        ("eflags", ctypes.c_ulonglong), ("rsp", ctypes.c_ulonglong),
        ("ss", ctypes.c_ulonglong), ("fs_base", ctypes.c_ulonglong),
        ("gs_base", ctypes.c_ulonglong), ("ds", ctypes.c_ulonglong),
        ("es", ctypes.c_ulonglong), ("fs", ctypes.c_ulonglong),
        ("gs", ctypes.c_ulonglong),
    ]


def ptrace(request: int, pid: int, addr=0, data=0) -> int:
    ctypes.set_errno(0)
    result = libc.ptrace(
        ctypes.c_uint(request), ctypes.c_uint(pid),
        ctypes.c_void_p(addr) if isinstance(addr, int) else addr,
        ctypes.c_void_p(data) if isinstance(data, int) else data,
    )
    err = ctypes.get_errno()
    if result == -1 and err:
        raise OSError(err, os.strerror(err))
    return int(result)


def get_regs(tid: int) -> UserRegsStruct:
    regs = UserRegsStruct()
    if libc.ptrace(PTRACE_GETREGS, tid, None, ctypes.byref(regs)) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return regs


def set_regs(tid: int, regs: UserRegsStruct) -> None:
    if libc.ptrace(PTRACE_SETREGS, tid, None, ctypes.byref(regs)) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def wait_stopped(tid: int) -> int:
    while True:
        try:
            got, status = os.waitpid(tid, WAIT_WALL)
            if got == tid:
                return status
        except InterruptedError:
            continue


class ThreadStopSet:
    def __init__(self, pid: int):
        self.pid = pid
        self.tids: list[int] = []

    def _tasks(self) -> list[int]:
        try:
            return sorted(int(p.name) for p in Path(f"/proc/{self.pid}/task").iterdir() if p.name.isdigit())
        except OSError:
            return []

    def suspend_all(self) -> list[int]:
        seen = set()
        self.tids = []
        try:
            for _round in range(3):
                added = 0
                for tid in self._tasks():
                    if tid in seen:
                        continue
                    try:
                        ptrace(PTRACE_ATTACH, tid)
                        # Track the tracee immediately: every later step can fail,
                        # and exception cleanup must still be able to detach it.
                        self.tids.append(tid)
                        wait_stopped(tid)
                        # If this tracer dies while HITMAN is deliberately
                        # suspended, the kernel must kill the tracee rather
                        # than detach it back into a potentially unknown
                        # partially-patched state.
                        ptrace(PTRACE_SETOPTIONS, tid, 0, PTRACE_O_EXITKILL)
                    except OSError as exc:
                        if exc.errno in (errno.ESRCH, errno.ECHILD):
                            # The just-attached thread disappeared before setup
                            # completed. Do not carry a dead TID into the live set.
                            if tid in self.tids:
                                self.tids.remove(tid)
                            continue
                        raise
                    seen.add(tid)
                    added += 1
                if added == 0:
                    break
                time.sleep(0.005)

            current = set(self._tasks())
            if not current.issubset(seen):
                raise FixError("game thread list did not become stable")
            return list(self.tids)
        except Exception:
            self.resume_all()
            raise

    def resume_all(self) -> bool:
        ok = True
        pending = list(self.tids)
        self.tids.clear()
        for tid in reversed(pending):
            try:
                ptrace(PTRACE_DETACH, tid, 0, 0)
            except OSError as exc:
                if exc.errno != errno.ESRCH:
                    ok = False
        return ok

    def rips_outside(self, ranges: list[tuple[int, int]]) -> bool:
        for tid in self.tids:
            regs = get_regs(tid)
            for start, end in ranges:
                if start <= regs.rip < end:
                    return False
        return True

    def remote_syscall(self, tid: int, number: int, args: tuple[int, ...]) -> int:
        """
        Execute one Linux syscall in a stopped target thread, then restore the
        original code bytes and register state. All other game threads remain
        stopped.
        """
        saved = get_regs(tid)
        rip = int(saved.rip)

        ctypes.set_errno(0)
        word = libc.ptrace(PTRACE_PEEKTEXT, tid, ctypes.c_void_p(rip), None)
        err = ctypes.get_errno()
        if word == -1 and err:
            raise OSError(err, os.strerror(err))

        word_u = ctypes.c_ulonglong(word).value
        original = struct.pack("<Q", word_u)
        patched = bytearray(original)
        patched[:3] = b"\x0f\x05\xcc"  # syscall ; int3
        patched_word = struct.unpack("<Q", patched)[0]

        regs = UserRegsStruct()
        ctypes.memmove(ctypes.byref(regs), ctypes.byref(saved), ctypes.sizeof(saved))
        regs.rax = number
        regs.orig_rax = 0xFFFFFFFFFFFFFFFF
        regs.rip = rip

        vals = list(args) + [0] * (6 - len(args))
        regs.rdi, regs.rsi, regs.rdx, regs.r10, regs.r8, regs.r9 = [v & 0xFFFFFFFFFFFFFFFF for v in vals[:6]]

        try:
            ptrace(PTRACE_POKETEXT, tid, rip, patched_word)
            set_regs(tid, regs)
            ptrace(PTRACE_CONT, tid, 0, 0)
            status = wait_stopped(tid)
            if not os.WIFSTOPPED(status):
                raise FixError("remote syscall thread did not stop")
            stop_signal = os.WSTOPSIG(status)
            if stop_signal != signal.SIGTRAP:
                raise FixError(
                    f"remote syscall stopped on unexpected signal {stop_signal}"
                )
            after = get_regs(tid)
            expected_rip = rip + 3  # syscall (2 bytes) + int3 (1 byte)
            if int(after.rip) != expected_rip:
                raise FixError(
                    f"remote syscall SIGTRAP had unexpected RIP 0x{int(after.rip):X} "
                    f"(expected 0x{expected_rip:X})"
                )
            result_u = int(after.rax)
            result = ctypes.c_longlong(result_u).value
        finally:
            try:
                ptrace(PTRACE_POKETEXT, tid, rip, word_u)
            finally:
                set_regs(tid, saved)

        if result < 0 and result >= -4095:
            raise OSError(-result, os.strerror(-result))
        return result


# ===========================================================================
# Wrapper byte builder
# ===========================================================================

class ByteBuilder:
    def __init__(self, origin: int):
        self.origin = origin
        self.data = bytearray()
        self.labels: dict[str, int] = {}
        self.branches: list[tuple[int, int, str]] = []

    def emit(self, data: bytes) -> None:
        self.data += data

    def hex(self, text: str) -> None:
        self.emit(bytes.fromhex(" ".join(text.split())))

    def label(self, name: str) -> None:
        if name in self.labels:
            raise FixError("duplicate wrapper label")
        self.labels[name] = len(self.data)

    def j8(self, opcode: int, target: str) -> None:
        self.data.append(opcode)
        pos = len(self.data)
        self.data.append(0)
        self.branches.append((pos, 1, target))

    def j32(self, opcode: bytes, target: str) -> None:
        self.emit(opcode)
        pos = len(self.data)
        self.data += b"\0" * 4
        self.branches.append((pos, 4, target))

    def rip32(self, prefix: bytes, target: int) -> None:
        self.emit(prefix)
        next_addr = self.origin + len(self.data) + 4
        disp = target - next_addr
        if not -(1 << 31) <= disp < (1 << 31):
            raise FixError("wrapper RIP target out of range")
        self.emit(struct.pack("<i", disp))

    def finish(self) -> bytes:
        for pos, size, target in self.branches:
            if target not in self.labels:
                raise FixError("missing wrapper label")
            disp = self.labels[target] - (pos + size)
            if size == 1:
                if not -128 <= disp <= 127:
                    raise FixError("short wrapper branch out of range")
                self.data[pos] = disp & 0xFF
            else:
                if not -(1 << 31) <= disp < (1 << 31):
                    raise FixError("near wrapper branch out of range")
                self.data[pos:pos + 4] = struct.pack("<i", disp)
        return bytes(self.data)


def build_outer_unit(unit: int, target: int, change_count: bool = False) -> bytes:
    data = unit + 0x1000
    b = ByteBuilder(unit)
    b.hex("F3 0F 1E FA")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x30)
    b.hex("""
48 8B 8C 24 C8 00 00 00
48 89 44 24 28
48 83 EC 78
4C 8B 9C 24 A0 00 00 00 4C 89 5C 24 20
4C 8B 9C 24 A8 00 00 00 4C 89 5C 24 28
4C 8B 9C 24 B0 00 00 00 4C 89 5C 24 30
4C 8B 9C 24 B8 00 00 00 4C 89 5C 24 38
4C 8B 9C 24 C0 00 00 00 4C 89 5C 24 40
4C 8B 9C 24 C8 00 00 00 4C 89 5C 24 48
48 89 4C 24 50
C7 44 24 5C 00 00 00 00
""")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x00)
    b.hex("8B 41 14 89 44 24 58")
    b.rip32(bytes.fromhex("3B 05"), data + 0x24)
    b.j8(0x76, "max_top_ok")
    b.rip32(bytes.fromhex("89 05"), data + 0x24)
    b.label("max_top_ok")
    b.hex("83 F8 04")
    b.j8(0x77, "bad_count")
    b.hex("44 8B 14 81")
    b.rip32(bytes.fromhex("44 89 15"), data + 0x20)
    b.hex("41 83 FA 04")
    b.j8(0x74, "count_four")
    b.hex("41 83 FA 01")
    b.j32(bytes.fromhex("0F 84"), "call_target")
    b.hex("41 83 FA 02")
    b.j8(0x74, "count_two")
    b.label("bad_count")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x18)
    b.j32(bytes.fromhex("E9"), "call_target")

    b.label("count_two")
    b.rip32(bytes.fromhex("4C 8B 1D"), data + 0x40)
    b.hex("4D 85 DB")
    b.j8(0x74, "call_target")
    b.j32(bytes.fromhex("E9"), "owner_conflict")

    b.label("count_four")
    b.rip32(bytes.fromhex("4C 8B 1D"), data + 0x30)
    b.hex("49 83 FB 01")
    b.j8(0x75, "owner_conflict")
    b.hex("33 C0")
    b.rip32(bytes.fromhex("F0 48 0F B1 0D"), data + 0x40)
    b.j8(0x75, "owner_conflict")
    b.hex("65 4C 8B 14 25 48 00 00 00")
    b.rip32(bytes.fromhex("4C 89 15"), data + 0x38)
    b.hex("80 4C 24 5C 01")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x48)
    if change_count:
        b.hex("8B 44 24 58 C7 04 81 02 00 00 00 80 4C 24 5C 02")
        b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x08)
    b.j32(bytes.fromhex("E9"), "call_target")

    b.label("owner_conflict")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x28)

    b.label("call_target")
    b.hex("48 B8")
    b.emit(struct.pack("<Q", target))
    b.hex("FF D0 48 89 44 24 60")

    b.hex("F6 44 24 5C 02")
    b.j8(0x74, "after_restore")
    b.hex("48 8B 4C 24 50 8B 44 24 58 83 F8 04")
    b.j8(0x77, "restore_bad")
    b.hex("83 3C 81 02")
    b.j8(0x75, "restore_bad")
    b.hex("C7 04 81 04 00 00 00")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x10)
    b.hex("39 41 14")
    b.j8(0x75, "restore_bad")
    b.j8(0xEB, "after_restore")
    b.label("restore_bad")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x28)

    b.label("after_restore")
    b.hex("F6 44 24 5C 01")
    b.j8(0x74, "finish")
    b.hex("48 8B 4C 24 50")
    b.rip32(bytes.fromhex("4C 8B 1D"), data + 0x40)
    b.hex("4C 3B D9")
    b.j8(0x75, "release_bad")
    b.hex("65 4C 8B 14 25 48 00 00 00")
    b.rip32(bytes.fromhex("4C 3B 15"), data + 0x38)
    b.j8(0x75, "release_bad")
    b.rip32(bytes.fromhex("4C 8B 1D"), data + 0x30)
    b.hex("49 83 FB 01")
    b.j8(0x75, "release_bad")
    b.hex("45 33 D2")
    b.rip32(bytes.fromhex("4C 89 15"), data + 0x38)
    b.hex("48 8B C1")
    b.rip32(bytes.fromhex("F0 4C 0F B1 15"), data + 0x40)
    b.j8(0x75, "release_bad")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x50)
    b.j8(0xEB, "finish")
    b.label("release_bad")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x28)

    b.label("finish")
    b.rip32(bytes.fromhex("F0 48 FF 0D"), data + 0x30)
    b.hex("48 8B 44 24 60 48 83 C4 78 C3")
    return b.finish()


def build_copy_unit(call: HookDesc, unit: int, target: int, from_count: int = 4, to_count: int = 2) -> bytes:
    if (from_count, to_count) not in ((4, 2), (2, 4)):
        raise FixError("unsupported CopyRefractionDepth count scope")
    if call.counter_offset not in (0x60, 0x80):
        raise FixError("invalid copy telemetry block")

    data = unit + (0x1000 - call.unit_offset)
    co = call.counter_offset
    b = ByteBuilder(unit)
    b.hex("F3 0F 1E FA")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + co + 0x18)
    b.hex("""
4D 8B C4
8B 41 04
44 8B 09
48 8B CE
48 83 EC 58
4C 8B 9C 24 88 00 00 00
4C 89 5C 24 28
89 44 24 20
48 89 4C 24 38
C7 44 24 34 00 00 00 00
""")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + co)
    b.hex("8B 41 14 89 44 24 30")
    b.rip32(bytes.fromhex("3B 05"), data + 0x24)
    b.j8(0x76, "max_top_ok")
    b.rip32(bytes.fromhex("89 05"), data + 0x24)
    b.label("max_top_ok")
    b.hex("83 F8 04")
    b.j8(0x77, "bad_count")
    b.hex("44 8B 1C 81")
    b.rip32(bytes.fromhex("44 89 1D"), data + 0x20)

    b.rip32(bytes.fromhex("48 8B 05"), data + 0x40)
    b.hex("48 85 C0")
    b.j8(0x74, "no_owner")
    b.hex("48 3B C1")
    b.j8(0x75, "owner_bad")
    b.hex("65 4C 8B 14 25 48 00 00 00")
    b.rip32(bytes.fromhex("4C 3B 15"), data + 0x38)
    b.j8(0x75, "owner_bad")
    b.rip32(bytes.fromhex("48 8B 05"), data + 0x30)
    b.hex("48 83 F8 01")
    b.j8(0x75, "owner_bad")
    b.j8(0xEB, "owner_ok")

    b.label("no_owner")
    b.hex("41 83 FB 01")
    b.j8(0x74, "call_target")
    b.hex("41 83 FB 02")
    b.j8(0x74, "call_target")
    b.j8(0xEB, "owner_bad")

    b.label("owner_ok")
    b.hex("8B 44 24 30")
    b.hex(f"41 83 FB {from_count:02X}")
    b.j8(0x74, "change_count")
    b.j8(0xEB, "bad_count")

    b.label("change_count")
    b.hex(f"C7 04 81 {to_count:02X} 00 00 00 C6 44 24 34 01")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + co + 0x08)
    b.j8(0xEB, "call_target")

    b.label("bad_count")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x18)
    b.j8(0xEB, "call_target")

    b.label("owner_bad")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x28)

    b.label("call_target")
    b.hex("48 B8")
    b.emit(struct.pack("<Q", target))
    b.hex("FF D0 48 89 44 24 40")
    b.hex("80 7C 24 34 01")
    b.j8(0x75, "finish")
    b.hex("48 8B 4C 24 38 8B 44 24 30 83 F8 04")
    b.j8(0x77, "restore_bad")
    b.hex(f"83 3C 81 {to_count:02X}")
    b.j8(0x75, "restore_bad")
    b.hex(f"C7 04 81 {from_count:02X} 00 00 00")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + co + 0x10)
    b.hex("39 41 14")
    b.j8(0x75, "restore_bad")
    b.j8(0xEB, "finish")

    b.label("restore_bad")
    b.rip32(bytes.fromhex("F0 48 FF 05"), data + 0x28)

    b.label("finish")
    b.rip32(bytes.fromhex("F0 48 FF 0D"), data + co + 0x18)
    b.hex("48 8B 44 24 40 48 83 C4 58 C3")
    return b.finish()


def build_call_patch(call: HookDesc, cave: int) -> bytes:
    length = len(call.stock)
    if length < 16 or length > 127:
        raise FixError("invalid hook patch-block length")
    out = bytearray(b"\x90" * length)
    head = bytes((0xFF, 0x15, 0x02, 0x00, 0x00, 0x00, 0xEB, (length - 8) & 0xFF))
    out[:8] = head
    out[8:16] = struct.pack("<Q", cave + call.unit_offset)
    return bytes(out)


# ===========================================================================
# Main fix class
# ===========================================================================

class HitmanFix:
    def __init__(self, process_name: str, log_path: Path):
        self.process_name = process_name
        self.log_path = log_path

        self.mem_fd: Optional[int] = None
        self.pid = 0
        self.base = 0
        self.exe_path: Optional[Path] = None
        self.mode = ""

        self.sites: list[Site] = []
        self.guard_sites: list[Site] = []
        self.written_sites: list[Site] = []
        self.hook_descs: list[HookDesc] = []
        self.hook_sites: list[HookSite] = []
        self.hook_cave = 0
        self.hook_prepared = False
        self.last_hook_log = 0.0
        self.last_integrity_check = 0.0
        self.hook_progress: dict[str, tuple[int, float]] = {}

        self.dev_slot = 0
        self.wno_off = VERIFIED_WNO_OFF
        self.patched = False

        self.dev = 0
        self.last_trans = -1
        self.stable_ready = 0
        self.stable_since = 0.0

        self.runtime_loaded = False
        self.last_runtime_check = 0.0
        self.last_attach_scan = 0.0

        self.last_status = ""
        self.fatal = ""
        self.stopped = False
        self.unsafe_code_state = False
        self.suspended = ThreadStopSet(0)

    # ----- logging/status ---------------------------------------------------

    def log(self, text: str) -> None:
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(self.log_path, flags, 0o600)
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode):
                    raise OSError("log is not regular file")

                # Keep the log owned by the normal user even though the tool
                # self-elevates through sudo for process-memory access.
                sudo_uid = os.environ.get("SUDO_UID")
                sudo_gid = os.environ.get("SUDO_GID")
                if sudo_uid is not None and sudo_gid is not None:
                    os.fchown(fd, int(sudo_uid), int(sudo_gid))
                os.fchmod(fd, 0o600)

                line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S}  [v{FIX_VERSION}] {text}\n"
                os.write(fd, line.encode())
            finally:
                os.close(fd)
        except OSError:
            pass

    def status(self, head: str, body: str) -> None:
        key = head + "\n" + body
        if key != self.last_status:
            self.last_status = key
            print(f"[{head}] {body}", flush=True)

    # ----- memory -----------------------------------------------------------

    def rb(self, addr: int, size: int) -> bytes:
        if self.mem_fd is None:
            raise FixError("process memory is not open")
        try:
            data = os.pread(self.mem_fd, size, addr)
        except OSError as exc:
            raise FixError(f"read failed at 0x{addr:X}") from exc
        if len(data) != size:
            raise FixError(f"read failed at 0x{addr:X}")
        return data

    def wb(self, addr: int, data: bytes) -> None:
        if self.mem_fd is None:
            raise FixError("process memory is not open")
        try:
            n = os.pwrite(self.mem_fd, data, addr)
        except OSError as exc:
            raise FixError(f"write failed at 0x{addr:X}") from exc
        if n != len(data):
            raise FixError(f"write failed at 0x{addr:X}")

    def u8(self, a): return self.rb(a, 1)[0]
    def u16(self, a): return struct.unpack("<H", self.rb(a, 2))[0]
    def u32(self, a): return struct.unpack("<I", self.rb(a, 4))[0]
    def i64(self, a): return struct.unpack("<q", self.rb(a, 8))[0]

    # ----- PE / search ------------------------------------------------------

    @staticmethod
    def read_pe(path: Path) -> tuple[int, int, bytes]:
        data = path.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        stamp = struct.unpack_from("<i", data, pe + 8)[0]
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        opt = struct.unpack_from("<H", data, pe + 20)[0]
        for i in range(nsec):
            o = pe + 24 + opt + i * 40
            name = data[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            if name == ".text":
                size = struct.unpack_from("<I", data, o + 16)[0]
                rva = struct.unpack_from("<I", data, o + 12)[0]
                off = struct.unpack_from("<I", data, o + 20)[0]
                return stamp, rva, data[off:off + size]
        raise FixError("no .text section")

    @staticmethod
    def find_sig(hay: bytes, pattern: str) -> list[int]:
        """Find at most two matches with the same fail-closed semantics.

        Windows v1.6.1 moved the expensive interpreted signature scan into
        compiled code. Python's bytes.find() provides the equivalent fast anchor
        search here; wildcard comparison and uniqueness requirements are unchanged.
        """
        vals = [-1 if x == "??" else int(x, 16) for x in pattern.split()]
        anchor = next((i for i, x in enumerate(vals) if x >= 0), None)
        if anchor is None:
            return []
        hits: list[int] = []
        n = len(vals)
        limit = len(hay) - n
        if limit < 0:
            return hits
        anchor_byte = bytes((vals[anchor],))
        search_from = anchor
        search_end = limit + anchor + 1
        while True:
            found = hay.find(anchor_byte, search_from, search_end)
            if found < 0:
                break
            p = found - anchor
            if all(v < 0 or hay[p + i] == v for i, v in enumerate(vals)):
                hits.append(p)
                if len(hits) > 1:
                    break
            search_from = found + 1
        return hits

    # ----- process discovery ------------------------------------------------

    def find_processes(self) -> list[int]:
        wanted = self.process_name.lower()
        wanted_exe = wanted if wanted.endswith(".exe") else wanted + ".exe"
        out = []
        for p in Path("/proc").iterdir():
            if not p.name.isdigit():
                continue
            try:
                comm = (p / "comm").read_text(errors="replace").strip().lower()
            except OSError:
                comm = ""
            try:
                cmd = (p / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").lower()
            except OSError:
                cmd = ""
            base = cmd.split(" ", 1)[0].replace("\\", "/").rsplit("/", 1)[-1]
            if comm in (wanted, wanted_exe) or base in (wanted, wanted_exe):
                out.append(int(p.name))
        return out

    def parse_maps(self, pid: int):
        rows = []
        with open(f"/proc/{pid}/maps", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip().split(None, 5)
                if len(parts) < 5:
                    continue
                s, e = parts[0].split("-")
                rows.append((int(s, 16), int(e, 16), parts[1], int(parts[2], 16),
                             parts[5] if len(parts) == 6 else ""))
        return rows

    def locate_module(self, pid: int) -> tuple[int, Path]:
        wanted = self.process_name.lower()
        wanted_exe = wanted if wanted.endswith(".exe") else wanted + ".exe"
        candidates = []
        for start, end, perms, offset, path in self.parse_maps(pid):
            clean = path.replace("\\040", " ")
            base = clean.replace("\\", "/").rsplit("/", 1)[-1].lower()
            if base in (wanted, wanted_exe):
                candidates.append((start, offset, Path(clean)))
        if not candidates:
            raise FixError("Could not locate HITMAN3.exe mapping")
        zero = [x for x in candidates if x[1] == 0]
        start, _, path = min(zero or candidates, key=lambda x: x[0])
        return start, path

    def alive(self) -> bool:
        return self.pid > 0 and Path(f"/proc/{self.pid}").exists()

    # ----- attach -----------------------------------------------------------

    def attach(self) -> bool:
        pids = self.find_processes()
        if not pids:
            return False
        if len(pids) > 1:
            self.fatal = "More than one HITMAN process is running. Close them all and start the game once."
            return False
        pid = pids[0]
        try:
            base, path = self.locate_module(pid)
            stamp, text_rva, text = self.read_pe(path)
        except Exception:
            return False

        sites: list[Site] = []
        guards: list[Site] = []
        hooks: list[HookDesc] = []
        mode = ""
        slot = 0
        wno = VERIFIED_WNO_OFF

        if stamp == VERIFIED_TIMESTAMP:
            # Only the verified build uses the executable hash. Unknown builds
            # are validated entirely by unique signatures, matching Windows v1.6.1.
            try:
                digest = hashlib.sha256(path.read_bytes()).hexdigest().upper()
            except OSError:
                self.fatal = "Could not verify the game executable."
                return False
            if digest != VERIFIED_SHA256:
                self.fatal = "This executable has the verified build number but different code. Nothing was changed."
                return False
            for rva, expected in VERIFIED_DIAGNOSTIC_CONTEXTS:
                off = rva - text_rva
                if off < 0 or off + len(expected) > len(text) or text[off:off + len(expected)] != expected:
                    self.fatal = f"Verified instruction context mismatch at RVA 0x{rva:X}. Nothing was changed."
                    return False
            mode = "verified"
            sites = [Site(s.name, s.rva, s.stock, s.fix) for s in VERIFIED_CODE]
            guards = [Site(s.name, s.rva, s.stock) for s in VERIFIED_GUARDS]
            hooks = list(HOOK_DESCS_VERIFIED)
        else:
            mode = "scanned"
            self.status(
                "Scanning this HITMAN build",
                "This is not the verified build; locating code by signature. Please wait before starting VR.",
            )
            scan_started = time.monotonic()
            for hit, fix, pattern, what in SIGS:
                matches = self.find_sig(text, pattern)
                if len(matches) != 1:
                    self.fatal = f"The code for '{what}' could not be located uniquely. Nothing was changed."
                    return False
                p = matches[0]
                stock = text[p + hit:p + hit + len(fix)]
                sites.append(Site(what, text_rva + p + hit, stock, fix))

            for sig in HOOK_SIGS:
                matches = self.find_sig(text, sig["pattern"])
                if len(matches) != 1:
                    self.fatal = f"The v1.4 refraction code for '{sig['name']}' could not be located uniquely."
                    return False
                p = matches[0] + sig["hit"]
                stock = text[p:p + sig["length"]]
                co = sig["call_offset"]
                if stock[co] != 0xE8:
                    self.fatal = "Located v1.4 call has unexpected instruction shape."
                    return False
                rel = struct.unpack_from("<i", stock, co + 1)[0]
                rva = text_rva + p
                target = rva + co + 5 + rel
                if not text_rva <= target < text_rva + len(text):
                    self.fatal = "Located v1.4 target falls outside executable code."
                    return False
                hooks.append(HookDesc(sig["name"], sig["kind"], rva, target,
                                      rva + sig["length"], sig["unit_offset"], stock,
                                      sig["counter_offset"]))
            copy_targets = {h.target_rva for h in hooks if h.kind.startswith("Copy")}
            if len(copy_targets) != 1:
                self.fatal = "The two refraction-depth calls do not share one target."
                return False

            m = self.find_sig(text, SIG_DEVICE_PAT)
            if len(m) != 1:
                self.fatal = "The VR device reference could not be located uniquely."
                return False
            p = m[0]
            rel = struct.unpack_from("<i", text, p + SIG_DEVICE_REL)[0]
            slot = text_rva + p + 7 + rel
            wno = struct.unpack_from("<I", text, p + SIG_DEVICE_DSP)[0]
            if not 0 < wno <= 0x4000:
                self.fatal = "Implausible device layout."
                return False

            scan_ms = int((time.monotonic() - scan_started) * 1000)
            self.log(
                f"signature scan finished in {scan_ms} ms over {len(text)} bytes of .text, "
                f"{len(SIGS)} base + {len(HOOK_SIGS)} refraction + 1 device pattern"
            )

        try:
            mem_fd = os.open(f"/proc/{pid}/mem", os.O_RDWR)
        except OSError:
            self.fatal = "Access denied. Run this tool with sudo."
            return False

        self.mem_fd = mem_fd
        self.pid = pid
        self.base = base
        self.exe_path = path
        self.mode = mode
        self.sites = sites
        self.guard_sites = guards
        self.hook_descs = hooks
        self.dev_slot = slot
        self.wno_off = wno
        self.suspended = ThreadStopSet(pid)
        self.log(f"attached pid {pid}, build {stamp}, mode {mode}, base sites {len(sites)}, guards {len(guards)}, v1.4 calls {len(hooks)}")
        return True

    # ----- device -----------------------------------------------------------

    def dev_plausible(self, d: int) -> bool:
        if not 0x10000 <= d <= 0x7FFFFFFFFFFF:
            return False
        try:
            fb = self.rb(d + OFF_FOV, 16)
            for i in range(4):
                f = struct.unpack_from("<f", fb, i * 4)[0]
                if not 0.2 <= f <= 3.0:
                    return False
            return self.u8(d + OFF_ACTIVE) <= 1
        except Exception:
            return False

    def get_dev(self) -> int:
        if self.mode == "verified":
            mgr = self.base + MANAGER_RVA
            if self.i64(mgr) != self.base + MANAGER_VTABLE_RVA:
                return 0
            d = self.i64(mgr + MANAGER_DEVICE_OFFSET)
            if not d:
                return 0
            vt = self.i64(d)
            if vt not in (self.base + OCULUS_VTABLE_RVA, self.base + OPENVR_VTABLE_RVA):
                return -1
            return d
        try:
            d = self.i64(self.base + self.dev_slot)
        except Exception:
            return 0
        return d if self.dev_plausible(d) else 0

    def vr_start_state(self) -> int:
        try:
            d = self.get_dev()
            if d == -1:
                return -1
            if d == 0:
                return 0
            active = self.u8(d + OFF_ACTIVE)
            return active if active in (0, 1) else -1
        except Exception:
            return -1

    def runtime_loaded_now(self) -> bool:
        try:
            text = Path(f"/proc/{self.pid}/maps").read_text(errors="replace").lower()
        except OSError:
            return False
        return "openvr_api" in text or "libovrrt" in text

    # ----- renderer validation ---------------------------------------------

    @staticmethod
    def floats_in_range(data: bytes, count: int, lo: float, hi: float) -> bool:
        for i in range(count):
            f = struct.unpack_from("<f", data, i * 4)[0]
            if math.isnan(f) or math.isinf(f) or f < lo or f > hi:
                return False
        return True

    def check_render_values(self, d: int) -> tuple[bool, bool]:
        # v1.6 never writes FOV, scale or mask device fields. FOV and scale are
        # initialization/plausibility gates only.
        fov = self.rb(d + OFF_FOV, 16)
        if not self.floats_in_range(fov, 4, 0.2, 3.0):
            return False, False

        scale = self.rb(d + OFF_SCALE, 16)
        if not self.floats_in_range(scale, 4, 0.05, 20.0):
            return False, False

        # HITMAN now computes these itself. Once the device block is initialized,
        # any readable non-zero mask means the source patch did not take.
        mask = self.rb(d + OFF_MASK, 8)
        return True, mask == MASK_FIX

    # ----- hook cave --------------------------------------------------------

    def allocate_hook_cave(self) -> int:
        if not self.suspended.tids:
            raise FixError("game threads must be stopped before allocating hook memory")
        tid = self.suspended.tids[0]
        cave = self.suspended.remote_syscall(
            tid, SYS_MMAP,
            (0, 0x2000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        )
        return cave

    def protect_hook_cave_rx(self, cave: int) -> None:
        tid = self.suspended.tids[0]
        self.suspended.remote_syscall(tid, SYS_MPROTECT, (cave, 0x1000, PROT_READ | PROT_EXEC))

    def prepare_hook_cave_while_stopped(self) -> bool:
        if self.hook_prepared:
            return True
        try:
            cave = self.allocate_hook_cave()
            dynamic: list[HookSite] = []
            for call in self.hook_descs:
                if call.continuation_rva != call.rva + len(call.stock):
                    raise FixError(f"{call.kind} continuation mismatch")
                co = 13 if call.kind == "Outer" else 16
                if call.stock[co] != 0xE8:
                    raise FixError(f"{call.kind} original call opcode missing")
                rel = struct.unpack_from("<i", call.stock, co + 1)[0]
                decoded = call.rva + co + 5 + rel
                if decoded != call.target_rva:
                    raise FixError(f"{call.kind} target RVA mismatch")

                unit = cave + call.unit_offset
                if call.kind == "Outer":
                    wrapper = build_outer_unit(unit, self.base + call.target_rva, False)
                    expected_len = 474
                else:
                    wrapper = build_copy_unit(call, unit, self.base + call.target_rva, 4, 2)
                    expected_len = 311
                if len(wrapper) != expected_len or call.unit_offset + len(wrapper) > 0x1000:
                    raise FixError(f"{call.kind} wrapper shape changed unexpectedly")
                self.wb(unit, wrapper)
                fix = build_call_patch(call, cave)
                dynamic.append(HookSite(call.name, call.rva, call.stock, fix,
                                        call.kind, unit, wrapper))

            if len(dynamic) != 3:
                raise FixError("not every selected v1.4 wrapper was built")
            magic = b"HMFIX-V1.4-W"
            self.wb(cave + 0x1400, magic)
            self.protect_hook_cave_rx(cave)

            for s in dynamic:
                if self.rb(s.wrapper_address, len(s.wrapper)) != s.wrapper:
                    raise FixError("wrapper readback failed")
            if self.rb(cave + 0x1400, len(magic)) != magic:
                raise FixError("hook ownership marker readback failed")

            self.hook_cave = cave
            self.hook_sites = dynamic
            self.hook_prepared = True
            self.log(f"v1.4 refraction cave prepared at 0x{cave:X}; calls CopyA,CopyB,Outer")
            return True
        except Exception as exc:
            self.fatal = f"The v1.4 refraction hook could not be prepared safely: {exc}"
            return False

    def read_telemetry(self):
        if not self.hook_prepared:
            return None
        b = self.rb(self.hook_cave + 0x1000, 0xA0)
        q = lambda o: struct.unpack_from("<Q", b, o)[0]
        i = lambda o: struct.unpack_from("<I", b, o)[0]
        return dict(
            calls=q(0x00), changed=q(0x08), restored=q(0x10),
            bad_count=q(0x18), last_old=i(0x20), max_top=i(0x24),
            bad_state=q(0x28), active=q(0x30), owner_tid=q(0x38),
            owner_ctx=q(0x40), owner_acquired=q(0x48), owner_released=q(0x50),
            mesh_overrides=q(0x58), copy_a_calls=q(0x60), copy_a_changed=q(0x68),
            copy_a_restored=q(0x70), copy_a_active=q(0x78),
            copy_b_calls=q(0x80), copy_b_changed=q(0x88),
            copy_b_restored=q(0x90), copy_b_active=q(0x98),
        )

    def hook_state(self) -> tuple[bool, str, str]:
        if not self.hook_prepared:
            return False, "", "no copy path observed"
        try:
            t = self.read_telemetry()
            if t is None:
                return False, "hook telemetry unavailable", "no copy path observed"
            if t["bad_count"] or t["bad_state"] or t["max_top"] > 4:
                return False, "wrapper rejected an unexpected owner/count state", ""

            now = time.monotonic()
            stable_inactive = False
            if t["active"] == 0 and t["copy_a_active"] == 0 and t["copy_b_active"] == 0:
                t2 = self.read_telemetry()
                if t2 is not None:
                    stable_inactive = (
                        t2["active"] == 0
                        and t2["copy_a_active"] == 0
                        and t2["copy_b_active"] == 0
                        and t2["calls"] == t["calls"]
                        and t2["changed"] == t["changed"]
                        and t2["restored"] == t["restored"]
                        and t2["copy_a_calls"] == t["copy_a_calls"]
                        and t2["copy_a_changed"] == t["copy_a_changed"]
                        and t2["copy_a_restored"] == t["copy_a_restored"]
                        and t2["copy_b_calls"] == t["copy_b_calls"]
                        and t2["copy_b_changed"] == t["copy_b_changed"]
                        and t2["copy_b_restored"] == t["copy_b_restored"]
                        and t2["owner_tid"] == t["owner_tid"]
                        and t2["owner_ctx"] == t["owner_ctx"]
                    )

            if stable_inactive:
                if t["owner_tid"] != 0 or t["owner_ctx"] != 0:
                    return False, "transparent-pass owner marker stayed set", ""
                if t["owner_acquired"] != t["owner_released"]:
                    return False, "transparent-pass owner acquisition was not balanced", ""
                if t["changed"] != t["restored"]:
                    return False, "outer wrapper count change was not restored", ""
                if t["copy_a_changed"] != t["copy_a_restored"]:
                    return False, "CopyA count change was not restored", ""
                if t["copy_b_changed"] != t["copy_b_restored"]:
                    return False, "CopyB count change was not restored", ""

            for name, active_count, progress_value in (
                ("Outer", t["active"], t["calls"] + t["restored"]),
                ("CopyA", t["copy_a_active"], t["copy_a_calls"] + t["copy_a_restored"]),
                ("CopyB", t["copy_b_active"], t["copy_b_calls"] + t["copy_b_restored"]),
            ):
                if active_count == 0:
                    self.hook_progress.pop(name, None)
                    continue
                old = self.hook_progress.get(name)
                if old is None or old[0] != progress_value:
                    self.hook_progress[name] = (progress_value, now)
                elif now - old[1] >= 10.0:
                    return False, f"{name} wrapper stayed active without progress for ten seconds", ""

            if now - self.last_integrity_check >= 2.0:
                for site in self.sites:
                    if self.rb(self.base + site.rva, len(site.fix)) != site.fix:
                        return False, f"base fix changed at RVA 0x{site.rva:X}", ""
                for guard in self.guard_sites:
                    if self.rb(self.base + guard.rva, len(guard.stock)) != guard.stock:
                        return False, f"stock guard changed at RVA 0x{guard.rva:X}", ""
                for site in self.hook_sites:
                    if self.rb(self.base + site.rva, len(site.fix)) != site.fix:
                        return False, f"{site.kind} call block changed", ""
                    if self.rb(site.wrapper_address, len(site.wrapper)) != site.wrapper:
                        return False, f"{site.kind} wrapper changed", ""
                if self.rb(self.hook_cave + 0x1400, 12) != b"HMFIX-V1.4-W":
                    return False, "wrapper ownership marker changed", ""
                self.last_integrity_check = now

            copy_a = t["copy_a_changed"] > 0 and t["copy_a_restored"] > 0
            copy_b = t["copy_b_changed"] > 0 and t["copy_b_restored"] > 0
            coverage = "no copy path observed"
            if copy_a and copy_b:
                coverage = "CopyA + CopyB verified"
            elif copy_a:
                coverage = "CopyA verified; CopyB not observed"
            elif copy_b:
                coverage = "CopyB verified; CopyA not observed"

            # v1.6 readiness proves the outer refraction owner path. CopyA/B
            # remain optional coverage diagnostics rather than a green-state gate.
            ready = t["owner_acquired"] > 0

            if now - self.last_hook_log >= 5.0:
                self.log(
                    "pass telemetry: "
                    f"outer calls={t['calls']}, owner={t['owner_acquired']}/{t['owner_released']}, "
                    f"changed={t['changed']}/{t['restored']}, "
                    f"copyA={t['copy_a_calls']}/{t['copy_a_changed']}/{t['copy_a_restored']}, "
                    f"copyB={t['copy_b_calls']}/{t['copy_b_changed']}/{t['copy_b_restored']}, "
                    f"active={t['active']}/{t['copy_a_active']}/{t['copy_b_active']}; "
                    f"coverage: {coverage}"
                )
                self.last_hook_log = now
            return ready, "", coverage
        except Exception as exc:
            return False, str(exc), ""

    # ----- patch transaction ------------------------------------------------

    def apply_code(self) -> bool:
        for g in self.guard_sites:
            if self.rb(self.base + g.rva, len(g.stock)) != g.stock:
                self.fatal = f"Guarded renderer site '{g.name}' is not in its original state."
                return False

        all_fix = all(self.rb(self.base + s.rva, len(s.fix)) == s.fix for s in self.sites)
        all_stock = all(self.rb(self.base + s.rva, len(s.stock)) == s.stock for s in self.sites)
        if all_fix:
            self.fatal = "HITMAN was already patched before this tool attached."
            return False
        if not all_stock:
            self.fatal = "The game code is not in its original state."
            return False

        state = self.vr_start_state()
        if state < 0:
            self.fatal = "The pre-VR renderer state could not be proven safely."
            return False
        if state == 1:
            self.fatal = "VR was already running. Start this tool before HITMAN/VR."
            return False

        for h in self.hook_descs:
            if self.rb(self.base + h.rva, len(h.stock)) != h.stock:
                self.fatal = f"v1.4 refraction call '{h.name}' is not stock."
                return False

        try:
            self.suspended.suspend_all()
        except Exception as exc:
            self.fatal = f"The game could not be paused safely: {exc}"
            return False

        written: list[Site] = []
        hook_written: list[HookSite] = []
        try:
            if self.vr_start_state() != 0:
                raise FixError("renderer state changed before suspended patch transaction")

            if not self.prepare_hook_cave_while_stopped():
                raise FixError(self.fatal)

            ranges = []
            for s in self.sites + self.hook_sites:
                start = self.base + s.rva
                ranges.append((start, start + len(s.stock)))
            for s in self.hook_sites:
                ranges.append((s.wrapper_address, s.wrapper_address + len(s.wrapper)))
            if not self.suspended.rips_outside(ranges):
                self.suspended.resume_all()
                time.sleep(0.050)
                return False

            # Recheck all preconditions while stopped.
            if self.mode == "verified":
                stamp, text_rva, text = self.read_pe(self.exe_path)
                for rva, expected in VERIFIED_DIAGNOSTIC_CONTEXTS:
                    if self.rb(self.base + rva, len(expected)) != expected:
                        raise FixError(f"loaded verified context changed at RVA 0x{rva:X}")
            for g in self.guard_sites:
                if self.rb(self.base + g.rva, len(g.stock)) != g.stock:
                    raise FixError("guarded renderer site changed before patch")
            for s in self.sites:
                if self.rb(self.base + s.rva, len(s.stock)) != s.stock:
                    raise FixError("base site changed before patch")
            for s in self.hook_sites:
                if self.rb(self.base + s.rva, len(s.stock)) != s.stock:
                    raise FixError("hook call changed before patch")

            for s in self.sites:
                written.append(s)
                self.wb(self.base + s.rva, s.fix)
            for s in self.hook_sites:
                hook_written.append(s)
                self.wb(self.base + s.rva, s.fix)

            for s in self.sites:
                if self.rb(self.base + s.rva, len(s.fix)) != s.fix:
                    raise FixError("base patch verification failed")
            for s in self.hook_sites:
                if self.rb(self.base + s.rva, len(s.fix)) != s.fix:
                    raise FixError("hook patch verification failed")
            for g in self.guard_sites:
                if self.rb(self.base + g.rva, len(g.stock)) != g.stock:
                    raise FixError("guarded site changed during patch")

            self.written_sites = written
            self.patched = True
            self.log(f"v1.6 code patched, base sites {len(written)}, refraction calls {len(hook_written)}")
            return True

        except Exception as exc:
            rollback_ok = True
            for s in reversed(hook_written):
                try:
                    self.wb(self.base + s.rva, s.stock)
                    rollback_ok &= self.rb(self.base + s.rva, len(s.stock)) == s.stock
                except Exception:
                    rollback_ok = False
            for s in written:
                try:
                    self.wb(self.base + s.rva, s.stock)
                    rollback_ok &= self.rb(self.base + s.rva, len(s.stock)) == s.stock
                except Exception:
                    rollback_ok = False
            if not rollback_ok:
                self.unsafe_code_state = True
                self.fatal = f"Patch failed ({exc}) and rollback could not be verified. HITMAN remains suspended; terminate it."
                return False
            self.fatal = f"Patch failed ({exc}) and was rolled back. Restart HITMAN before retrying."
            return False
        finally:
            if not self.unsafe_code_state:
                if not self.suspended.resume_all():
                    self.fatal = "One or more HITMAN threads could not be resumed."
                    self.unsafe_code_state = True

    # ----- lifecycle --------------------------------------------------------

    @staticmethod
    def advance_lifecycle(last: int, trans: int) -> LifecycleResult:
        changed = last != trans
        return LifecycleResult(trans, changed, changed)

    # ----- restore ----------------------------------------------------------

    def restore(self) -> bool:
        if self.mem_fd is None or not self.alive():
            return True
        if self.unsafe_code_state:
            return False

        safe = False
        for _ in range(20):
            self.suspended.suspend_all()
            try:
                ranges = []
                for site in self.written_sites + self.hook_sites:
                    start = self.base + site.rva
                    ranges.append((start, start + len(site.stock)))
                for site in self.hook_sites:
                    ranges.append((site.wrapper_address, site.wrapper_address + len(site.wrapper)))
                t = self.read_telemetry()
                inactive = (t is None or (
                    t["active"] == 0 and t["copy_a_active"] == 0 and t["copy_b_active"] == 0
                    and t["owner_tid"] == 0 and t["owner_ctx"] == 0
                ))
                safe = inactive and self.suspended.rips_outside(ranges)
            except Exception:
                self.suspended.resume_all()
                return False
            if safe:
                break
            self.suspended.resume_all()
            time.sleep(0.050)

        if not safe:
            self.fatal = "The refraction pass stayed busy. Close HITMAN or retry."
            return False

        restore_order = list(reversed(self.hook_sites)) + list(self.written_sites)
        restored: list[Site] = []
        try:
            for site in restore_order:
                cur = self.rb(self.base + site.rva, len(site.fix))
                if cur == site.stock:
                    continue
                if cur != site.fix:
                    raise FixError(f"foreign bytes at RVA 0x{site.rva:X}")
                restored.append(site)
                self.wb(self.base + site.rva, site.stock)
                if self.rb(self.base + site.rva, len(site.stock)) != site.stock:
                    raise FixError("restore verification failed")
        except Exception as exc:
            rollback_ok = True
            for site in reversed(restored):
                try:
                    self.wb(self.base + site.rva, site.fix)
                    rollback_ok &= self.rb(self.base + site.rva, len(site.fix)) == site.fix
                except Exception:
                    rollback_ok = False
            if not rollback_ok:
                self.unsafe_code_state = True
                self.fatal = f"Restore failed ({exc}); rollback not verifiable. HITMAN remains suspended."
                return False
            self.suspended.resume_all()
            self.fatal = f"Restore failed ({exc}) and was rolled back safely."
            return False

        if not self.suspended.resume_all():
            self.fatal = "Fix restored, but one or more HITMAN threads could not be resumed."
            return False
        self.patched = False
        self.written_sites = []
        self.log("restored")
        return True

    # ----- detach/reset -----------------------------------------------------

    def reset_device(self) -> None:
        self.dev = 0
        self.last_trans = -1
        self.stable_ready = 0
        self.stable_since = 0.0
        self.runtime_loaded = False
        self.last_runtime_check = 0.0

    def detach(self) -> None:
        if self.suspended.tids and not self.unsafe_code_state:
            self.suspended.resume_all()
        if self.mem_fd is not None:
            try:
                os.close(self.mem_fd)
            except OSError:
                pass
        self.mem_fd = None
        self.pid = 0
        self.base = 0
        self.exe_path = None
        self.mode = ""
        self.sites = []
        self.guard_sites = []
        self.written_sites = []
        self.hook_descs = []
        self.hook_sites = []
        self.hook_cave = 0
        self.hook_prepared = False
        self.hook_progress = {}
        self.patched = False
        self.dev = 0
        self.last_trans = -1
        self.stable_ready = 0
        self.stable_since = 0.0
        self.runtime_loaded = False
        self.last_runtime_check = 0.0
        self.last_status = ""

    # ----- tick -------------------------------------------------------------

    def tick(self) -> None:
        if self.stopped:
            return
        if self.mem_fd is not None and not self.alive():
            self.log("game closed")
            self.detach()
            self.fatal = ""
            self.status("Waiting for HITMAN", "Game closed. Start it again and v1.6.0 will apply automatically.")
            return

        if self.unsafe_code_state:
            self.status("END HITMAN", "An unverified rollback state is deliberately suspended. Terminate HITMAN; do not resume it.")
            return
        if self.fatal:
            self.status("Not active", self.fatal)
            return
        if self.mem_fd is None:
            now = time.monotonic()
            if self.last_attach_scan and now - self.last_attach_scan < 0.5:
                return
            self.last_attach_scan = now
            if not self.attach():
                if self.fatal:
                    self.status("Not active", self.fatal)
                return

        if not self.patched:
            if not self.apply_code():
                return
            self.status("Ready - start VR", "v1.6.0 is patched. Start VR and load a mission.")
            return

        hook_ready, hook_error, hook_coverage = self.hook_state()
        if hook_error:
            self.fatal = f"Pass-local safety monitor detected an unexpected state: {hook_error}"
            return

        d = self.get_dev()
        if d == -1:
            if self.dev:
                self.reset_device()
            self.status("Unsupported backend", "Active VR device is neither supported Oculus nor OpenVR.")
            return
        if d == 0:
            if self.dev:
                self.log("VR device became unavailable")
                self.reset_device()
            self.status("Ready - start VR", "v1.6.0 is patched; waiting for VR.")
            return
        if d != self.dev:
            self.reset_device()
            self.dev = d
            backend = "unknown"
            try:
                vt = self.i64(d)
                if vt == self.base + OCULUS_VTABLE_RVA:
                    backend = "Oculus"
                elif vt == self.base + OPENVR_VTABLE_RVA:
                    backend = "SteamVR/OpenVR"
            except Exception:
                pass
            self.log(f"VR device found at 0x{d:X}, backend {backend}")

        active = self.u8(d + OFF_ACTIVE)
        wno = self.u8(d + self.wno_off)
        trans = self.u32(d + OFF_TRANS)
        layers = self.u16(d + OFF_LAYERS)
        tex = self.i64(d + OFF_TEX)
        width = self.u32(d + OFF_W)
        height = self.u32(d + OFF_H)

        if self.mode == "scanned" and not self.runtime_loaded:
            now = time.monotonic()
            if now - self.last_runtime_check >= 0.5:
                self.runtime_loaded = self.runtime_loaded_now()
                self.last_runtime_check = now
            if not self.runtime_loaded:
                self.stable_ready = 0
                self.stable_since = 0
                self.last_trans = -1
                self.status("Ready - start VR", "Waiting for Oculus/OpenVR runtime.")
                return

        if active == 1 and wno != 0:
            self.status("Not active", "VR started before the patch took effect. Restart HITMAN with the tool running first.")
            return

        initialized, mask_fixed = self.check_render_values(d)

        life = self.advance_lifecycle(self.last_trans, trans)
        if life.transition_changed:
            self.log(f"transition {self.last_trans} -> {trans}")
        self.last_trans = life.last_transition
        if life.reset_stable:
            self.stable_ready = 0
            self.stable_since = 0

        if active != 1:
            self.status("Ready - start VR", "v1.6.0 is patched; waiting for VR.")
            return
        if not initialized:
            self.status("Waiting for renderer", "VR device is still initialising.")
            return
        if not mask_fixed:
            self.status(
                "Mask patch did not take",
                "HITMAN is still computing a non-zero foveation mask. "
                "The patched instruction is not the one this build uses. Close HITMAN and report this."
            )
            return
        if trans != 3 or layers != 2 or tex == 0:
            self.status("Waiting for mission", "VR is running in two-layer mode. Load a mission.")
            return
        if not hook_ready:
            self.status("Waiting for scene renderer", "The refraction wrapper is installed but the transparent pass has not run yet. Load a mission.")
            return

        now = time.monotonic()
        if not self.stable_since:
            self.stable_since = now
        if self.stable_ready < 3:
            self.stable_ready += 1
        if self.stable_ready < 3 or now - self.stable_since < 0.250:
            self.status("Finishing mission load", "Render values are correct; confirming they remain stable.")
        else:
            self.status(
                "Active",
                f"Sharp edge-to-edge at {width} x {height} per eye. "
                f"Glass/water refraction uses the corrected two-eye copy path; {hook_coverage}. "
                "No continuous renderer-value writes."
            )

    def run(self) -> int:
        self.status("Waiting for HITMAN", "Start HITMAN after this tool. It will apply the fix before VR starts.")
        next_tick = time.monotonic()
        while not self.stopped:
            try:
                self.tick()
            except Exception as exc:
                if self.alive():
                    self.status("Something went wrong", f"{exc}. Close HITMAN and try again.")
            next_tick += 0.015
            delay = next_tick - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_tick = time.monotonic()
        return 0

    def stop(self, *_):
        self.stopped = True


def ensure_root() -> None:
    """Re-exec this script through sudo when launched as a normal user."""
    if os.geteuid() == 0:
        return
    script = str(Path(__file__).resolve())
    try:
        os.execvp("sudo", ["sudo", sys.executable, "-I", script, *sys.argv[1:]])
    except OSError as exc:
        raise SystemExit(f"Could not elevate through sudo: {exc}") from exc


def main() -> int:
    ensure_root()

    parser = argparse.ArgumentParser(
        description=f"HitmanVRFoveationFix Linux v{FIX_VERSION}, based on Windows/PowerShell v{UPSTREAM_VERSION}"
    )
    parser.add_argument("--process-name", default="HITMAN3")
    args = parser.parse_args()

    lock_path = "/run/HitmanVRFoveationFix.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    lock_file = os.fdopen(fd, "r+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("HitmanVRFoveationFix is already running.", file=sys.stderr)
        return 0

    fix = HitmanFix(args.process_name, Path(__file__).resolve().parent / "foveationfix.log")
    cleaned = False

    def cleanup():
        nonlocal cleaned
        if cleaned:
            return
        cleaned = True
        try:
            if fix.alive() and fix.patched:
                if not fix.restore():
                    print("[Close HITMAN] Live restoration was incomplete.", file=sys.stderr)
        finally:
            if not fix.unsafe_code_state:
                fix.detach()

    atexit.register(cleanup)
    signal.signal(signal.SIGINT, fix.stop)
    signal.signal(signal.SIGTERM, fix.stop)

    print(f"HitmanVRFoveationFix v{FIX_VERSION} - Linux/Proton")
    print(f"Based on Windows/PowerShell v{UPSTREAM_VERSION}. Leave this terminal open while you play.")
    print("Press Ctrl+C to turn off and restore.")
    rc = fix.run()
    cleanup()
    fix.log("closed")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
