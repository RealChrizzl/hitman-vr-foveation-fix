<#
    HitmanVRFoveationFix v1.6.1

    v1.6.1 is v1.6 with one thing fixed: on a build that is not the verified one,
    the signature scan was measured at about twelve seconds. That is long enough
    to reach the VR prompt first, and the tool then correctly refused to patch a
    session where VR was already running (issue #15). The search now runs in
    compiled code instead of interpreted PowerShell, and the scanned path no
    longer hashes the executable it does not need. Nothing about what it matches,
    or refuses to match, changed. The new duration is logged rather than claimed.

    v1.6 removes the race instead of defending against it.

    Every version up to 1.5 wrote three values into the VR device and then had to
    stop HITMAN from writing them back - first with a 15 ms loop, then with a
    1 ms guard on its own thread. That is a race, and it can be lost: scheduler
    stalls of 78, 125 and 218 ms were all measured on real machines.

    The two mask values are now zeroed inside HITMAN's own calculation:

      0x11CDAC1  mulss xmm0,xmm0  ->  xorps xmm0,xmm0 ; nop     mask b = 0
      0x11CDAC9  mulss xmm2,xmm2  ->  xorps xmm2,xmm2 ; nop     mask a = 0

    HITMAN then stores zero itself, every time it recalculates - including during
    every save load and every renderer rebuild. There is no value of ours for
    anything to overwrite.

    The four scale values are no longer touched at all. Two test sessions with
    them left at HITMAN's own numbers showed no visible difference, in bright and
    dark scenes, with glass and water. They had been written since 1.0 because
    they were part of the original find, never because anyone had checked what
    they did on their own.

    WHAT THAT REMOVES
      - all device memory writes
      - the 1 ms renderer guard, its thread, its timer and its lock
      - the ownership, rollback and restore machinery for those values
      - the "reload this mission once" state, which existed only because a value
        could be written too late
      - the idle CPU load, now that the process scan is not run 67 times a second

    WHAT IS LEFT
      Eight base code patches plus the v1.4 refraction hook, applied once and
      verified before and after. Plus one check in the normal loop: are the two
      mask fields actually zero. If HITMAN ever computes something else there,
      the tool says so instead of looking fine.

    WHAT IT DOES
      HITMAN renders VR with foveation: four layers per frame, two wide ones at
      half resolution covering the whole field of view, and two narrow ones at
      full resolution covering only a small circle in the centre. Everything
      outside that circle is upscaled from the half-resolution layer, which is
      why it looks like mush on a high resolution headset.

      This tool switches the game to two layers at full resolution instead. That
      is twice the pixel work, but the density is what matters: 936 px across the
      old ~49 degree circle is 19.1 px per degree, 1872 px across the full 99
      degrees is 18.9. About a percent apart.

    HOW TO USE IT
      1. Start this tool
      2. Start HITMAN - however you like, including straight into VR
      3. Play

    Build 3.270.1 uses exact verified addresses. Other builds keep the
    fail-closed pattern path. Nothing is written to disk, ever.

    MIT licensed. Made by RealChrizzl.
#>

[CmdletBinding()]
param([string]$ProcessName = "HITMAN3",
      # Started together with the game (scheduled task / Steam launch option):
      # start minimized, stay silent if already running, close with HITMAN.
      [switch]$ExitWithGame)

$ErrorActionPreference = "Stop"

$FIX_VERSION = "1.6.1"
$MODE_INFO = [pscustomobject]@{
    Short="v1.6.1"
    Title="HitmanVRFoveationFix v1.6.1"
    Warning=""
    UsesHook=$true
    HookKinds=@("Outer","CopyA","CopyB")
    OuterChangesCount=$false
    CopyFrom=4
    CopyTo=2
    UsesMesh4=$false
}

# Reading another process's memory needs administrator rights. If we do not
# have them, ask Windows for them once and restart ourselves.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
    $launchArguments=@("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden",
                "-File","`"$self`"","-ProcessName","`"$ProcessName`"")
    if ($ExitWithGame) { $launchArguments += "-ExitWithGame" }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $launchArguments
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            "This tool needs administrator rights to read the game's memory.`n`nPlease allow the prompt, or right-click the file and choose 'Run as administrator'.",
            "HitmanVRFoveationFix","OK","Warning") | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not [Environment]::Is64BitProcess) {
    [Windows.Forms.MessageBox]::Show(
        "HitmanVRFoveationFix v1.6.1 requires 64-bit Windows PowerShell so live code changes can be verified safely.",
        "HitmanVRFoveationFix","OK","Warning") | Out-Null
    exit
}

# Two instances can both observe stock code before either writes it, then each
# believe it owns the patch. A named mutex closes that race before any game
# handle is opened.
$script:instanceMutex=New-Object Threading.Mutex($false,"Local\HitmanVRFoveationFix")
$script:mutexOwned=$false
try { $script:mutexOwned=$script:instanceMutex.WaitOne(0,$false) }
catch [Threading.AbandonedMutexException] { $script:mutexOwned=$true }
if (-not $script:mutexOwned) {
    # Auto-start on every game launch must not nag when the tool is already open.
    if ($ExitWithGame) { $script:instanceMutex.Dispose(); exit }
    [Windows.Forms.MessageBox]::Show(
        "HitmanVRFoveationFix is already running in this Windows session.",
        "HitmanVRFoveationFix","OK","Information") | Out-Null
    $script:instanceMutex.Dispose()
    exit
}

if (-not ("HmFix" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HmFix {
    // A byte-for-byte transcription of the PowerShell Find-Sig loop, moved here
    // because PowerShell walks 28 MB of .text twelve times - eight base patterns,
    // three refraction patterns and the device pattern. On an unknown build that
    // was measured at about twelve seconds, which is long enough to reach the VR
    // prompt first; the tool then correctly refused to patch a live VR session
    // (issue #15).
    //
    // Deliberately NOT a cleverer algorithm. Same anchor (the first non-wildcard
    // byte), same first-byte prefilter, same full comparison including wildcards,
    // same early exit once more than maxHits matches are found. Only the language
    // changed, so the matching semantics cannot have.
    public static int[] FindPattern(byte[] hay, int[] pat, int maxHits) {
        int n = pat.Length;
        if (hay == null || n == 0 || hay.Length < n) return new int[0];
        int anchor = 0;
        while (anchor < n && pat[anchor] < 0) anchor++;
        // An all-wildcard pattern would have thrown in PowerShell. Here it simply
        // matches nothing, which the caller turns into a fail-closed refusal.
        if (anchor >= n) return new int[0];
        byte first = (byte)pat[anchor];
        int limit = hay.Length - n;
        List<int> hits = new List<int>();
        for (int p = 0; p <= limit; p++) {
            if (hay[p + anchor] != first) continue;
            bool ok = true;
            for (int i = 0; i < n; i++) {
                int v = pat[i];
                if (v >= 0 && hay[p + i] != v) { ok = false; break; }
            }
            if (ok) {
                hits.Add(p);
                if (hits.Count > maxHits) break;
            }
        }
        return hits.ToArray();
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint allocationType, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, UIntPtr size, uint newProtect, out uint oldProtect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenThread(uint access, bool inheritHandle, uint threadId);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", EntryPoint="GetThreadContext", SetLastError=true)]
    private static extern bool GetThreadContextNative(IntPtr thread, IntPtr context);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetProcessMitigationPolicy(IntPtr process, uint policy, out uint buffer, UIntPtr length);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);

    // AMD64 CONTEXT is 16-byte aligned. ContextFlags is at +48 and RIP at
    // +248. CONTEXT_CONTROL is sufficient and keeps this helper independent
    // of the large floating-point/vector tail of the structure.
    public static bool TryGetThreadRip(IntPtr thread, out ulong rip, out int error) {
        const int SIZE = 0x4D0;
        rip = 0; error = 0;
        if (!Environment.Is64BitProcess) { error = 193; return false; }
        IntPtr raw = Marshal.AllocHGlobal(SIZE + 15);
        try {
            long alignedValue = (raw.ToInt64() + 15L) & ~15L;
            IntPtr aligned = new IntPtr(alignedValue);
            for (int i = 0; i < SIZE; i += 8) Marshal.WriteInt64(aligned, i, 0L);
            Marshal.WriteInt32(aligned, 0x30, unchecked((int)0x00100001u));
            if (!GetThreadContextNative(thread, aligned)) {
                error = Marshal.GetLastWin32Error(); return false;
            }
            rip = unchecked((ulong)Marshal.ReadInt64(aligned, 0xF8));
            return true;
        } finally { Marshal.FreeHGlobal(raw); }
    }
}

// v1.6 has no renderer guard. The mask is zeroed inside HITMAN's own
// calculation, so there is no value of ours that anything could overwrite and
// nothing to defend on a background thread. What used to be a 1 ms writer is now
// a plain check in the normal 15 ms loop: are the two mask fields actually zero.
'@
}

# ===========================================================================
#  VERIFIED PATH - build 3.270.1; v1.3 base plus the confirmed v1.4 W fix
# ===========================================================================
$VERIFIED_TIMESTAMP    = 1781013974
$VERIFIED_SHA256       = "B4FB04F460FD67E67F21264D7AD0D64BC081FBA62EC71E36B898D04DB9E8620D"
$MANAGER_RVA           = 0x03225D20L
$MANAGER_VTABLE_RVA    = 0x01EF5398L
$MANAGER_DEVICE_OFFSET = 0x141A0L
$OCULUS_VTABLE_RVA     = 0x01F016C0L    # ZRenderVRDeviceOculus
$OPENVR_VTABLE_RVA     = 0x01EFE020L    # ZRenderVRDeviceOpenVR - same layout, verified by probe
$VERIFIED_WNO_OFF      = 0x31BL

$VERIFIED_WNO_WRITERS = @(
  [pscustomobject]@{ Name="v1.3 WNO writer A"
                     RVA=0x011D8B9EL
                     Stock=[byte[]](0x0F,0x94,0xC1)
                     Fix  =[byte[]](0xB1,0x00,0x90) }
  [pscustomobject]@{ Name="v1.3 WNO writer B"
                     RVA=0x011D8BC1L
                     Stock=[byte[]](0x0F,0x94,0xC0)
                     Fix  =[byte[]](0xB0,0x00,0x90) }
)

$VERIFIED_PRIMARY_DEPTH_CB = @(
  [pscustomobject]@{ Name="v1.3 depth flag Oculus"
                     RVA=0x012C1EACL          # primary depth/tile CB flag, Oculus
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  [pscustomobject]@{ Name="v1.3 depth flag OpenVR"
                     RVA=0x012499CCL          # primary depth/tile CB flag, OpenVR
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
)

$VERIFIED_VIEW_COUNT =
  [pscustomobject]@{ Name="v1.3 view count"
                     RVA=0x01161FE9L
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

# The same 1/2/4 view count is set up in a SECOND place. v1.3 patched one of
# them; the other kept pushing 2 and produced the oval mask on one eye. Same
# instruction shape, same reasoning, same fix - see HOW-IT-WORKS.md section 3.
$VERIFIED_VIEW_COUNT_2 =
  [pscustomobject]@{ Name="v1.5 view count 2"
                     RVA=0x01162E3CL
                     Stock=[byte[]](0x80,0xB9,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

# Most experimental sites below take one locally WNO-dependent producer or
# consumer down the stock WNO=1 path while the device itself remains in v1.3's
# two-slice state. `test rsp,rsp` plus NOPs makes ZF=0 without changing control
# flow or using new executable memory. CopyRefractionDepth is the one exception:
# its three-byte load is replaced with a same-size base-slice-zero assignment.
$REFRACTION_DEPTH_ZERO =
  [pscustomobject]@{ Name="CopyRefractionDepth base slice zero"
                     RVA=0x0128FF20L
                     Stock=[byte[]](0x8B,0x6E,0x20)
                     Fix  =[byte[]](0x31,0xED,0x90) }

$CAMERA_STATE_4 =
  [pscustomobject]@{ Name="extended camera state"
                     RVA=0x011B4625L
                     Stock=[byte[]](0x44,0x38,0xB9,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$ASSAO_DEPTH_4 =
  [pscustomobject]@{ Name="four-view ASSAO depth preparation"
                     RVA=0x012886DAL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$CAMERA_RECORDS_4 =
  [pscustomobject]@{ Name="four-view camera records"
                     RVA=0x0129297EL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$OCCLUDER_STATE_4 = @(
  [pscustomobject]@{ Name="occluder matrix preprocess"
                     RVA=0x01298B1DL
                     Stock=[byte[]](0x44,0x38,0xA8,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
  [pscustomobject]@{ Name="occluder matrix restore"
                     RVA=0x0129987CL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
)

$SSR_FRUSTA_4 =
  [pscustomobject]@{ Name="four-view SSR frusta"
                     RVA=0x0129DE92L
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }

$CORE_DRAW_GATES_4 = @(
  [pscustomobject]@{ Name="core DrawGate A"
                     RVA=0x01296BEFL
                     Stock=[byte[]](0x40,0x38,0xB0,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
  [pscustomobject]@{ Name="core DrawGate B"
                     RVA=0x0129706CL
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
)

# With the global render-context count left at two, this changes only the
# instance-multiplier constant consumed by CullScatter's visibility shader.
# CullScatter's other two tests distinguish one view from more than one, so
# their behaviour is identical for the two-view and four-view profiles.
$CULL_SCATTER_4 =
  [pscustomobject]@{ Name="CullScatter instance multiplier four"
                     RVA=0x0127AABBL
                     Stock=[byte[]](0x41,0x8B,0x46,0x14,0x41,0x8B,0x0C,0x86)
                     Fix  =[byte[]](0xB9,0x04,0x00,0x00,0x00,0x90,0x90,0x90) }

# v1.4 redirects only exact instruction blocks. Every replacement uses a
# normal indirect CALL followed by an inline jump over its 64-bit pointer. The
# private wrapper returns normally, so Windows shadow-stack/CET CALL/RET symmetry
# is retained. No replacement consumes another engine context-stack slot.
$TRANSPARENT_PASS_CALL =
  [pscustomobject]@{ Name="DrawRefractiveAndTransparent camera call"
                     Kind="Outer"
                     RVA=0x011B892AL
                     TargetRVA=0x01290220L
                     ContinuationRVA=0x011B893CL
                     UnitOffset=0x000L
                     Stock=[byte[]](0x48,0x8B,0x8C,0x24,0xC0,0x00,0x00,0x00,0x48,0x89,0x44,0x24,0x20,0xE8,0xE4,0x78,0x0D,0x00) }

$COPY_DEPTH_CALL_A =
  [pscustomobject]@{ Name="CopyRefractionDepth call A"
                     Kind="CopyA"
                     RVA=0x01290BA2L
                     TargetRVA=0x0128FE20L
                     ContinuationRVA=0x01290BB7L
                     UnitOffset=0x400L
                     CounterOffset=0x60L
                     Stock=[byte[]](0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x69,0xF2,0xFF,0xFF) }

$COPY_DEPTH_CALL_B =
  [pscustomobject]@{ Name="CopyRefractionDepth call B"
                     Kind="CopyB"
                     RVA=0x01291386L
                     TargetRVA=0x0128FE20L
                     ContinuationRVA=0x0129139BL
                     UnitOffset=0x600L
                     CounterOffset=0x80L
                     Stock=[byte[]](0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x85,0xEA,0xFF,0xFF) }

$MESH_COUNT_HOOK =
  [pscustomobject]@{ Name="transparent indexed-mesh instance multiplier"
                     Kind="Mesh"
                     RVA=0x0121C91AL
                     ContinuationRVA=0x0121C92BL
                     UnitOffset=0x200L
                     Stock=[byte[]](0x8B,0x41,0x14,0x41,0x8B,0xE9,0x45,0x8B,0xF0,0x8B,0xF2,0x48,0x8B,0xD9,0x8B,0x3C,0x81) }

# The old water wrapper and the unrelated particle-lighting multiplier are
# stock-only guards. Test S already proved that the water wrapper adds nothing;
# reverse engineering proved the sprite multiplier runs before this pass.
$WATER_PASS_CALL =
  [pscustomobject]@{ Name="DrawWaterRefractive camera call"
                     Kind="WaterGuard"
                     RVA=0x011B83CAL
                     TargetRVA=0x0127E260L
                     ContinuationRVA=0x011B83E1L
                     Stock=[byte[]](0x48,0x8D,0x84,0x24,0xE0,0x01,0x00,0x00,0x48,0x89,0x5C,0x24,0x28,0x48,0x89,0x44,0x24,0x20,0xE8,0x7F,0x5E,0x0C,0x00) }
$SPRITE_COUNT_GUARD =
  [pscustomobject]@{ Name="unrelated particle-lighting instance multiplier"
                     Kind="SpriteGuard"
                     RVA=0x012EB2B4L
                     Stock=[byte[]](0x48,0x8B,0xCB,0x44,0x8D,0x42,0x14,0x0F,0xB7,0x74,0xC7,0x32,0x8B,0x43,0x14,0x0F,0xAF,0x34,0x83) }

# Publish all inner blocks first and the outer camera entry last. Reverse
# rollback therefore removes the entry gate first even on a partial failure.
$ALL_HOOK_SITES=@($COPY_DEPTH_CALL_A,$COPY_DEPTH_CALL_B,$MESH_COUNT_HOOK,$TRANSPARENT_PASS_CALL)

# Exact on-disk instruction contexts for every profile-sensitive site. Each
# sequence is unique in build 3.270.1.
$VERIFIED_DIAGNOSTIC_CONTEXTS = @(
  [pscustomobject]@{ RVA=0x012499A0L
                     Bytes=[byte[]](0x50,0x09,0x00,0x00,0x45,0x33,0xC0,0x4C,0x8B,0x8E,0xC8,0x7A,0x00,0x00,0x48,0x8B,0xD3,0x48,0x89,0x6C,0x24,0x28,0x48,0x89,0x6C,0x24,0x20,0x48,0x8B,0x01,0xFF,0x50,0x28,0x48,0x8B,0xCB,0xE8,0x57,0x66,0xFD,0xFF,0xFF,0x4B,0x14,0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00) }
  [pscustomobject]@{ RVA=0x012C1E80L
                     Bytes=[byte[]](0xC0,0x08,0x00,0x00,0x45,0x33,0xC0,0x4C,0x8B,0x8E,0xC8,0x7A,0x00,0x00,0x48,0x8B,0xD3,0x48,0x89,0x6C,0x24,0x28,0x48,0x89,0x6C,0x24,0x20,0x48,0x8B,0x01,0xFF,0x50,0x28,0x48,0x8B,0xCB,0xE8,0x77,0xE1,0xF5,0xFF,0xFF,0x4B,0x14,0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01296BEAL
                     Bytes=[byte[]](0xB9,0x03,0x00,0x00,0x00,0x40,0x38,0xB0,0x1B,0x03,0x00,0x00,0x41,0x0F,0x44,0xCF,0x44,0x3B,0xC9,0x0F,0x83) }
  [pscustomobject]@{ RVA=0x01297067L
                     Bytes=[byte[]](0xB9,0x03,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x41,0x0F,0x44,0xC9,0x3B,0xF1,0x0F,0x83) }
  [pscustomobject]@{ RVA=0x0128FF16L
                     Bytes=[byte[]](0x48,0x8B,0xB0,0xE0,0x00,0x00,0x00,0x8B,0x47,0x14,0x8B,0x6E,0x20,0x44,0x8B,0xFD,0x8D,0x4D,0xFF,0x03,0x4E,0x24,0x83,0x3C,0x87,0x01,0x44,0x0F,0x46,0xF9,0x48,0x85,0xDB) }
  [pscustomobject]@{ RVA=0x011B4619L
                     Bytes=[byte[]](0x48,0x8B,0x0D,0xA0,0x58,0x08,0x02,0x8B,0xD6,0x48,0x8B,0x01,0x44,0x38,0xB9,0x1B,0x03,0x00,0x00,0x0F,0x84,0x6C,0x01,0x00,0x00,0xFF,0x90,0x30,0x01,0x00,0x00,0x0F,0x10,0x40,0x40) }
  [pscustomobject]@{ RVA=0x01292963L
                     Bytes=[byte[]](0xBB,0x04,0x00,0x00,0x00,0x48,0x8B,0x05,0x51,0x75,0xFA,0x01,0x0F,0x28,0x3D,0xEA,0x19,0x9B,0x00,0xB9,0x02,0x00,0x00,0x00,0x0F,0x28,0xEE,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x29,0xB5,0xE0,0x07,0x00,0x00,0x0F,0x10,0x96,0x90,0x02,0x00,0x00,0x0F,0x44,0xD9,0x89,0x9D,0xA0,0x0B,0x00,0x00,0x0F,0x29,0x95,0xF0,0x07) }
  [pscustomobject]@{ RVA=0x012886DAL
                     Bytes=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x84,0x32,0x03,0x00,0x00,0xF3,0x44,0x0F,0x10,0x05,0xF8,0x49,0x32,0x03) }
  [pscustomobject]@{ RVA=0x01298B11L
                     Bytes=[byte[]](0x48,0x8B,0x05,0xA8,0x13,0xFA,0x01,0xB9,0x03,0x00,0x00,0x00,0x44,0x38,0xA8,0x1B,0x03,0x00,0x00,0x0F,0x44,0xCF,0x44,0x3B,0xC1,0x73,0x79,0x41,0x8D,0x50,0x01,0x41,0x8B,0xC0,0x8B) }
  [pscustomobject]@{ RVA=0x01299870L
                     Bytes=[byte[]](0x48,0x8B,0x05,0x49,0x06,0xFA,0x01,0xB9,0x03,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x0F,0x44,0xCB,0x44,0x3B,0xE9,0x73,0x4D,0x41,0x8D,0x55,0x01,0x41,0x8B,0xCD,0x48) }
  [pscustomobject]@{ RVA=0x0129DE80L
                     Bytes=[byte[]](0x48,0x8B,0x05,0x39,0xC0,0xF9,0x01,0xB9,0x02,0x00,0x00,0x00,0x41,0xBE,0x04,0x00,0x00,0x00,0x80,0xB8,0x1B,0x03,0x00,0x00,0x00,0x44,0x0F,0x44,0xF1,0x44,0x0F,0x28,0x25,0x6B,0xC7,0xCB,0x00) }
  [pscustomobject]@{ RVA=0x0127AAABL
                     Bytes=[byte[]](0x74,0x0E,0xF3,0x0F,0x10,0x84,0x24,0x28,0x01,0x00,0x00,0xF3,0x0F,0x11,0x04,0x38,0x41,0x8B,0x46,0x14,0x41,0x8B,0x0C,0x86,0x8B,0x82,0x60,0x61,0x00,0x00,0x89,0x8C,0x24,0x28,0x01,0x00,0x00,0x49,0x3B,0xC0,0x74,0x0E,0xF3,0x0F,0x10,0x84,0x24,0x28) }
  [pscustomobject]@{ RVA=0x0121C90AL
                     Bytes=[byte[]](0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41,0x56,0x48,0x83,0xEC,0x30,0x8B,0x41,0x14,0x41,0x8B,0xE9,0x45,0x8B,0xF0,0x8B,0xF2,0x48,0x8B,0xD9,0x8B,0x3C,0x81,0xE8,0x80,0x64,0x00,0x00,0x48,0x8B,0x8B,0xF8,0x16,0x00,0x00,0xE8,0x24,0x40,0xFC,0xFF,0x48,0x8B,0x8B,0x00,0x17,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01290220L
                     Bytes=[byte[]](0x4C,0x89,0x4C,0x24,0x20,0x48,0x89,0x4C,0x24,0x08,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x81,0xEC,0xB0,0x01,0x00,0x00) }
  [pscustomobject]@{ RVA=0x01291BC2L
                     Bytes=[byte[]](0x0F,0x28,0xBD,0x30,0x01,0x00,0x00,0x44,0x0F,0x28,0x85,0x20,0x01,0x00,0x00,0x44,0x0F,0x28,0x8D,0x10,0x01,0x00,0x00,0x48,0x8D,0xA5,0x50,0x01,0x00,0x00,0x41,0x5F,0x41,0x5E,0x41,0x5C,0x5F,0x5E,0x5B,0x5D,0xC3) }
  [pscustomobject]@{ RVA=0x0127E260L
                     Bytes=[byte[]](0x4C,0x89,0x4C,0x24,0x20,0x4C,0x89,0x44,0x24,0x18,0x41,0x55,0x41,0x57) }
  [pscustomobject]@{ RVA=0x0127FA73L
                     Bytes=[byte[]](0x48,0x81,0xC4,0x78,0x02,0x00,0x00,0x41,0x5F,0x41,0x5D,0xC3) }
  [pscustomobject]@{ RVA=0x011B892AL
                     Bytes=[byte[]](0x48,0x8B,0x8C,0x24,0xC0,0x00,0x00,0x00,0x48,0x89,0x44,0x24,0x20,0xE8,0xE4,0x78,0x0D,0x00,0x48,0x8D,0x8C,0x24,0x60,0x02,0x00,0x00) }
  [pscustomobject]@{ RVA=0x011B83CAL
                     Bytes=[byte[]](0x48,0x8D,0x84,0x24,0xE0,0x01,0x00,0x00,0x48,0x89,0x5C,0x24,0x28,0x48,0x89,0x44,0x24,0x20,0xE8,0x7F,0x5E,0x0C,0x00,0x48,0x85,0xDB,0x74,0x45) }
  [pscustomobject]@{ RVA=0x01290B90L
                     Bytes=[byte[]](0x48,0x8B,0x8D,0xB0,0x01,0x00,0x00,0x48,0x8D,0x95,0xD0,0x01,0x00,0x00,0x89,0x44,0x24,0x28,0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x69,0xF2,0xFF,0xFF,0x48,0x8B,0x9D,0xD0,0x01,0x00,0x00,0x48,0x8B,0xF8,0x48,0x8B,0x0D,0xD8,0x92,0xFA,0x01,0x4C,0x8D,0x0D,0xB1,0xF3,0xC6,0x00) }
  [pscustomobject]@{ RVA=0x01291374L
                     Bytes=[byte[]](0x48,0x8B,0x8D,0xB0,0x01,0x00,0x00,0x48,0x8D,0x95,0xD0,0x01,0x00,0x00,0x89,0x44,0x24,0x28,0x4D,0x8B,0xC4,0x8B,0x41,0x04,0x44,0x8B,0x09,0x48,0x8B,0xCE,0x89,0x44,0x24,0x20,0xE8,0x85,0xEA,0xFF,0xFF,0x48,0x8B,0x9D,0xD0,0x01,0x00,0x00,0x48,0x8B,0xF8,0x48,0x8B,0x85,0xB0,0x01,0x00,0x00,0x4C,0x8B,0x40,0x60,0x4D,0x85,0xC0) }
  [pscustomobject]@{ RVA=0x012EB2A4L
                     Bytes=[byte[]](0x80,0x00,0x00,0x00,0xBA,0x01,0x00,0x00,0x00,0x4C,0x8B,0x4F,0x20,0x48,0x03,0xC0,0x48,0x8B,0xCB,0x44,0x8D,0x42,0x14,0x0F,0xB7,0x74,0xC7,0x32,0x8B,0x43,0x14,0x0F,0xAF,0x34,0x83,0xE8,0x14,0x47,0xF3,0xFF,0x4C,0x8B,0x83,0x38,0x0F,0x00,0x00,0x33,0xC9,0x4D,0x85,0xC0,0x74,0x05,0x4D,0x8B,0x00,0xEB,0x03) }
  [pscustomobject]@{ RVA=0x0128FE20L
                     Bytes=[byte[]](0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57,0x48,0x81,0xEC,0xA0,0x00,0x00,0x00,0x48,0x8B,0x05,0x60,0xA0,0xFA,0x01) }
)

$COMMON_TWO_LAYER_CODE = @($VERIFIED_WNO_WRITERS) + @($VERIFIED_PRIMARY_DEPTH_CB)
# 0x11CD890 is where HITMAN DERIVES the foveation mask from the FOV geometry.
# rcx is device+0x410, so [rcx+0xB4] is device+0x4C4 and [rcx+0xB0] is +0x4C0 -
# the two values every version up to 1.5 kept overwriting from the outside.
#
#   0x11CDAB3  movss xmm0,[rcx+0x30]
#   0x11CDAB8  divss xmm0,[rcx+0x18]
#   0x11CDAC1  mulss xmm0,xmm0          <- squared here
#   0x11CDACD  movss [rcx+0xB4],xmm0    <- mask b, the black centre circle
#   0x11CDAC9  mulss xmm2,xmm2          <- and here
#   0x11CDADE  movss [rcx+0xB0],xmm2    <- mask a, the overlay pass
#
# Zeroing the register instead of squaring it is a same-length change, and both
# registers are reloaded immediately afterwards, so nothing else sees it. HITMAN
# then stores zero itself, every time it recalculates - including during every
# save load and every renderer rebuild. There is no value of ours to defend and
# therefore no race, which is what made every guard before this necessary.
$VERIFIED_MASK_SOURCE = @(
  [pscustomobject]@{ Name="mask b zero at source"
                     RVA=0x011CDAC1L
                     Stock=[byte[]](0xF3,0x0F,0x59,0xC0)
                     Fix  =[byte[]](0x0F,0x57,0xC0,0x90) }
  [pscustomobject]@{ Name="mask a zero at source"
                     RVA=0x011CDAC9L
                     Stock=[byte[]](0xF3,0x0F,0x59,0xD2)
                     Fix  =[byte[]](0x0F,0x57,0xD2,0x90) }
)

$BASELINE_CODE = @($COMMON_TWO_LAYER_CODE) + @($VERIFIED_VIEW_COUNT) + @($VERIFIED_VIEW_COUNT_2) + @($VERIFIED_MASK_SOURCE)
$CORE_VIEW_EXTENSION = @($CAMERA_RECORDS_4) + @($CORE_DRAW_GATES_4) + @($OCCLUDER_STATE_4)
$LEGACY_TESTKIT3_SITES = @($REFRACTION_DEPTH_ZERO) + @($CAMERA_STATE_4) + @($ASSAO_DEPTH_4) + @($SSR_FRUSTA_4) + @($CORE_VIEW_EXTENSION)
$ALL_PROFILE_SITES = @($VERIFIED_VIEW_COUNT) + @($CULL_SCATTER_4) + @($LEGACY_TESTKIT3_SITES)
$VERIFIED_CODE = @($BASELINE_CODE)

# Every earlier experimental site remains stock-only. Selected v1.4 call blocks
# are owned by the atomic hook transaction; every unselected block is a guard.
$VERIFIED_GUARDS = @($ALL_PROFILE_SITES) + @($WATER_PASS_CALL) + @($SPRITE_COUNT_GUARD)
$selectedRvas=@($VERIFIED_CODE | ForEach-Object { [Int64]$_.RVA })
$VERIFIED_GUARDS=@($VERIFIED_GUARDS | Where-Object { $selectedRvas -notcontains [Int64]$_.RVA })
foreach ($hookCall in $ALL_HOOK_SITES) {
    if ($MODE_INFO.HookKinds -notcontains $hookCall.Kind) {
        $VERIFIED_GUARDS += $hookCall
    }
}
$profileRvas=@($VERIFIED_CODE | ForEach-Object { [Int64]$_.RVA }) +
             @($VERIFIED_GUARDS | ForEach-Object { [Int64]$_.RVA }) +
             @($ALL_HOOK_SITES | Where-Object { $MODE_INFO.HookKinds -contains $_.Kind } | ForEach-Object { [Int64]$_.RVA })
if (@($profileRvas | Sort-Object -Unique).Count -ne $profileRvas.Count) {
    throw "Internal v1.4 profile error: duplicate code/guard RVA." }
foreach ($site in $VERIFIED_CODE) {
    if ($site.Stock.Length -ne $site.Fix.Length) {
        throw ("Internal v1.4 profile error: unequal patch length at 0x{0:X}." -f $site.RVA) } }

# ===========================================================================
#  PATTERN PATH - used only when the build is not the verified one
# ===========================================================================
$SIGS = @(
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0xB1,0x00,0x90)
    Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00"
    What="two layers instead of four (writer A)" }
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0xB0,0x00,0x90)
    Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00"
    What="two layers instead of four (writer B)" }
  [pscustomobject]@{ Hit=44; Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90)
    Pattern="C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
    What="full field of view, Oculus device" }
  [pscustomobject]@{ Hit=44; Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90)
    Pattern="50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"
    What="full field of view, OpenVR device" }
  [pscustomobject]@{ Hit=12; Fix=[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90)
    Pattern="74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF"
    What="view count 4 - without this, geometry disappears" }
  [pscustomobject]@{ Hit=9;  Fix=[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90)
    Pattern="49 8B 8D A0 41 01 00 74 1A 80 B9 1B 03 00 00 00 BF 02 00 00"
    What="view count 4, second site - without this, one eye keeps an oval mask" }
  # One pattern, two patched instructions. It deliberately runs past both
  # stores and past the reloads of xmm0 and xmm2, because the reloads are the
  # whole safety argument: mulss only touches the low float, xorps clears the
  # entire register. On an unknown build we would rather match nothing than
  # match an arithmetically similar block whose registers are still live.
  [pscustomobject]@{ Hit=14; Fix=[byte[]](0x0F,0x57,0xC0,0x90)
    Pattern="F3 0F 10 41 30 F3 0F 5E 41 18 F3 0F 5E D1 F3 0F 59 C0 41 0F 28 C8 F3 0F 59 D2 F3 0F 11 81 B4 00 00 00 F3 0F 10 41 44 F3 0F 58 C0 F3 0F 11 91 B0 00 00 00 0F 11 99 80 00 00 00 41 0F 28 D8 41 0F 28 D0"
    What="mask b zero at source - the black centre circle" }
  [pscustomobject]@{ Hit=22; Fix=[byte[]](0x0F,0x57,0xD2,0x90)
    Pattern="F3 0F 10 41 30 F3 0F 5E 41 18 F3 0F 5E D1 F3 0F 59 C0 41 0F 28 C8 F3 0F 59 D2 F3 0F 11 81 B4 00 00 00 F3 0F 10 41 44 F3 0F 58 C0 F3 0F 11 91 B0 00 00 00 0F 11 99 80 00 00 00 41 0F 28 D8 41 0F 28 D0"
    What="mask a zero at source - the overlay pass" }
)

# The production transparency fix is located independently of the five v1.3
# sites. The relative CALL displacement is wildcarded and decoded after the
# whole surrounding sequence is proven unique. Both inner calls must resolve to
# the same CopyRefractionDepth function or the untested build is rejected.
$HOOK_SIGS = @(
  [pscustomobject]@{ Name="DrawRefractiveAndTransparent camera call"; Kind="Outer"
    Hit=0; Length=18; CallOffset=13; UnitOffset=0x000L; CounterOffset=0L
    Pattern="48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 ?? ?? ?? ?? 48 8D 8C 24 60 02 00 00" }
  [pscustomobject]@{ Name="CopyRefractionDepth call A"; Kind="CopyA"
    Hit=18; Length=21; CallOffset=16; UnitOffset=0x400L; CounterOffset=0x60L
    Pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D ?? ?? ?? ?? 4C 8D 0D ?? ?? ?? ??" }
  [pscustomobject]@{ Name="CopyRefractionDepth call B"; Kind="CopyB"
    Hit=18; Length=21; CallOffset=16; UnitOffset=0x600L; CounterOffset=0x80L
    Pattern="48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28 4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ?? 48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00 4C 8B 40 60 4D 85 C0" }
)
# Locator only, never patched.
$SIG_DEVICE_PAT = "48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"
$SIG_DEVICE_REL = 3
$SIG_DEVICE_DSP = 15

# --- device field offsets --------------------------------------------------
$OFF_ACTIVE=0x319L; $OFF_TRANS=0x4D8L; $OFF_W=0x510L; $OFF_H=0x514L
$OFF_LAYERS=0x520L; $OFF_TEX=0x530L
$OFF_FOV=0x420L; $OFF_SCALE=0x490L; $OFF_MASK=0x4C0L
[UInt32[]]$SCALE_FIX    = 0x3F800000,0x3F800000,0x3F800000,0x3F800000
[UInt32[]]$SCALE_STOCK  = 0x3EDF2BF0,0x3ECE8B44,0x4012D426,0x401EA625
[byte[]]$MASK_FIX       = 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
[byte[]]$MASK_STOCK     = 0x3D,0x2D,0x66,0x3F, 0xDA,0xB9,0x4D,0x3E

$SELF_DIR =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$LOG_PATH = Join-Path $SELF_DIR "foveationfix.log"

# --- helpers ---------------------------------------------------------------
function RB { param([IntPtr]$h,[Int64]$a,[int]$n)
    $b = New-Object byte[] $n; $r = [IntPtr]::Zero
    if (-not [HmFix]::ReadProcessMemory($h,[IntPtr]$a,$b,$n,[ref]$r) -or $r.ToInt64() -ne $n) {
        throw ("read failed at 0x{0:X}" -f $a) }
    return ,$b }
function Same { param([byte[]]$A,[byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    for ($i=0;$i -lt $A.Length;$i++){ if ($A[$i] -ne $B[$i]) { return $false } }; return $true }
function WB { param([IntPtr]$h,[Int64]$a,[byte[]]$b)
    $w = [IntPtr]::Zero
    if (-not [HmFix]::WriteProcessMemory($h,[IntPtr]$a,$b,$b.Length,[ref]$w) -or $w.ToInt64() -ne $b.Length) {
        throw ("write failed at 0x{0:X}" -f $a) }
    if (-not [HmFix]::FlushInstructionCache($h,[IntPtr]$a,[UIntPtr]::op_Explicit($b.Length))) {
        throw ("instruction-cache flush failed at 0x{0:X}" -f $a) } }
function U8  { param($h,$a) (RB $h $a 1)[0] }
function U16 { param($h,$a) [BitConverter]::ToUInt16((RB $h $a 2),0) }
function U32 { param($h,$a) [BitConverter]::ToUInt32((RB $h $a 4),0) }
function I64 { param($h,$a) [BitConverter]::ToInt64((RB $h $a 8),0) }
function W2B { param([UInt32[]]$W)
    $o = New-Object byte[] ($W.Length*4)
    for ($i=0;$i -lt $W.Length;$i++){ [Array]::Copy([BitConverter]::GetBytes($W[$i]),0,$o,$i*4,4) }
    return ,$o }
function Hex-Bytes { param([string]$Text)
    $tokens=@($Text -split '\s+' | Where-Object { $_ })
    $out=New-Object byte[] $tokens.Count
    for ($i=0;$i -lt $tokens.Count;$i++) { $out[$i]=[Convert]::ToByte($tokens[$i],16) }
    return ,$out }
function Join-Bytes { param([object[]]$Parts)
    $length=0
    foreach ($part in $Parts) { $length += ([byte[]]$part).Length }
    $out=New-Object byte[] $length; $offset=0
    foreach ($part in $Parts) {
        $bytes=[byte[]]$part
        [Array]::Copy($bytes,0,$out,$offset,$bytes.Length)
        $offset += $bytes.Length }
    return ,$out }
function U64B { param([UInt64]$Value) return ,[BitConverter]::GetBytes($Value) }

# v1.4's owner-aware wrapper blobs are built declaratively below. Labels
# and RIP-relative data references are resolved after emission, avoiding hand-
# maintained branch displacements while retaining deterministic byte images.
function New-ByteBuilder { param([Int64]$Origin)
    [pscustomobject]@{ Origin=$Origin; Bytes=New-Object 'System.Collections.Generic.List[byte]'; Labels=@{}; Branches=New-Object System.Collections.ArrayList } }
function Emit-Bytes { param($Builder,[byte[]]$Bytes) foreach($x in $Bytes){$Builder.Bytes.Add($x)} }
function Emit-Hex { param($Builder,[string]$Text) Emit-Bytes $Builder (Hex-Bytes $Text) }
function Mark-Label { param($Builder,[string]$Name) if($Builder.Labels.ContainsKey($Name)){throw "duplicate wrapper label"};$Builder.Labels[$Name]=$Builder.Bytes.Count }
function Emit-J8 { param($Builder,[byte]$Opcode,[string]$Target)
    $Builder.Bytes.Add($Opcode);$p=$Builder.Bytes.Count;$Builder.Bytes.Add(0)
    [void]$Builder.Branches.Add([pscustomobject]@{Position=$p;Size=1;Target=$Target}) }
function Emit-J32 { param($Builder,[byte[]]$Opcode,[string]$Target)
    Emit-Bytes $Builder $Opcode;$p=$Builder.Bytes.Count
    1..4|ForEach-Object{$Builder.Bytes.Add(0)}
    [void]$Builder.Branches.Add([pscustomobject]@{Position=$p;Size=4;Target=$Target}) }
function Emit-Rip32 { param($Builder,[byte[]]$Prefix,[Int64]$Target) Emit-Bytes $Builder $Prefix;$next=$Builder.Origin+$Builder.Bytes.Count+4L;$d=$Target-$next;if($d -lt [Int32]::MinValue -or $d -gt [Int32]::MaxValue){throw "wrapper RIP target out of range"};Emit-Bytes $Builder ([BitConverter]::GetBytes([Int32]$d)) }
function Finish-ByteBuilder { param($Builder)
    foreach($j in $Builder.Branches){
        if(-not $Builder.Labels.ContainsKey($j.Target)){throw "missing wrapper label"}
        $d=[Int64]$Builder.Labels[$j.Target]-([Int64]$j.Position+[Int64]$j.Size)
        if($j.Size -eq 1){
            if($d -lt -128 -or $d -gt 127){throw "short wrapper branch out of range"}
            $Builder.Bytes[$j.Position]=[byte]([sbyte]$d)
        } else {
            if($d -lt [Int32]::MinValue -or $d -gt [Int32]::MaxValue){throw "near wrapper branch out of range"}
            $raw=[BitConverter]::GetBytes([Int32]$d)
            for($i=0;$i -lt 4;$i++){$Builder.Bytes[$j.Position+$i]=$raw[$i]}
        }
    }
    return ,$Builder.Bytes.ToArray() }

function Build-OuterUnit { param([Int64]$Unit,[Int64]$Target,[bool]$ChangeCount)
    $data=$Unit+0x1000L
    $b=New-ByteBuilder $Unit

    # Proven TestKit-6 ABI frame plus an owner scope. ownerCtx is the atomic
    # gate; ownerTid is published only after acquisition. Local byte +5C uses
    # bit 0 for ownership and bit 1 for a count change.
    Emit-Hex $b 'F3 0F 1E FA'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x30L)
    Emit-Hex $b @'
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
'@
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x00L)
    Emit-Hex $b '8B 41 14 89 44 24 58'
    Emit-Rip32 $b (Hex-Bytes '3B 05') ($data+0x24L)
    Emit-J8 $b 0x76 'max_top_ok'
    Emit-Rip32 $b (Hex-Bytes '89 05') ($data+0x24L)
    Mark-Label $b 'max_top_ok'
    Emit-Hex $b '83 F8 04'
    Emit-J8 $b 0x77 'bad_count'
    Emit-Hex $b '44 8B 14 81'
    Emit-Rip32 $b (Hex-Bytes '44 89 15') ($data+0x20L)
    Emit-Hex $b '41 83 FA 04'
    Emit-J8 $b 0x74 'count_four'
    Emit-Hex $b '41 83 FA 01'
    Emit-J32 $b (Hex-Bytes '0F 84') 'call_target'
    Emit-Hex $b '41 83 FA 02'
    Emit-J8 $b 0x74 'count_two'
    Mark-Label $b 'bad_count'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x18L)
    Emit-J32 $b (Hex-Bytes 'E9') 'call_target'

    # Count two is ordinary only when no owner exists. A nonzero owner means
    # re-entry or another thread observed the temporary shared state.
    Mark-Label $b 'count_two'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x40L)
    Emit-Hex $b '4D 85 DB'
    Emit-J8 $b 0x74 'call_target'
    Emit-J32 $b (Hex-Bytes 'E9') 'owner_conflict'

    Mark-Label $b 'count_four'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x30L)
    Emit-Hex $b '49 83 FB 01'
    Emit-J8 $b 0x75 'owner_conflict'
    Emit-Hex $b '33 C0'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 0F B1 0D') ($data+0x40L)
    Emit-J8 $b 0x75 'owner_conflict'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 89 15') ($data+0x38L)
    Emit-Hex $b '80 4C 24 5C 01'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x48L)
    if($ChangeCount){
        Emit-Hex $b '8B 44 24 58 C7 04 81 02 00 00 00 80 4C 24 5C 02'
        Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x08L)
    }
    Emit-J32 $b (Hex-Bytes 'E9') 'call_target'

    Mark-Label $b 'owner_conflict'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'call_target'
    Emit-Hex $b '48 B8'
    Emit-Bytes $b (U64B ([UInt64]$Target))
    Emit-Hex $b 'FF D0 48 89 44 24 60'

    Emit-Hex $b 'F6 44 24 5C 02'
    Emit-J8 $b 0x74 'after_restore'
    Emit-Hex $b '48 8B 4C 24 50 8B 44 24 58 83 F8 04'
    Emit-J8 $b 0x77 'restore_bad'
    Emit-Hex $b '83 3C 81 02'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-Hex $b 'C7 04 81 04 00 00 00'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x10L)
    Emit-Hex $b '39 41 14'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-J8 $b 0xEB 'after_restore'
    Mark-Label $b 'restore_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'after_restore'
    Emit-Hex $b 'F6 44 24 5C 01'
    Emit-J8 $b 0x74 'finish'
    Emit-Hex $b '48 8B 4C 24 50'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x40L)
    Emit-Hex $b '4C 3B D9'
    Emit-J8 $b 0x75 'release_bad'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 3B 15') ($data+0x38L)
    Emit-J8 $b 0x75 'release_bad'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 1D') ($data+0x30L)
    Emit-Hex $b '49 83 FB 01'
    Emit-J8 $b 0x75 'release_bad'
    # Emit-Rip32 targets the end of its displacement field, so avoid a
    # RIP-relative store with a trailing imm32 and clear through R10 instead.
    Emit-Hex $b '45 33 D2'
    Emit-Rip32 $b (Hex-Bytes '4C 89 15') ($data+0x38L)
    Emit-Hex $b '48 8B C1'
    Emit-Rip32 $b (Hex-Bytes 'F0 4C 0F B1 15') ($data+0x40L)
    Emit-J8 $b 0x75 'release_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x50L)
    Emit-J8 $b 0xEB 'finish'
    Mark-Label $b 'release_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'finish'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 0D') ($data+0x30L)
    Emit-Hex $b '48 8B 44 24 60 48 83 C4 78 C3'
    Finish-ByteBuilder $b
}

function Emit-OwnerChecks { param($Builder,[Int64]$Data,[string]$NoOwnerLabel,[string]$MismatchLabel,[string]$ContextRegister)
    Emit-Rip32 $Builder (Hex-Bytes '4C 8B 1D') ($Data+0x40L)
    Emit-Hex $Builder '4D 85 DB'
    Emit-J8 $Builder 0x74 $NoOwnerLabel
    if($ContextRegister -eq 'rcx'){Emit-Hex $Builder '4C 3B D9'}
    elseif($ContextRegister -eq 'rbx'){Emit-Hex $Builder '4C 3B DB'}
    else{throw 'unsupported owner context register'}
    Emit-J8 $Builder 0x75 $MismatchLabel
    Emit-Hex $Builder '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $Builder (Hex-Bytes '4C 3B 15') ($Data+0x38L)
    Emit-J8 $Builder 0x75 $MismatchLabel
}

function Build-MeshUnit { param([Int64]$Unit)
    # Mesh lives at cave+200; all wrappers deliberately share cave+1000 data.
    $data=$Unit+0xE00L
    $b=New-ByteBuilder $Unit
    Emit-Hex $b @'
F3 0F 1E FA
8B 41 14 41 8B E9 45 8B F0 8B F2 48 8B D9 8B 3C 81
'@
    # This helper is global: absent or mismatched ownership remains stock.
    Emit-OwnerChecks $b $data 'done' 'done' 'rbx'
    Emit-Rip32 $b (Hex-Bytes '4C 8B 15') ($data+0x30L)
    Emit-Hex $b '49 83 FA 01'
    Emit-J8 $b 0x75 'bad'
    Emit-Hex $b '83 FF 02'
    Emit-J8 $b 0x75 'bad'
    Emit-Hex $b 'BF 04 00 00 00'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x58L)
    Emit-J8 $b 0xEB 'done'
    Mark-Label $b 'bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)
    Mark-Label $b 'done'
    Emit-Hex $b 'C3'
    Finish-ByteBuilder $b
}

function Build-CopyUnit { param($Call,[Int64]$Unit,[Int64]$Target,[int]$FromCount,[int]$ToCount)
    if(($FromCount -ne 4 -or $ToCount -ne 2) -and ($FromCount -ne 2 -or $ToCount -ne 4)){
        throw 'unsupported CopyRefractionDepth count scope'}
    [Int64]$counterOffset=[Int64]$Call.CounterOffset
    if($counterOffset -ne 0x60L -and $counterOffset -ne 0x80L){throw 'invalid copy telemetry block'}
    $data=$Unit+(0x1000L-[Int64]$Call.UnitOffset)
    $b=New-ByteBuilder $Unit
    Emit-Hex $b 'F3 0F 1E FA'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x18L)

    # Replay the common 21-byte setup/call block. The old caller's sixth
    # argument moves from new [rsp+88] to the wrapper call's [rsp+28].
    Emit-Hex $b @'
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
'@
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset)
    Emit-Hex $b '8B 41 14 89 44 24 30'
    Emit-Rip32 $b (Hex-Bytes '3B 05') ($data+0x24L)
    Emit-J8 $b 0x76 'max_top_ok'
    Emit-Rip32 $b (Hex-Bytes '89 05') ($data+0x24L)
    Mark-Label $b 'max_top_ok'
    Emit-Hex $b '83 F8 04'
    Emit-J8 $b 0x77 'bad_count'
    Emit-Hex $b '44 8B 1C 81'
    Emit-Rip32 $b (Hex-Bytes '44 89 1D') ($data+0x20L)

    # Preserve R11D (observed count). owner zero with current 1/2 is a stock
    # desktop/unselected path; owner zero with current 4 is unexpected here.
    Emit-Rip32 $b (Hex-Bytes '48 8B 05') ($data+0x40L)
    Emit-Hex $b '48 85 C0'
    Emit-J8 $b 0x74 'no_owner'
    Emit-Hex $b '48 3B C1'
    Emit-J8 $b 0x75 'owner_bad'
    Emit-Hex $b '65 4C 8B 14 25 48 00 00 00'
    Emit-Rip32 $b (Hex-Bytes '4C 3B 15') ($data+0x38L)
    Emit-J8 $b 0x75 'owner_bad'
    Emit-Rip32 $b (Hex-Bytes '48 8B 05') ($data+0x30L)
    Emit-Hex $b '48 83 F8 01'
    Emit-J8 $b 0x75 'owner_bad'
    Emit-J8 $b 0xEB 'owner_ok'
    Mark-Label $b 'no_owner'
    Emit-Hex $b '41 83 FB 01'
    Emit-J8 $b 0x74 'call_target'
    Emit-Hex $b '41 83 FB 02'
    Emit-J8 $b 0x74 'call_target'
    Emit-J8 $b 0xEB 'owner_bad'
    Mark-Label $b 'owner_ok'
    Emit-Hex $b '8B 44 24 30'

    Emit-Hex $b ('41 83 FB {0:X2}' -f $FromCount)
    Emit-J8 $b 0x74 'change_count'
    Emit-J8 $b 0xEB 'bad_count'
    Mark-Label $b 'change_count'
    Emit-Hex $b ('C7 04 81 {0:X2} 00 00 00 C6 44 24 34 01' -f $ToCount)
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x08L)
    Emit-J8 $b 0xEB 'call_target'
    Mark-Label $b 'bad_count'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x18L)
    Emit-J8 $b 0xEB 'call_target'
    Mark-Label $b 'owner_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'call_target'
    Emit-Hex $b '48 B8'
    Emit-Bytes $b (U64B ([UInt64]$Target))
    Emit-Hex $b 'FF D0 48 89 44 24 40'
    Emit-Hex $b '80 7C 24 34 01'
    Emit-J8 $b 0x75 'finish'
    Emit-Hex $b '48 8B 4C 24 38 8B 44 24 30 83 F8 04'
    Emit-J8 $b 0x77 'restore_bad'
    Emit-Hex $b ('83 3C 81 {0:X2}' -f $ToCount)
    Emit-J8 $b 0x75 'restore_bad'
    Emit-Hex $b ('C7 04 81 {0:X2} 00 00 00' -f $FromCount)
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+$counterOffset+0x10L)
    Emit-Hex $b '39 41 14'
    Emit-J8 $b 0x75 'restore_bad'
    Emit-J8 $b 0xEB 'finish'
    Mark-Label $b 'restore_bad'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 05') ($data+0x28L)

    Mark-Label $b 'finish'
    Emit-Rip32 $b (Hex-Bytes 'F0 48 FF 0D') ($data+$counterOffset+0x18L)
    Emit-Hex $b '48 8B 44 24 40 48 83 C4 58 C3'
    Finish-ByteBuilder $b
}

function Build-CallPatch { param($Call,[Int64]$Cave)
    $length=$Call.Stock.Length
    if ($length -lt 16 -or $length -gt 127) { throw "invalid hook patch-block length" }
    $out=New-Object byte[] $length
    for ($i=0;$i -lt $length;$i++) { $out[$i]=0x90 }
    [byte[]]$head=0xFF,0x15,0x02,0x00,0x00,0x00,0xEB,[byte]($length-8)
    [Array]::Copy($head,0,$out,0,$head.Length)
    [Array]::Copy((U64B ([UInt64]($Cave+[Int64]$Call.UnitOffset))),0,$out,8,8)
    return ,$out
}

function Allocate-HookMemory {
    $allocated=[HmFix]::VirtualAllocEx($script:handle,[IntPtr]::Zero,[UIntPtr]::op_Explicit(0x2000),0x3000,0x04)
    if ($allocated -eq [IntPtr]::Zero) { return 0L }
    return $allocated.ToInt64()
}
function Suspend-GameThreads {
    if ($script:unsafeCodeState) {
        throw "the game is deliberately suspended after an unverified code rollback" }
    if ($script:suspendedHandles.Count -gt 0 -and -not (Resume-GameThreads @())) {
        throw "a previously suspended game thread could not be resumed" }
    $held=@(); $seen=@{}
    try {
        for ($round=0;$round -lt 3;$round++) {
            $added=0
            $script:process.Refresh()
            foreach ($thread in @($script:process.Threads)) {
                $tid=[UInt32]$thread.Id
                if ($seen.ContainsKey($tid)) { continue }
                $handle=[HmFix]::OpenThread(0x0010000A,$false,$tid) # SYNCHRONIZE | SUSPEND_RESUME | GET_CONTEXT
                if ($handle -eq [IntPtr]::Zero) {
                    $openError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    if ($openError -eq 87) { continue } # thread ended between snapshot and OpenThread
                    throw ("could not open game thread {0} (Windows error {1})" -f $tid,$openError) }
                $previous=[HmFix]::SuspendThread($handle)
                if ($previous -eq [UInt32]::MaxValue) {
                    $ended=([HmFix]::WaitForSingleObject($handle,0) -eq 0)
                    [HmFix]::CloseHandle($handle) | Out-Null
                    if ($ended) { continue }
                    throw ("could not suspend game thread {0}" -f $tid) }
                $held += [pscustomobject]@{ Id=$tid; Handle=$handle }
                $seen[$tid]=$true; $added++ }
            if ($added -eq 0) { return $held }
            Start-Sleep -Milliseconds 5 }
        $script:process.Refresh()
        foreach ($thread in @($script:process.Threads)) {
            if (-not $seen.ContainsKey([UInt32]$thread.Id)) { throw "game thread list did not become stable" } }
        return $held
    } catch {
        Resume-GameThreads $held | Out-Null
        throw
    }
}
function Resume-GameThreads { param([object[]]$Held)
    if ($script:unsafeCodeState) { return $false }
    $ok=$true
    $pending=@($script:suspendedHandles)+@($Held)
    $script:suspendedHandles=@()
    $seenHandles=@{}
    foreach ($item in @($pending)) {
        if ($null -eq $item -or $null -eq $item.Handle -or $item.Handle -isnot [IntPtr]) { $ok=$false; continue }
        $key=$item.Handle.ToInt64().ToString("X")
        if ($seenHandles.ContainsKey($key)) { continue }
        $seenHandles[$key]=$true
        $released=$false
        for ($attempt=0;$attempt -lt 3 -and -not $released;$attempt++) {
            try {
                if ([HmFix]::ResumeThread($item.Handle) -ne [UInt32]::MaxValue) { $released=$true; break }
                if ([HmFix]::WaitForSingleObject($item.Handle,0) -eq 0) { $released=$true; break }
            } catch {}
            if (-not $released) { Start-Sleep -Milliseconds 2 } }
        if ($released) {
            try { [HmFix]::CloseHandle($item.Handle) | Out-Null } catch { $ok=$false } }
        else {
            $script:suspendedHandles += $item
            $ok=$false } }
    return $ok
}
function Threads-AreOutsidePatchRanges { param([object[]]$Held,[object[]]$Ranges)
    foreach ($item in @($Held)) {
        if ($null -eq $item -or $null -eq $item.Handle -or $item.Handle -isnot [IntPtr]) {
            throw "the suspended-thread list has an invalid shape" }
        [UInt64]$rip=0
        [Int32]$contextError=0
        if (-not [HmFix]::TryGetThreadRip($item.Handle,[ref]$rip,[ref]$contextError)) {
            throw ("could not verify the instruction pointer of game thread {0} (Windows error {1})" -f $item.Id,$contextError) }
        foreach ($range in @($Ranges)) {
            if ($rip -ge [UInt64]$range.Start -and $rip -lt [UInt64]$range.End) { return $false } }
    }
    return $true
}
function Log { param($t)
    try { Add-Content -Path $LOG_PATH -Value ("{0}  [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$MODE_INFO.Short,$t) -Encoding UTF8 } catch {} }

# --- PE parsing / pattern search (pattern path only) -----------------------
function Read-PE { param([string]$path)
    $b = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($b,0x3C)
    $stamp   = [BitConverter]::ToInt32($b,$pe+8)
    $nsec    = [BitConverter]::ToUInt16($b,$pe+6)
    $optSize = [BitConverter]::ToUInt16($b,$pe+20)
    $tRVA=0; $tOff=0; $tSize=0
    for ($i=0;$i -lt $nsec;$i++) {
        $o = $pe+24+$optSize+$i*40
        $name = [Text.Encoding]::ASCII.GetString($b,$o,8).TrimEnd([char]0)
        if ($name -eq ".text") {
            $tSize=[BitConverter]::ToInt32($b,$o+16)
            $tRVA =[BitConverter]::ToInt32($b,$o+12)
            $tOff =[BitConverter]::ToInt32($b,$o+20); break } }
    if ($tRVA -eq 0) { throw "no .text section" }
    $text = New-Object byte[] $tSize
    [Array]::Copy($b,$tOff,$text,0,$tSize)
    return [pscustomobject]@{ Stamp=$stamp; TextRVA=$tRVA; Text=$text } }

# Pattern parsing is unchanged and still happens here; only the search itself
# moved into HmFix.FindPattern. maxHits=1 reproduces the old early exit exactly:
# the loop stopped as soon as a second match was found, because every caller
# treats "not exactly one" as a refusal.
function Find-Sig { param([byte[]]$hay,[string]$pat)
    $tok=$pat.Split(" "); $n=$tok.Count
    $val=New-Object int[] $n
    for ($i=0;$i -lt $n;$i++) {
        if ($tok[$i] -eq "??") { $val[$i]=-1 } else { $val[$i]=[Convert]::ToInt32($tok[$i],16) } }
    # No unary comma here. ",$array" would return the int[] as ONE pipeline
    # object, so @(Find-Sig ...) would always have Count 1 and the fail-closed
    # "exactly one match" test would pass for zero and for two matches alike.
    # Returning the array plainly lets PowerShell enumerate it, so the callers
    # see 0, 1 or 2 offsets as they always did.
    [int[]]$hits = [HmFix]::FindPattern($hay,$val,1)
    if ($null -eq $hits) { return @() }
    return $hits }

# --- state -----------------------------------------------------------------
$script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
$script:mode=""            # verified | scanned
$script:sites=@()
$script:guardSites=@()       # verified-only preconditions; never written/restored
$script:writtenSites=@()    # only sites this instance owns and may restore
$script:hookDescriptors=@() # verified or uniquely pattern-located v1.4 call blocks
$script:hookSites=@()       # dynamic indirect-CALL blocks owned by this instance
$script:hookCave=0L; $script:hookPrepared=$false
$script:lastHookLog=[DateTime]::MinValue
$script:lastHookIntegrityCheck=[DateTime]::MinValue
$script:hookProgress=@{}
$script:lastPatchBusyLog=[DateTime]::MinValue
$script:suspendedHandles=@()
$script:unsafeCodeState=$false
$script:devSlot=0L         # pattern path: RVA of the device pointer
$script:wnoOff=$OFF_ACTIVE
$script:patched=$false
$script:dev=0L; $script:lastTrans=-1L
$script:stableReady=0; $script:stableSince=0L
$script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
$script:lastUi=""
$script:fatal=""; $script:stopped=$false
$script:lastAttachScan=0L
# -ExitWithGame gives up if HITMAN never appears, so a cancelled launch does
# not leave the tool waiting in the background forever.
$AUTO_GIVE_UP_SECONDS=600
$script:everAttached=$false
$script:startedTs=[Diagnostics.Stopwatch]::GetTimestamp()





# v1.6 owns no renderer values, so there is no ownership that can become
# uncertain and nothing to hand back when a device goes away.
function Reset-DeviceState {
    $script:dev=0L; $script:lastTrans=-1L
    $script:stableReady=0; $script:stableSince=0L
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    }

function Advance-Lifecycle {
    param([Int64]$LastTransition,[UInt32]$Transition)
    $changed=($LastTransition -ne [Int64]$Transition)
    return [pscustomobject]@{
        LastTransition=[Int64]$Transition
        TransitionChanged=$changed
        ResetStable=$changed }
}


function Detach {
    foreach ($item in @($script:suspendedHandles)) {
        try { [HmFix]::CloseHandle($item.Handle) | Out-Null } catch {} }
    $script:suspendedHandles=@()
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    $script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
    $script:mode=""; $script:sites=@(); $script:guardSites=@(); $script:writtenSites=@(); $script:hookDescriptors=@(); $script:hookSites=@()
    $script:hookCave=0L; $script:hookPrepared=$false; $script:lastHookLog=[DateTime]::MinValue
    $script:lastHookIntegrityCheck=[DateTime]::MinValue; $script:hookProgress=@{}
    $script:lastPatchBusyLog=[DateTime]::MinValue
    $script:unsafeCodeState=$false
    $script:devSlot=0L; $script:patched=$false
    $script:dev=0L; $script:lastTrans=-1L
    $script:stableReady=0; $script:stableSince=0L
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    $script:lastUi=""
    }

function Game-IsAlive {
    if ($script:handle -eq [IntPtr]::Zero) { return $false }
    try {
        $wait=[HmFix]::WaitForSingleObject($script:handle,0)
        if ($wait -eq 0) { return $false }       # WAIT_OBJECT_0: process exited
        return $true                            # WAIT_TIMEOUT or failure: fail closed
    } catch { return $true }
}

# A return from the wrapper intentionally lands in the dynamic call block.  It
# is therefore unsafe to rewrite that block while HITMAN can still have a thread
# at the call or inside the wrapper.  Unknown/unreadable bytes fail closed too.
function Hook-PatchMayBeLive {
    if (-not $MODE_INFO.UsesHook -or $script:hookSites.Count -eq 0) { return $false }
    if ($script:patched) { return $true }
    foreach ($site in $script:hookSites) {
        try {
            $cur=RB $script:handle ($script:base+$site.RVA) $site.Stock.Length
            if (Same $cur $site.Fix) { return $true }
            if (-not (Same $cur $site.Stock)) { return $true }
        } catch { return $true }
    }
    return $false
}

function Changes-MayBeLive {
    if ($script:patched -or $script:writtenSites.Count -gt 0 -or
        $script:suspendedHandles.Count -gt 0 -or $script:unsafeCodeState) { return $true }
    return (Hook-PatchMayBeLive)
}

# --- window ----------------------------------------------------------------
$form=New-Object Windows.Forms.Form
$form.Text="HitmanVRFoveationFix v1.6.1"
$form.ClientSize=New-Object Drawing.Size(520,318)
$form.FormBorderStyle="FixedSingle"; $form.MaximizeBox=$false
$form.StartPosition="CenterScreen"
# Launched with the game: do not pop up over it. The status is still in the
# taskbar title (see Show-State).
if ($ExitWithGame) { $form.WindowState="Minimized" }
$form.Font=New-Object Drawing.Font("Segoe UI",9)

$title=New-Object Windows.Forms.Label
$title.Location=New-Object Drawing.Point(20,18); $title.Size=New-Object Drawing.Size(480,28)
$title.Text=$MODE_INFO.Title
$title.Font=New-Object Drawing.Font("Segoe UI",13,[Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$dot=New-Object Windows.Forms.Label
$dot.Location=New-Object Drawing.Point(20,64); $dot.Size=New-Object Drawing.Size(22,22)
$dot.Text=[char]0x25CF; $dot.Font=New-Object Drawing.Font("Segoe UI",16)
$dot.ForeColor=[Drawing.Color]::Gray
$form.Controls.Add($dot)

$state=New-Object Windows.Forms.Label
$state.Location=New-Object Drawing.Point(46,62); $state.Size=New-Object Drawing.Size(456,28)
$state.Font=New-Object Drawing.Font("Segoe UI",12,[Drawing.FontStyle]::Bold)
$form.Controls.Add($state)

$detail=New-Object Windows.Forms.Label
$detail.Location=New-Object Drawing.Point(22,96); $detail.Size=New-Object Drawing.Size(478,74)
$detail.Font=New-Object Drawing.Font("Segoe UI",9)
$form.Controls.Add($detail)

$note=New-Object Windows.Forms.Label
$note.Location=New-Object Drawing.Point(22,176); $note.Size=New-Object Drawing.Size(478,36)
$note.Font=New-Object Drawing.Font("Segoe UI",9,[Drawing.FontStyle]::Bold)
$note.ForeColor=[Drawing.Color]::FromArgb(190,110,0)
$form.Controls.Add($note)

$steps=New-Object Windows.Forms.Label
$steps.Location=New-Object Drawing.Point(22,214); $steps.Size=New-Object Drawing.Size(478,34)
$steps.Font=New-Object Drawing.Font("Segoe UI",9)
$steps.ForeColor=[Drawing.Color]::FromArgb(90,90,90)
$steps.Text="Start this tool before HITMAN. Leave the window open while you play."
$form.Controls.Add($steps)

$btnStop=New-Object Windows.Forms.Button
$btnStop.Location=New-Object Drawing.Point(22,252); $btnStop.Size=New-Object Drawing.Size(200,36)
$btnStop.Text="Turn off and restore"; $btnStop.Enabled=$false
$form.Controls.Add($btnStop)

$link=New-Object Windows.Forms.LinkLabel
$link.Location=New-Object Drawing.Point(240,260); $link.Size=New-Object Drawing.Size(260,22)
$link.Text="v1.6.1 - project page"
$link.LinkArea=New-Object Windows.Forms.LinkArea(0,6)
$link.TextAlign="MiddleRight"
$link.Add_LinkClicked({ Start-Process "https://github.com/RealChrizzl/hitman-vr-foveation-fix" })
$form.Controls.Add($link)

function Show-State { param($colour,$head,$body,$warn="")
    $uiKey=$colour+"`n"+$head+"`n"+$body+"`n"+$warn
    if ($script:lastUi -eq $uiKey) { return }
    $script:lastUi=$uiKey
    $dot.ForeColor = switch ($colour) {
        "green" { [Drawing.Color]::FromArgb(0,150,60) }
        "amber" { [Drawing.Color]::FromArgb(220,140,0) }
        "red"   { [Drawing.Color]::Firebrick }
        default { [Drawing.Color]::Gray } }
    $state.Text=$head; $detail.Text=$body; $note.Text=$warn
    $form.Text="HitmanVRFoveationFix v1.6.1 - $head" }

Show-State "grey" "Waiting for HITMAN" "Start HITMAN after this tool. It will apply the fix before VR starts."

# --- attach ----------------------------------------------------------------
function Try-Attach {
    $procs=@()
    foreach ($candidate in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        try { if (-not $candidate.HasExited) { $procs += $candidate } } catch {} }
    if ($procs.Count -eq 0) { return $false }
    if ($procs.Count -gt 1) { $script:fatal="More than one HITMAN process is running. Close them all and start the game once."; return $false }
    $p=$procs[0]
    try { if ($p.HasExited) { return $false } } catch { return $false }
    try { $path=$p.MainModule.FileName; $b=$p.MainModule.BaseAddress.ToInt64() } catch { return $false }

    try { $peCheck=Read-PE $path }
    catch { $script:fatal="Could not verify the game executable's code section."; return $false }
    $stamp=$peCheck.Stamp

    $sites=@(); $guards=@(); $hooks=@(); $mode=""; $slot=0L; $wno=0x31BL
    if ($stamp -eq $VERIFIED_TIMESTAMP) {
        # The hash only ever gated the verified path, so it is computed there.
        # An unknown build no longer pays for a SHA-256 of the whole executable
        # before a scan it is already waiting on.
        try { $exeHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant() }
        catch { $script:fatal="Could not verify the game executable."; return $false }
        if ($exeHash -ne $VERIFIED_SHA256) {
            Log ("refused executable hash {0}" -f $exeHash)
            $script:fatal="This executable has the verified build number but different code. Nothing was changed."
            return $false }
        foreach ($ctx in $VERIFIED_DIAGNOSTIC_CONTEXTS) {
            $offset=[int64]$ctx.RVA-[int64]$peCheck.TextRVA
            if ($offset -lt 0 -or ($offset+$ctx.Bytes.Length) -gt $peCheck.Text.Length) {
                $script:fatal="A verified instruction context falls outside the code section. Nothing was changed."
                return $false }
            $actual=New-Object byte[] $ctx.Bytes.Length
            [Array]::Copy($peCheck.Text,[int]$offset,$actual,0,$actual.Length)
            if (-not (Same $actual $ctx.Bytes)) {
                Log ("refused context mismatch at RVA 0x{0:X}" -f $ctx.RVA)
                $script:fatal="A verified instruction context does not match the executable. Nothing was changed."
                return $false } }

        $mode="verified"
        foreach ($c in $VERIFIED_CODE) {
            $sites += [pscustomobject]@{ Name=$c.Name; RVA=$c.RVA; Stock=$c.Stock; Fix=$c.Fix } }
        foreach ($g in $VERIFIED_GUARDS) {
            $guards += [pscustomobject]@{ Name=$g.Name; RVA=$g.RVA; Stock=$g.Stock } }
        $hooks=@($COPY_DEPTH_CALL_A,$COPY_DEPTH_CALL_B,$TRANSPARENT_PASS_CALL)
        $wno=$VERIFIED_WNO_OFF
    } else {
        $mode="scanned"
        # This build is not the verified one, so every site has to be located by
        # signature. Say so and PAINT it before the scan starts - Refresh forces
        # an immediate repaint without pumping the message queue, so the timer
        # cannot re-enter this function while it runs.
        Show-State "amber" "Scanning this HITMAN build" "This build is not the verified one, so the code is being located by signature. Please wait for this window before starting VR."
        try { $form.Refresh() } catch {}
        $scanClock=[Diagnostics.Stopwatch]::StartNew()

        foreach ($sig in $SIGS) {
            $hits=@(Find-Sig $peCheck.Text $sig.Pattern)
            if ($hits.Count -ne 1) {
                $script:fatal="The code for '" + $sig.What + "' could not be located uniquely in this build. Nothing was changed."
                return $false }
            $stock=New-Object byte[] $sig.Fix.Length
            [Array]::Copy($peCheck.Text,$hits[0]+$sig.Hit,$stock,0,$stock.Length)
            $sites += [pscustomobject]@{ Name=$sig.What; RVA=[int64]($peCheck.TextRVA+$hits[0]+$sig.Hit); Stock=$stock; Fix=$sig.Fix } }

        foreach ($sig in $HOOK_SIGS) {
            $hits=@(Find-Sig $peCheck.Text $sig.Pattern)
            if ($hits.Count -ne 1) {
                $script:fatal="The v1.4 refraction code for '" + $sig.Name + "' could not be located uniquely. Nothing was changed."
                return $false }
            $siteOffset=[int]($hits[0]+$sig.Hit)
            $stock=New-Object byte[] $sig.Length
            [Array]::Copy($peCheck.Text,$siteOffset,$stock,0,$stock.Length)
            if ($stock[$sig.CallOffset] -ne 0xE8) {
                $script:fatal="A located v1.4 refraction call has an unexpected instruction shape. Nothing was changed."
                return $false }
            $rel=[BitConverter]::ToInt32($stock,$sig.CallOffset+1)
            $rva=[int64]($peCheck.TextRVA+$siteOffset)
            $target=[int64]($rva+$sig.CallOffset+5L+$rel)
            if ($target -lt $peCheck.TextRVA -or $target -ge ($peCheck.TextRVA+$peCheck.Text.Length)) {
                $script:fatal="A located v1.4 refraction target falls outside executable code. Nothing was changed."
                return $false }
            $hooks += [pscustomobject]@{
                Name=$sig.Name; Kind=$sig.Kind; RVA=$rva; TargetRVA=$target
                ContinuationRVA=[int64]($rva+$sig.Length); UnitOffset=[int64]$sig.UnitOffset
                CounterOffset=[int64]$sig.CounterOffset; Stock=$stock }
        }
        $copyTargets=@($hooks | Where-Object {$_.Kind -like "Copy*"} | ForEach-Object {[int64]$_.TargetRVA} | Sort-Object -Unique)
        if ($copyTargets.Count -ne 1) {
            $script:fatal="The two located refraction-depth calls do not share one target. Nothing was changed."
            return $false }

        $hits=@(Find-Sig $peCheck.Text $SIG_DEVICE_PAT)
        if ($hits.Count -ne 1) {
            $script:fatal="The VR device reference could not be located uniquely in this build. Nothing was changed."
            return $false }
        $at=$hits[0]
        $rel=[BitConverter]::ToInt32($peCheck.Text,$at+$SIG_DEVICE_REL)
        $slot=[int64]($peCheck.TextRVA+$at+7+$rel)
        $wno=[int64][BitConverter]::ToUInt32($peCheck.Text,$at+$SIG_DEVICE_DSP)
        if ($wno -le 0 -or $wno -gt 0x4000) {
            $script:fatal="Implausible device layout in this build. Nothing was changed."
            return $false }

        $scanClock.Stop()
        Log ("signature scan finished in {0} ms over {1} bytes of .text, {2} base + {3} refraction + 1 device pattern" -f `
            [int]$scanClock.ElapsedMilliseconds,$peCheck.Text.Length,$SIGS.Count,$HOOK_SIGS.Count)
    }

    $hnd=[HmFix]::OpenProcess(0x1F0FFF,$false,$p.Id)
    if ($hnd -eq [IntPtr]::Zero) {
        try { if ($p.HasExited) { return $false } } catch { return $false }
        $script:fatal="Access denied. Close this tool and start it as administrator."
        return $false }

    if ($MODE_INFO.UsesHook) {
        [UInt32]$shadowPolicy=0
        if (-not [HmFix]::GetProcessMitigationPolicy($hnd,15,[ref]$shadowPolicy,[UIntPtr]::op_Explicit(4))) {
            [HmFix]::CloseHandle($hnd) | Out-Null
            $script:fatal="Windows' hardware shadow-stack state could not be verified. The v1.4 hook was not installed."
            return $false }
        if (($shadowPolicy -band 1) -ne 0) {
            [HmFix]::CloseHandle($hnd) | Out-Null
            $script:fatal="Hardware-enforced stack protection is active for HITMAN. This v1.4 hook is conservatively refused."
            return $false } }

    $script:handle=$hnd; $script:gamePid=$p.Id; $script:process=$p; $script:base=$b
    $script:mode=$mode; $script:sites=$sites; $script:guardSites=$guards; $script:hookDescriptors=$hooks
    $script:devSlot=$slot; $script:wnoOff=$wno
    Log ("attached pid {0}, build {1}, mode {2}, base sites {3}, guards {4}, v1.4 calls {5}" -f $p.Id,$stamp,$mode,$sites.Count,$guards.Count,$hooks.Count)
    Log ("writes: " + ((@($sites | ForEach-Object { "{0}=0x{1:X}" -f $(if($_.Name){$_.Name}else{"site"}),$_.RVA })) -join ", "))
    Log ("guards: " + ((@($guards | ForEach-Object { "{0}=0x{1:X}" -f $(if($_.Name){$_.Name}else{"site"}),$_.RVA })) -join ", "))
    return $true }

# --- device access, mode aware ---------------------------------------------
function Dev-Plausible { param([Int64]$d)
    if ($d -lt 0x10000 -or $d -gt 0x7FFFFFFFFFFF) { return $false }
    try {
        $fb = RB $script:handle ($d+$OFF_FOV) 16
        for ($i=0;$i -lt 4;$i++) {
            $f=[BitConverter]::ToSingle($fb,$i*4)
            if ($f -lt 0.2 -or $f -gt 3.0) { return $false } }
        $a = U8 $script:handle ($d+$OFF_ACTIVE)
        if ($a -gt 1) { return $false }
    } catch { return $false }
    return $true }

# returns 0 = no device yet, -1 = wrong backend, otherwise the device address
function Get-Dev {
    if ($script:mode -eq "verified") {
        $mgr=$script:base+$MANAGER_RVA
        if ((I64 $script:handle $mgr) -ne ($script:base+$MANAGER_VTABLE_RVA)) { return 0L }
        $d=I64 $script:handle ($mgr+$MANAGER_DEVICE_OFFSET)
        if ($d -eq 0) { return 0L }
        $vt = I64 $script:handle $d
        if ($vt -ne ($script:base+$OCULUS_VTABLE_RVA) -and
            $vt -ne ($script:base+$OPENVR_VTABLE_RVA)) { return -1L }
        return $d
    }
    try { $d = I64 $script:handle ($script:base+$script:devSlot) } catch { return 0L }
    if (-not (Dev-Plausible $d)) { return 0L }
    return $d }

# 0 = safely not running, 1 = running, -1 = state could not be proven.
function Get-VRStartState {
    try { $d = Get-Dev } catch { return -1 }
    if ($d -eq -1L) { return -1 }
    if ($d -eq 0L) { return 0 }
    try {
        $active=U8 $script:handle ($d+$OFF_ACTIVE)
        if ($active -eq 0) { return 0 }
        if ($active -eq 1) { return 1 }
        return -1
    } catch { return -1 } }

# Either backend is fine - the device layout is identical, verified on both.
function VR-Runtime-Loaded {
    try {
        # Process.Modules is cached by System.Diagnostics.Process. Refresh is
        # required or a runtime loaded after the first check is never observed.
        $script:process.Refresh()
        foreach ($m in $script:process.Modules) {
            if ($m.ModuleName -like "LibOVRRT*" -or $m.ModuleName -like "openvr_api*") { return $true } } } catch {}
    return $false }

# Check that the VR device geometry block is initialised and that HITMAN's
# patched mask calculation has produced zero. Field of view and scale are used
# only as plausibility gates for "is this device built yet"; v1.6 never writes
# any of these fields.
function Check-RenderValues { param([Int64]$d)
    $result=[pscustomobject]@{ Initialized=$false; Fixed=$false }

    $fb=RB $script:handle ($d+$OFF_FOV) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($fb,$i*4)
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.2 -or $f -gt 3.0) {
            return $result } }

    $sb=RB $script:handle ($d+$OFF_SCALE) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($sb,$i*4)
        # All-zero scale fields mean the device builder has not reached this
        # block yet. The scale itself is left alone - two test sessions with it
        # at HITMAN's own values showed no difference at all.
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.05 -or $f -gt 20.0) {
            return $result } }

    # No plausibility window on the mask any more. v1.6 never writes there, so
    # there is no write to gate - and a value outside the old range would have
    # been reported as "still initialising" when it actually means the patch did
    # not do what we think. Every readable non-zero mask is a failure now.
    $mb=RB $script:handle ($d+$OFF_MASK) 8

    $result.Initialized=$true
    # HITMAN computes these two itself. With the source patched it computes zero,
    # every time, including during every save load. If they are ever non-zero the
    # patch did not take, and the tool says so instead of quietly looking fine.
    $result.Fixed = (Same $mb $MASK_FIX)
    return $result }

function Prepare-HookCave {
    if (-not $MODE_INFO.UsesHook) { return $true }
    if ($script:hookPrepared) { return $true }
    try {
        $cave=Allocate-HookMemory
        if ($cave -eq 0) { throw "the private v1.4 wrapper allocation failed" }
        $dynamic=@()
        foreach ($call in $script:hookDescriptors) {
            if ([Int64]$call.ContinuationRVA -ne ([Int64]$call.RVA+[Int64]$call.Stock.Length)) {
                throw ("{0} call block does not end at its verified continuation" -f $call.Kind) }
            if($call.Kind -ne "Mesh") {
                $originalCallOffset=if($call.Kind -eq "Outer"){13}else{16}
                if ($call.Stock[$originalCallOffset] -ne 0xE8) { throw ("{0} original call opcode is missing" -f $call.Kind) }
                $originalRel=[BitConverter]::ToInt32($call.Stock,$originalCallOffset+1)
                $decodedTarget=[Int64]$call.RVA+$originalCallOffset+5L+$originalRel
                if ($decodedTarget -ne [Int64]$call.TargetRVA) {
                    throw ("{0} target RVA does not match the original direct call" -f $call.Kind) }
            }
            $unitAddress=$cave+[Int64]$call.UnitOffset
            if($call.Kind -eq "Outer"){$wrapper=Build-OuterUnit $unitAddress ($script:base+[Int64]$call.TargetRVA) ([bool]$MODE_INFO.OuterChangesCount)}
            elseif($call.Kind -eq "Mesh"){$wrapper=Build-MeshUnit $unitAddress}
            else{$wrapper=Build-CopyUnit $call $unitAddress ($script:base+[Int64]$call.TargetRVA) ([int]$MODE_INFO.CopyFrom) ([int]$MODE_INFO.CopyTo)}
            $expectedWrapperLength=
                if($call.Kind -eq "Outer"){if([bool]$MODE_INFO.OuterChangesCount){498}else{474}}
                elseif($call.Kind -eq "Mesh"){98}
                else{311}
            if ($wrapper.Length -ne $expectedWrapperLength -or ([Int64]$call.UnitOffset+$wrapper.Length) -gt 0x1000L) {
                throw ("{0} wrapper shape changed unexpectedly" -f $call.Kind) }
            WB $script:handle $unitAddress $wrapper
            $fix=Build-CallPatch $call $cave
            if ([BitConverter]::ToUInt64($fix,8) -ne [UInt64]$unitAddress) {
                throw ("{0} call block does not point at its wrapper" -f $call.Kind) }
            $dynamic += [pscustomobject]@{
                Name=$call.Name; Kind=$call.Kind; RVA=[Int64]$call.RVA
                Stock=[byte[]]$call.Stock; Fix=[byte[]]$fix
                WrapperAddress=$unitAddress; Wrapper=[byte[]]$wrapper }
        }
        if ($dynamic.Count -ne $MODE_INFO.HookKinds.Count) { throw "not every selected pass wrapper was built" }
        $magic=[Text.Encoding]::ASCII.GetBytes("HMFIX-V1.4-W")
        WB $script:handle ($cave+0x1400L) $magic
        [UInt32]$oldProtect=0
        if (-not [HmFix]::VirtualProtectEx($script:handle,[IntPtr]$cave,[UIntPtr]::op_Explicit(0x1000),0x20,[ref]$oldProtect)) {
            throw "could not make the verified hook page executable" }
        if (-not [HmFix]::FlushInstructionCache($script:handle,[IntPtr]$cave,[UIntPtr]::op_Explicit(0x1000))) {
            throw "could not flush the verified hook page" }
        foreach ($site in $dynamic) {
            if (-not (Same (RB $script:handle $site.WrapperAddress $site.Wrapper.Length) $site.Wrapper)) { throw "wrapper readback failed" }
            if ($site.Fix.Length -ne $site.Stock.Length) { throw "invalid dynamic call-block length" } }
        if (-not (Same (RB $script:handle ($cave+0x1400L) $magic.Length) $magic)) { throw "hook ownership marker readback failed" }
        $script:hookCave=$cave; $script:hookSites=$dynamic; $script:hookPrepared=$true
        Log ("v1.4 refraction cave prepared at 0x{0:X}; calls {1}" -f $cave,(($dynamic | ForEach-Object {$_.Kind}) -join ","))
        return $true
    } catch {
        $script:fatal=("The v1.4 refraction hook could not be prepared safely: {0}. Nothing was hooked." -f $_.Exception.Message)
        return $false }
}

function Read-HookTelemetry { param($Site)
    if (-not $script:hookPrepared -or $script:hookCave -eq 0) { return $null }
    $bytes=RB $script:handle ($script:hookCave+0x1000L) 0xA0
    return [pscustomobject]@{
        Kind=$Site.Kind
        Calls=[BitConverter]::ToUInt64($bytes,0x00)
        Changed=[BitConverter]::ToUInt64($bytes,0x08)
        Restored=[BitConverter]::ToUInt64($bytes,0x10)
        BadCount=[BitConverter]::ToUInt64($bytes,0x18)
        LastOld=[BitConverter]::ToUInt32($bytes,0x20)
        MaxTop=[BitConverter]::ToUInt32($bytes,0x24)
        BadState=[BitConverter]::ToUInt64($bytes,0x28)
        Active=[BitConverter]::ToUInt64($bytes,0x30)
        OwnerTid=[BitConverter]::ToUInt64($bytes,0x38)
        OwnerCtx=[BitConverter]::ToUInt64($bytes,0x40)
        OwnerAcquired=[BitConverter]::ToUInt64($bytes,0x48)
        OwnerReleased=[BitConverter]::ToUInt64($bytes,0x50)
        MeshOverrides=[BitConverter]::ToUInt64($bytes,0x58)
        CopyACalls=[BitConverter]::ToUInt64($bytes,0x60)
        CopyAChanged=[BitConverter]::ToUInt64($bytes,0x68)
        CopyARestored=[BitConverter]::ToUInt64($bytes,0x70)
        CopyAActive=[BitConverter]::ToUInt64($bytes,0x78)
        CopyBCalls=[BitConverter]::ToUInt64($bytes,0x80)
        CopyBChanged=[BitConverter]::ToUInt64($bytes,0x88)
        CopyBRestored=[BitConverter]::ToUInt64($bytes,0x90)
        CopyBActive=[BitConverter]::ToUInt64($bytes,0x98) }
}

function Read-AllHookTelemetry {
    if (-not $script:hookPrepared -or $script:hookCave -eq 0) { return $null }
    $bytes=RB $script:handle ($script:hookCave+0x1000L) 0xA0
    return [pscustomobject]@{
        Calls=[BitConverter]::ToUInt64($bytes,0x00); Changed=[BitConverter]::ToUInt64($bytes,0x08)
        Restored=[BitConverter]::ToUInt64($bytes,0x10); BadCount=[BitConverter]::ToUInt64($bytes,0x18)
        LastOld=[BitConverter]::ToUInt32($bytes,0x20); MaxTop=[BitConverter]::ToUInt32($bytes,0x24)
        BadState=[BitConverter]::ToUInt64($bytes,0x28); Active=[BitConverter]::ToUInt64($bytes,0x30)
        OwnerTid=[BitConverter]::ToUInt64($bytes,0x38); OwnerCtx=[BitConverter]::ToUInt64($bytes,0x40)
        OwnerAcquired=[BitConverter]::ToUInt64($bytes,0x48); OwnerReleased=[BitConverter]::ToUInt64($bytes,0x50)
        MeshOverrides=[BitConverter]::ToUInt64($bytes,0x58)
        CopyACalls=[BitConverter]::ToUInt64($bytes,0x60); CopyAChanged=[BitConverter]::ToUInt64($bytes,0x68)
        CopyARestored=[BitConverter]::ToUInt64($bytes,0x70); CopyAActive=[BitConverter]::ToUInt64($bytes,0x78)
        CopyBCalls=[BitConverter]::ToUInt64($bytes,0x80); CopyBChanged=[BitConverter]::ToUInt64($bytes,0x88)
        CopyBRestored=[BitConverter]::ToUInt64($bytes,0x90); CopyBActive=[BitConverter]::ToUInt64($bytes,0x98) }
}

function Get-HookTelemetryState {
    # Readiness and coverage are two different questions, and conflating them is
    # what left the dot amber forever on at least one machine:
    #   Ready        the refraction fix has been proven on at least one copy path
    #                that this renderer session actually uses
    #   FullCoverage both known CopyRefractionDepth call sites were exercised
    # A path that never ran is not a fault. It is simply not observed, and the
    # existing validation still catches it if it later runs and misbehaves.
    $result=[pscustomobject]@{
        Ready=(-not $MODE_INFO.UsesHook)
        FullCoverage=(-not $MODE_INFO.UsesHook)
        CopyAObserved=$false
        CopyBObserved=$false
        Coverage=""
        Error=""
        Summary="" }
    if (-not $MODE_INFO.UsesHook) { return $result }
    $parts=@(); $now=Get-Date
    try {
        $checkIntegrity=(($now-$script:lastHookIntegrityCheck).TotalSeconds -ge 2)
        foreach ($site in $script:hookSites) {
            if ($checkIntegrity) {
                if (-not (Same (RB $script:handle ($script:base+$site.RVA) $site.Fix.Length) $site.Fix)) {
                    throw ("{0} call block no longer matches the installed v1.4 fix" -f $site.Kind) }
                if (-not (Same (RB $script:handle $site.WrapperAddress $site.Wrapper.Length) $site.Wrapper)) {
                    throw ("{0} wrapper code no longer matches its verified image" -f $site.Kind) } }
        }
        $t=Read-AllHookTelemetry
        if ($null -eq $t) { throw "hook telemetry is unavailable" }
        if ($t.BadCount -ne 0 -or $t.BadState -ne 0 -or $t.MaxTop -gt 4) {
            throw ("a wrapper rejected an unexpected owner/count state (badCount={0}, badState={1}, maxTop={2})" -f $t.BadCount,$t.BadState,$t.MaxTop) }
        $stableSample=$null
        if ($t.Active -eq 0 -and $t.CopyAActive -eq 0 -and $t.CopyBActive -eq 0) {
            $second=Read-AllHookTelemetry
            if($null -ne $second -and $second.Active -eq 0 -and $second.CopyAActive -eq 0 -and $second.CopyBActive -eq 0 -and
               $second.Calls -eq $t.Calls -and $second.Changed -eq $t.Changed -and $second.Restored -eq $t.Restored -and
               $second.CopyACalls -eq $t.CopyACalls -and $second.CopyAChanged -eq $t.CopyAChanged -and $second.CopyARestored -eq $t.CopyARestored -and
               $second.CopyBCalls -eq $t.CopyBCalls -and $second.CopyBChanged -eq $t.CopyBChanged -and $second.CopyBRestored -eq $t.CopyBRestored -and
               $second.OwnerTid -eq $t.OwnerTid -and $second.OwnerCtx -eq $t.OwnerCtx){$stableSample=$second}
        }
        if ($null -ne $stableSample) {
            if($t.OwnerTid -ne 0 -or $t.OwnerCtx -ne 0){throw "the transparent-pass owner marker stayed set"}
            if($t.OwnerAcquired -ne $t.OwnerReleased){throw "transparent-pass owner acquisition was not balanced"}
            if($t.Changed -ne $t.Restored -or $t.CopyAChanged -ne $t.CopyARestored -or $t.CopyBChanged -ne $t.CopyBRestored){throw "a local count change was not restored"}
        }
        # "Observed" is meant literally: one complete 4 -> 2 -> call -> 4 round
        # trip has been seen on that path. Calls alone prove nothing (a call that
        # never took ownership did nothing), and Changed alone only proves the
        # path was entered - Restored is incremented after the original copy call
        # returned and the count was put back. Requiring both closes the one
        # theoretical gap: sampling while the very first copy call is still in
        # flight and calling it verified.
        $ownerProven    = ($t.OwnerAcquired -gt 0)
        $copyAObserved  = ($t.CopyAChanged -gt 0 -and $t.CopyARestored -gt 0)
        $copyBObserved  = ($t.CopyBChanged -gt 0 -and $t.CopyBRestored -gt 0)
        $fullCoverage   = ($copyAObserved -and $copyBObserved)

        # Readiness is the OUTER pass, and only that. The refraction wrapper is
        # installed and demonstrably owning the transparent pass - that is the
        # thing that had to be proven. CopyA and CopyB are optional sub-paths of
        # it: a scene simply may not need a refraction-depth copy. Measured in a
        # real session, the outer pass ran cleanly for ninety seconds before
        # either copy path was called once, and the picture was correct the whole
        # time. Coverage is what the log records; it is not a gate.
        $allReady       = $ownerProven

        $result.CopyAObserved=$copyAObserved
        $result.CopyBObserved=$copyBObserved
        $result.FullCoverage=$fullCoverage
        # Four independent statements rather than a multi-line if-expression.
        # This file has already shipped one bug caused by clever block syntax.
        $coverage = "no copy path observed"
        if ($copyAObserved -and $copyBObserved) { $coverage = "CopyA + CopyB verified" }
        if ($copyAObserved -and -not $copyBObserved) { $coverage = "CopyA verified; CopyB not observed" }
        if ($copyBObserved -and -not $copyAObserved) { $coverage = "CopyB verified; CopyA not observed" }
        $result.Coverage = $coverage
        foreach($unitName in @("Outer","CopyA","CopyB")){
            $isActive=if($unitName -eq "Outer"){$t.Active}elseif($unitName -eq "CopyA"){$t.CopyAActive}else{$t.CopyBActive}
            $progressValue=if($unitName -eq "Outer"){$t.Calls+$t.Restored}elseif($unitName -eq "CopyA"){$t.CopyACalls+$t.CopyARestored}else{$t.CopyBCalls+$t.CopyBRestored}
            $progress=$script:hookProgress[$unitName]
            if($isActive -eq 0){$script:hookProgress.Remove($unitName)|Out-Null}
            elseif($null -eq $progress -or $progress.Value -ne $progressValue){$script:hookProgress[$unitName]=[pscustomobject]@{Value=$progressValue;Since=$now}}
            elseif(($now-$progress.Since).TotalSeconds -ge 10){throw ("{0} wrapper stayed active without progress for ten seconds" -f $unitName)}
        }
        $parts += ("outer calls={0}, owner={1}/{2}, changed={3}/{4}, mesh4={5}, copyA={6}/{7}/{8}, copyB={9}/{10}/{11}, active={12}/{13}/{14}" -f $t.Calls,$t.OwnerAcquired,$t.OwnerReleased,$t.Changed,$t.Restored,$t.MeshOverrides,$t.CopyACalls,$t.CopyAChanged,$t.CopyARestored,$t.CopyBCalls,$t.CopyBChanged,$t.CopyBRestored,$t.Active,$t.CopyAActive,$t.CopyBActive)
        $parts += ("coverage: {0}" -f $result.Coverage)
        if ($checkIntegrity) {
            foreach($s in $script:sites){if(-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)){throw ("base fix changed at RVA 0x{0:X}" -f $s.RVA)}}
            foreach($g in $script:guardSites){if(-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)){throw ("stock guard changed at RVA 0x{0:X}" -f $g.RVA)}}
            $magic=[Text.Encoding]::ASCII.GetBytes("HMFIX-V1.4-W")
            if (-not (Same (RB $script:handle ($script:hookCave+0x1400L) $magic.Length) $magic)) {
                throw "the v1.4 wrapper ownership marker changed" }
            $script:lastHookIntegrityCheck=$now }
        $result.Ready=$allReady; $result.Summary=($parts -join "; ")
        if (((Get-Date)-$script:lastHookLog).TotalSeconds -ge 5) {
            Log ("pass telemetry: " + $result.Summary)
            $script:lastHookLog=Get-Date }
    } catch { $result.Error=$_.Exception.Message }
    return $result
}

function Apply-Code {
    foreach ($g in $script:guardSites) {
        $cur = RB $script:handle ($script:base+$g.RVA) $g.Stock.Length
        if (-not (Same $cur $g.Stock)) {
            $script:fatal="A guarded renderer site is not in its original state. Close HITMAN and every fix window, then start v1.6 again."
            return $false } }

    $allFix=$true; $allStock=$true
    foreach ($s in $script:sites) {
        $cur = RB $script:handle ($script:base+$s.RVA) $s.Fix.Length
        if (-not (Same $cur $s.Fix))   { $allFix=$false }
        if (-not (Same $cur $s.Stock)) { $allStock=$false } }
    if ($allFix) {
        $script:fatal="HITMAN was already patched before this tool attached. Close every fix window and HITMAN, then start this tool again."
        return $false }
    if (-not $allStock) {
        $script:fatal="The game code is not in its original state. Close HITMAN, start it again, then this tool."
        return $false }

    $vrStartState=Get-VRStartState
    if ($vrStartState -lt 0) {
        $script:fatal="The pre-VR renderer state could not be proven safely. Close HITMAN and retry; nothing was changed."
        return $false }
    if ($vrStartState -eq 1) {
        $script:fatal="VR was already running when this tool attached. Close HITMAN, start this tool first, then the game."
        return $false }

    if ($MODE_INFO.UsesHook) {
        foreach ($call in $script:hookDescriptors) {
            if (-not (Same (RB $script:handle ($script:base+$call.RVA) $call.Stock.Length) $call.Stock)) {
                $script:fatal="A v1.4 refraction call is not in its original state. Close HITMAN and every fix window, then start v1.6 again."
                return $false } }
        if (-not (Prepare-HookCave)) { return $false } }

    $held=@()
    try { $held=@(Suspend-GameThreads) }
    catch {
        $script:fatal=("The game could not be paused safely for the atomic patch transaction: {0}. Nothing was changed." -f $_.Exception.Message)
        return $false }

    # Multi-instruction call blocks must never be replaced while a suspended
    # thread is parked anywhere inside them.  The same conservative check is
    # applied to the small v1.3 sites.  On a busy frame we simply resume and
    # retry on a later timer tick without writing a byte.
    try {
        $ranges=@()
        foreach ($s in @($script:sites)+@($script:hookSites)) {
            $start=[UInt64]($script:base+[Int64]$s.RVA)
            $ranges += [pscustomobject]@{ Start=$start; End=[UInt64]($start+[UInt64]$s.Stock.Length) } }
        foreach ($s in @($script:hookSites)) {
            $start=[UInt64]$s.WrapperAddress
            $ranges += [pscustomobject]@{ Start=$start; End=[UInt64]($start+[UInt64]$s.Wrapper.Length) } }
        $telemetry=Read-AllHookTelemetry
        if ($null -eq $telemetry -or $telemetry.Active -ne 0 -or $telemetry.CopyAActive -ne 0 -or $telemetry.CopyBActive -ne 0 -or
            $telemetry.Calls -ne 0 -or $telemetry.OwnerTid -ne 0 -or $telemetry.OwnerCtx -ne 0 -or
            $telemetry.CopyACalls -ne 0 -or $telemetry.CopyBCalls -ne 0 -or $telemetry.MeshOverrides -ne 0) {
            throw "the fresh v1.4 wrapper data page did not have a clean zero state" }
        $rangesClear=Threads-AreOutsidePatchRanges $held $ranges
    }
    catch {
        $resumeOk=Resume-GameThreads $held; $held=@()
        $script:fatal=("The patch was not installed because thread positions could not be verified safely: {0}. Nothing was changed." -f $_.Exception.Message)
        if (-not $resumeOk) { $script:fatal += " One or more game threads could not be resumed; close HITMAN." }
        return $false }
    if (-not $rangesClear) {
        $resumeOk=Resume-GameThreads $held; $held=@()
        if (-not $resumeOk) {
            $script:fatal="A game thread could not be resumed after a deferred patch attempt. Close HITMAN; nothing was written."
            return $false }
        if (((Get-Date)-$script:lastPatchBusyLog).TotalSeconds -ge 2) {
            Log "patch transaction deferred because a render thread was inside a target instruction block"
            $script:lastPatchBusyLog=Get-Date }
        Start-Sleep -Milliseconds 50
        return $false }

    $written=@(); $hookWritten=@(); $applyOk=$false; $rollbackOk=$true; $failure=""
    try {
        # Recheck every precondition while all target threads are stopped.
        $suspendedVrState=Get-VRStartState
        if ($suspendedVrState -ne 0) {
            if ($suspendedVrState -eq 1) { throw "VR became active before the suspended patch transaction" }
            throw "the renderer state became uncertain before the suspended patch transaction" }
        if ($script:mode -eq "verified") {
            foreach ($ctx in $VERIFIED_DIAGNOSTIC_CONTEXTS) {
                if (-not (Same (RB $script:handle ($script:base+$ctx.RVA) $ctx.Bytes.Length) $ctx.Bytes)) {
                    throw ("a loaded verified code context changed at RVA 0x{0:X}" -f $ctx.RVA) } } }
        foreach ($g in $script:guardSites) {
            if (-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)) {
                throw "a guarded renderer site changed before the suspended transaction" } }
        foreach ($s in $script:sites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                throw "a base site changed before the suspended transaction" } }
        foreach ($s in $script:hookSites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                throw "a selected pass call changed before the suspended transaction" } }

        foreach ($s in $script:sites) {
            # Include the site before attempting the write: WriteProcessMemory
            # can modify a prefix and still report a short/failed write.
            $written += $s
            WB $script:handle ($script:base+$s.RVA) $s.Fix }
        foreach ($s in $script:hookSites) {
            $hookWritten += $s
            WB $script:handle ($script:base+$s.RVA) $s.Fix }
        foreach ($s in $script:sites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) {
                throw "verification failed" } }
        foreach ($s in $script:hookSites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) {
                throw "hook verification failed" } }
        foreach ($g in $script:guardSites) {
            if (-not (Same (RB $script:handle ($script:base+$g.RVA) $g.Stock.Length) $g.Stock)) {
                throw "a guarded renderer site changed during patch" } }
        $applyOk=$true
    } catch {
        $failure=$_.Exception.Message
        # Never leave the game with only a subset of this mode's instructions
        # patched.  Roll back every site written by this attempt immediately.
        for ($i=$hookWritten.Count-1;$i -ge 0;$i--) {
            $s=$hookWritten[$i]
            try {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) { $rollbackOk=$false } }
            catch { $rollbackOk=$false } }
        foreach ($s in $written) {
            try {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                    $rollbackOk=$false } }
            catch { $rollbackOk=$false } }
    } finally {
        if (-not $applyOk -and -not $rollbackOk) {
            # A failed rollback can leave a partially rewritten instruction or
            # call block.  Never let a target thread execute that uncertainty.
            # Keep every handle suspended until the user terminates HITMAN;
            # process exit is the only operation that discards this state.
            $script:unsafeCodeState=$true
            $script:suspendedHandles += @($held)
            $held=@()
        } elseif (-not (Resume-GameThreads $held)) {
            $applyOk=$false; $rollbackOk=$false
            if (-not $failure) { $failure="one or more game threads could not be resumed" } } }

    if (-not $applyOk) {
        $script:writtenSites=if($rollbackOk){@()}else{@($written)}
        if ($rollbackOk) {
            $script:fatal=("A patch transaction failed ({0}) and was rolled back. Restart HITMAN before retrying." -f $failure) }
        elseif ($script:unsafeCodeState) {
            $script:fatal=("A patch transaction failed ({0}) and its rollback could not be verified. HITMAN remains deliberately suspended. End HITMAN in Task Manager; do not resume it." -f $failure) }
        else {
            $script:fatal=("A patch transaction failed ({0}) and could not be made safe. Close HITMAN now; every change disappears when the game exits." -f $failure) }
        return $false }
    $script:writtenSites=$written
    $script:patched=$true
    Log ("v1.6.1 code patched, base sites {0}, refraction calls {1}" -f $written.Count,$hookWritten.Count)
    return $true }

# Restore every code block owned by this instance while HITMAN is still live.
# The dynamic CALL blocks can only be rewritten while all game threads are
# suspended, no wrapper is active, and no RIP is inside a block or wrapper.
# The executable cave itself remains allocated until process exit; this avoids
# a stale-instruction or stale-return-address lifetime race.

function Restore {
    if ($script:handle -eq [IntPtr]::Zero) { return $true }
    if (-not (Game-IsAlive)) { return $true }
    if ($script:unsafeCodeState) { return $false }

    try {
        $held=@(); $safeSnapshot=$false
        for ($attempt=0;$attempt -lt 20 -and -not $safeSnapshot;$attempt++) {
            try { $held=@(Suspend-GameThreads) }
            catch { $script:fatal=$_.Exception.Message; return $false }
            try {
                $ranges=@()
                foreach ($s in @($script:writtenSites)+@($script:hookSites)) {
                    $start=[UInt64]($script:base+[Int64]$s.RVA)
                    $ranges += [pscustomobject]@{Start=$start;End=[UInt64]($start+[UInt64]$s.Stock.Length)} }
                foreach ($s in @($script:hookSites)) {
                    $start=[UInt64]$s.WrapperAddress
                    $ranges += [pscustomobject]@{Start=$start;End=[UInt64]($start+[UInt64]$s.Wrapper.Length)} }
                $telemetry=Read-AllHookTelemetry
                $inactive=($null -eq $telemetry -or
                    ($telemetry.Active -eq 0 -and $telemetry.CopyAActive -eq 0 -and $telemetry.CopyBActive -eq 0 -and
                     $telemetry.OwnerTid -eq 0 -and $telemetry.OwnerCtx -eq 0))
                $safeSnapshot=$inactive -and (Threads-AreOutsidePatchRanges $held $ranges)
            } catch {
                Resume-GameThreads $held | Out-Null; $held=@()
                $script:fatal=("Live restoration could not verify game-thread positions: {0}" -f $_.Exception.Message)
                return $false
            }
            if (-not $safeSnapshot) {
                if (-not (Resume-GameThreads $held)) { return $false }
                $held=@(); Start-Sleep -Milliseconds 50 }
        }
        if (-not $safeSnapshot) {
            $script:fatal="The refraction pass stayed busy. Try Turn off again, or close HITMAN. Nothing was restored."
            return $false
        }

        $restoreOrder=@()
        for ($i=$script:hookSites.Count-1;$i -ge 0;$i--) { $restoreOrder += $script:hookSites[$i] }
        $restoreOrder += @($script:writtenSites)
        $restored=@(); $codeOk=$false; $rollbackOk=$true; $failure=""
        try {
            foreach ($s in $restoreOrder) {
                $cur=RB $script:handle ($script:base+$s.RVA) $s.Fix.Length
                if (-not (Same $cur $s.Fix)) {
                    if (Same $cur $s.Stock) { continue }
                    throw ("foreign bytes at RVA 0x{0:X}" -f $s.RVA) }
                $restored += $s
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                    throw ("restore verification failed at RVA 0x{0:X}" -f $s.RVA) }
            }
            $codeOk=$true
        } catch {
            $failure=$_.Exception.Message
            for ($i=$restored.Count-1;$i -ge 0;$i--) {
                $s=$restored[$i]
                try {
                    WB $script:handle ($script:base+$s.RVA) $s.Fix
                    if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) { $rollbackOk=$false } }
                catch { $rollbackOk=$false }
            }
        }

        if (-not $codeOk) {
            if (-not $rollbackOk) {
                $script:unsafeCodeState=$true
                $script:suspendedHandles += @($held); $held=@()
                $script:fatal=("Live restoration failed ({0}) and rollback was not verifiable. HITMAN remains suspended. End it in Task Manager; do not resume it." -f $failure)
            } else {
                Resume-GameThreads $held | Out-Null; $held=@()
                $script:fatal=("Live restoration failed ({0}) and was rolled back safely. Close HITMAN or try again." -f $failure)
            }
            return $false
        }

        $resumeOk=Resume-GameThreads $held; $held=@()
        if (-not $resumeOk) {
            $script:fatal="The fix was restored, but one or more HITMAN threads could not be resumed. Close HITMAN."
            return $false }

        $script:patched=$false; $script:writtenSites=@()
        Log "restored"
        return $true
    } finally {
        if ($held.Count -gt 0 -and -not $script:unsafeCodeState) {
            Resume-GameThreads $held | Out-Null }
    }
}

# --- main loop -------------------------------------------------------------
$timer=New-Object Windows.Forms.Timer
$timer.Interval=15
$timer.Add_Tick({
    try {
        if ($script:stopped) { return }

        if ($script:handle -ne [IntPtr]::Zero) {
            $script:everAttached=$true
            $gameClosed=(-not (Game-IsAlive))
            if ($gameClosed) {
                Log "game closed"; Detach; $script:fatal=""
                if ($ExitWithGame) { Log "closing with the game (-ExitWithGame)"; $form.Close(); return }
                Show-State "grey" "Waiting for HITMAN" "The game was closed. Start it again and v1.6.1 will apply automatically."
                $btnStop.Enabled=$false; return } }

        if ($ExitWithGame -and -not $script:everAttached -and $script:handle -eq [IntPtr]::Zero -and
            (([Diagnostics.Stopwatch]::GetTimestamp()-$script:startedTs)/[Diagnostics.Stopwatch]::Frequency) -gt $AUTO_GIVE_UP_SECONDS) {
            Log "HITMAN did not start within $AUTO_GIVE_UP_SECONDS s of an automatic start; closing"
            $form.Close(); return }

        if ($script:suspendedHandles.Count -gt 0) {
            if ($script:unsafeCodeState) {
                Show-State "red" "End HITMAN in Task Manager" "A failed code rollback could not be verified. HITMAN is deliberately kept suspended so the uncertain instruction can never execute. Force-close the game process; do not resume it."
                return }
            if (Resume-GameThreads @()) { Log "previously suspended game threads were resumed on retry" }
            else {
                Show-State "red" "Close HITMAN" "One or more game threads could not be resumed after three retries. End HITMAN from Task Manager; no further write will be attempted."
                return } }

        if ($script:fatal) { Show-State "red" "Not active" $script:fatal; return }

        if ($script:handle -eq [IntPtr]::Zero) {
            # The 15 ms cadence is for the attached case. Looking for the process
            # that often means enumerating every process on the system 67 times a
            # second, which is where the idle CPU load came from.
            $nowTs=[Diagnostics.Stopwatch]::GetTimestamp()
            if ($script:lastAttachScan -ne 0 -and
                ((($nowTs-$script:lastAttachScan)*1000.0/[Diagnostics.Stopwatch]::Frequency) -lt 500)) { return }
            $script:lastAttachScan=$nowTs
            if (-not (Try-Attach)) { if ($script:fatal) { Show-State "red" "Not active" $script:fatal }; return } }

        $warn=""
        if ($script:mode -eq "scanned") {
            $warn="Untested build - every code pattern was unique, but please check the image carefully." }
        $ready="v1.6.1 is patched. Put on your headset, start VR as usual, then load a mission."

        if (-not $script:patched) {
            if (-not (Apply-Code)) { return }
            $btnStop.Enabled=$true
            Show-State "amber" "Ready - start VR" $ready $warn
            return }

        $hookState=Get-HookTelemetryState
        if ($hookState.Error) {
            $script:fatal=("The pass-local safety monitor detected an unexpected state: {0}. Close HITMAN now; do not continue this run." -f $hookState.Error)
            Show-State "red" "Stop this run" $script:fatal $warn
            return }

        $d = Get-Dev
        if ($d -eq -1L) {
            if ($script:dev -ne 0) { Reset-DeviceState }
            Show-State "red" "Unsupported backend" "The active VR device is neither the Oculus nor the SteamVR one this tool was verified against."
            return }
        if ($d -eq 0L) {
            if ($script:dev -ne 0) {
                Log "VR device became unavailable"
                Reset-DeviceState }
            Show-State "amber" "Ready - start VR" $ready $warn; return }
        if ($d -ne $script:dev) {
            Reset-DeviceState
            $script:dev=$d
            $backend="unknown"
            try {
                $vt=I64 $script:handle $d
                if ($vt -eq ($script:base+$OCULUS_VTABLE_RVA)) { $backend="Oculus" }
                elseif ($vt -eq ($script:base+$OPENVR_VTABLE_RVA)) { $backend="SteamVR/OpenVR" } }
            catch {}
            Log ("VR device found at 0x{0:X}, backend {1}" -f $d,$backend) }

        $active=U8  $script:handle ($d+$OFF_ACTIVE)
        $wno   =U8  $script:handle ($d+$script:wnoOff)
        $trans =U32 $script:handle ($d+$OFF_TRANS)
        $layers=U16 $script:handle ($d+$OFF_LAYERS)
        $tex   =I64 $script:handle ($d+$OFF_TEX)
        $w     =U32 $script:handle ($d+$OFF_W)
        $h     =U32 $script:handle ($d+$OFF_H)

        if ($script:mode -eq "scanned" -and -not $script:runtimeLoaded) {
            $runtimeNow=[Diagnostics.Stopwatch]::GetTimestamp()
            $runtimeAge=if($script:lastRuntimeCheck -eq 0){[double]::PositiveInfinity}else{($runtimeNow-$script:lastRuntimeCheck)*1000.0/[Diagnostics.Stopwatch]::Frequency}
            if ($runtimeAge -ge 500) {
                $script:runtimeLoaded=VR-Runtime-Loaded
                $script:lastRuntimeCheck=$runtimeNow }
        }
        if ($script:mode -eq "scanned" -and -not $script:runtimeLoaded) {
            $script:stableReady=0; $script:stableSince=0L
            $script:lastTrans=-1L
            if ($active -eq 1) {
                Show-State "red" "No VR runtime" "Neither the Oculus nor the SteamVR runtime is loaded in the game." }
            else { Show-State "amber" "Ready - start VR" $ready $warn }
            return }

        if ($active -eq 1 -and $wno -ne 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Not active" "VR started before the patch could take effect. Close HITMAN, start this tool first, then the game."
            return }

        $check=Check-RenderValues $d

        $life=Advance-Lifecycle $script:lastTrans $trans
        if ($life.TransitionChanged) {
            Log ("transition {0} -> {1}" -f $script:lastTrans,$trans) }
        $script:lastTrans=$life.LastTransition
        if ($life.ResetStable) { $script:stableReady=0; $script:stableSince=0L }

        if ($active -ne 1) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Ready - start VR" $ready $warn; return }

        if (-not $check.Initialized) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for the VR renderer" "The device is still initialising." $warn
            return }

        if (-not $check.Fixed) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Mask patch did not take" "HITMAN is still computing a non-zero foveation mask. The patched instruction is not the one this build uses. Close HITMAN and report this." $warn
            return }

        if ($trans -ne 3 -or $layers -ne 2 -or $tex -eq 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for a mission" "VR is running in two-layer mode. Load a mission and the fix becomes active." $warn
            return }

        if (-not $hookState.Ready) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for the scene renderer" "The refraction wrapper is installed but the transparent pass has not run yet. Load a mission." $warn
            return }

        $stableNow=[Diagnostics.Stopwatch]::GetTimestamp()
        if ($script:stableSince -eq 0) { $script:stableSince=$stableNow }
        if ($script:stableReady -lt 3) { $script:stableReady++ }
        $stableMs=($stableNow-$script:stableSince)*1000.0/[Diagnostics.Stopwatch]::Frequency
        if ($script:stableReady -lt 3 -or $stableMs -lt 250) {
            Show-State "amber" "Finishing the mission load" "The render values are correct. Waiting briefly to make sure they remain stable." $warn
        } else {
            Show-State "green" "Active" ("Sharp from edge to edge at {0} x {1} per eye. Glass, water and refraction use the corrected two-eye copy path; no continuous renderer-value writes and nothing to defend." -f $w,$h) $warn }
    } catch {
        Show-State "red" "Something went wrong" ($_.Exception.Message + "  Close HITMAN and try again.") }
})
$timer.Start()

$btnStop.Add_Click({
    if ($script:unsafeCodeState -and (Game-IsAlive)) {
        Show-State "red" "End HITMAN in Task Manager" "The failed rollback remains deliberately suspended. Force-close the HITMAN process; do not resume it." $MODE_INFO.Warning
        return }
    $restored=Restore
    if (-not $restored) {
        if ($script:unsafeCodeState) {
            Show-State "red" "End HITMAN in Task Manager" $script:fatal
        } else {
            Show-State "amber" "Close HITMAN or retry" $script:fatal }
        return }
    Detach
    $script:stopped=$true; $script:fatal=""
    $btnStop.Enabled=$false
    Show-State "grey" "Turned off" "Everything owned by v1.6.1 was restored. Close and reopen this tool to use the fix again." })

$form.Add_FormClosing({ param($sender,$eventArgs)
    if ($script:unsafeCodeState -and (Game-IsAlive)) {
        $eventArgs.Cancel=$true
        Show-State "red" "End HITMAN in Task Manager" "The failed rollback remains deliberately suspended. Force-close the HITMAN process; do not resume it." $MODE_INFO.Warning
        Log "window close deferred while an unsafe rollback state remains suspended"
        return }
    $timer.Stop()
    if ((Game-IsAlive) -and (Changes-MayBeLive) -and -not (Restore)) {
        $eventArgs.Cancel=$true
        $timer.Start()
        if ($script:unsafeCodeState) {
            Show-State "red" "End HITMAN in Task Manager" $script:fatal
        } else {
            Show-State "amber" "Close HITMAN or retry" $script:fatal }
        Log "window close deferred because live restoration was incomplete"
        return }
    Detach
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    if ($script:mutexOwned) {
        try { $script:instanceMutex.ReleaseMutex() } catch {}
        $script:mutexOwned=$false }
    try { $script:instanceMutex.Dispose() } catch {}
    Log "closed" })

[void]$form.ShowDialog()
