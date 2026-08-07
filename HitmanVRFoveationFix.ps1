<#
    HitmanVRFoveationFix  v1.3
    Edge-to-edge sharpness for HITMAN World of Assassination in PC VR.

    WHAT IT DOES
      HITMAN renders VR with foveation: four layers per frame, two wide ones at
      half resolution covering the whole field of view, and two narrow ones at
      full resolution covering only a small circle in the centre. Everything
      outside that circle is upscaled from the half-resolution layer, which is
      why it looks like mush on a high resolution headset.

      This tool switches the game to two layers at full resolution instead,
      covering the whole field of view. That is twice the pixel work - four
      quarter-sized slices against two full-sized ones - but the density is what
      matters: 936 px across the old ~49 degree circle is 19.1 px per degree,
      1872 px across the full 99 degrees is 18.9. About a percent apart. You get
      the old sweet-spot sharpness, everywhere.

    HOW TO USE IT
      1. Start this tool
      2. Start HITMAN - however you like, including straight into VR
      3. Play

    TWO MODES
      On build 3.270.1, the build this was developed and tested on, the tool
      uses fixed, verified addresses - exactly the code path that was tested.

      On any other build it searches for the relevant code by byte pattern.
      Addresses move with every rebuild of the game, the surrounding
      instructions do not. If every pattern is found exactly once the tool
      works and says the build is untested. If anything is ambiguous or
      missing, it refuses and changes nothing.

    SUPPORTED HEADSETS
      Both VR backends the game speaks are supported:

        Oculus  - Quest 2, Quest 3, Quest 3S, Quest Pro, Rift S, via Link or
                  Air Link
        SteamVR - anything that presents itself through OpenVR, including Quest
                  headsets connected with Steam Link or Virtual Desktop

      The device layout turned out to be identical between the two, so the same
      values work for both. The code is not quite identical though: each backend
      has its own device class with its own copy of one function, so that one is
      patched twice, once per class. HITMAN has no OpenXR backend at all, so
      launching through an OpenXR runtime lands on SteamVR anyway.

    WHAT IT TOUCHES
      No game file or setting is modified. The tool writes a small
      foveationfix.log next to itself for diagnostics. All renderer changes are
      made in the memory of the running process and are gone the moment you
      close HITMAN.

      It does write to the memory of a game that has an online connection. That
      is said plainly because you should know it. Use at your own discretion.

    Project page: https://github.com/RealChrizzl/hitman-vr-foveation-fix
    MIT licensed. Made by RealChrizzl.
#>

[CmdletBinding()]
param([string]$ProcessName = "HITMAN3")

$ErrorActionPreference = "Stop"

# Reading another process's memory needs administrator rights. If we do not
# have them, ask Windows for them once and restart ourselves.
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File","`"$self`"")
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

# Two instances can both observe stock code before either writes it, then each
# believe it owns the patch. A named mutex closes that race before any game
# handle is opened.
$script:instanceMutex=New-Object Threading.Mutex($false,"Local\HitmanVRFoveationFix")
$script:mutexOwned=$false
try { $script:mutexOwned=$script:instanceMutex.WaitOne(0,$false) }
catch [Threading.AbandonedMutexException] { $script:mutexOwned=$true }
if (-not $script:mutexOwned) {
    [Windows.Forms.MessageBox]::Show(
        "HitmanVRFoveationFix is already running in this Windows session.",
        "HitmanVRFoveationFix","OK","Information") | Out-Null
    $script:instanceMutex.Dispose()
    exit
}

if (-not ("HmFix" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HmFix {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, UIntPtr size);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
'@
}

# ===========================================================================
#  VERIFIED PATH - build 3.270.1, tested, unchanged from v1.0
# ===========================================================================
$VERIFIED_TIMESTAMP    = 1781013974
$MANAGER_RVA           = 0x03225D20L
$MANAGER_VTABLE_RVA    = 0x01EF5398L
$MANAGER_DEVICE_OFFSET = 0x141A0L
$OCULUS_VTABLE_RVA     = 0x01F016C0L    # ZRenderVRDeviceOculus
$OPENVR_VTABLE_RVA     = 0x01EFE020L    # ZRenderVRDeviceOpenVR - same layout, verified by probe
$VERIFIED_WNO_OFF      = 0x31BL

$VERIFIED_CODE = @(
  [pscustomobject]@{ RVA=0x011D8B9EL
                     Stock=[byte[]](0x0F,0x94,0xC1)
                     Fix  =[byte[]](0xB1,0x00,0x90) }
  [pscustomobject]@{ RVA=0x011D8BC1L
                     Stock=[byte[]](0x0F,0x94,0xC0)
                     Fix  =[byte[]](0xB0,0x00,0x90) }
  [pscustomobject]@{ RVA=0x012C1EACL          # field of view, Oculus device
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  [pscustomobject]@{ RVA=0x012499CCL          # field of view, OpenVR device
                     Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00)
                     Fix  =[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  [pscustomobject]@{ RVA=0x01161FE9L
                     Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00)
                     Fix  =[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
)

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
    [HmFix]::FlushInstructionCache($h,[IntPtr]$a,[UIntPtr]::op_Explicit($b.Length)) | Out-Null }
function U8  { param($h,$a) (RB $h $a 1)[0] }
function U16 { param($h,$a) [BitConverter]::ToUInt16((RB $h $a 2),0) }
function U32 { param($h,$a) [BitConverter]::ToUInt32((RB $h $a 4),0) }
function I64 { param($h,$a) [BitConverter]::ToInt64((RB $h $a 8),0) }
function W2B { param([UInt32[]]$W)
    $o = New-Object byte[] ($W.Length*4)
    for ($i=0;$i -lt $W.Length;$i++){ [Array]::Copy([BitConverter]::GetBytes($W[$i]),0,$o,$i*4,4) }
    return ,$o }
function Log { param($t)
    try { Add-Content -Path $LOG_PATH -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$t) -Encoding UTF8 } catch {} }

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

function Find-Sig { param([byte[]]$hay,[string]$pat)
    $tok=$pat.Split(" "); $n=$tok.Count
    $val=New-Object int[] $n
    for ($i=0;$i -lt $n;$i++) {
        if ($tok[$i] -eq "??") { $val[$i]=-1 } else { $val[$i]=[Convert]::ToInt32($tok[$i],16) } }
    $a=0; while ($a -lt $n -and $val[$a] -lt 0) { $a++ }
    $first=[byte]$val[$a]
    $hits=@(); $limit=$hay.Length-$n
    for ($p=0; $p -le $limit; $p++) {
        if ($hay[$p+$a] -ne $first) { continue }
        $ok=$true
        for ($i=0;$i -lt $n;$i++) {
            if ($val[$i] -ge 0 -and $hay[$p+$i] -ne $val[$i]) { $ok=$false; break } }
        if ($ok) { $hits+=$p; if ($hits.Count -gt 1) { return $hits } } }
    return $hits }

# --- state -----------------------------------------------------------------
$script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
$script:mode=""            # verified | scanned
$script:sites=@()
$script:writtenSites=@()    # only sites this instance owns and may restore
$script:devSlot=0L         # pattern path: RVA of the device pointer
$script:wnoOff=$OFF_ACTIVE
$script:patched=$false
$script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
$script:pendingValueWrite=$false
$script:stableReady=0; $script:stableSince=0L
$script:scaleStock=$null; $script:maskStock=$null
$script:scaleTouched=$false; $script:maskTouched=$false
$script:deviceRestoreUncertain=$false
$script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
$script:lastWriteLog=[DateTime]::MinValue; $script:lastUi=""
$script:fatal=""; $script:stopped=$false

function Reset-DeviceState { param([bool]$OwnershipBecameUncertain=$false)
    if ($OwnershipBecameUncertain -and ($script:scaleTouched -or $script:maskTouched)) {
        $script:deviceRestoreUncertain=$true }
    $script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
    $script:pendingValueWrite=$false
    $script:stableReady=0; $script:stableSince=0L
    $script:scaleStock=$null; $script:maskStock=$null
    $script:scaleTouched=$false; $script:maskTouched=$false
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    $script:lastWriteLog=[DateTime]::MinValue }

function Advance-Lifecycle {
    param([Int64]$LastTransition,[bool]$NeedReload,[UInt32]$Transition,[bool]$ValuesWritten)
    $changed=($LastTransition -ne [Int64]$Transition)
    if ($Transition -ne 3) { $NeedReload=$false }
    elseif ($ValuesWritten) { $NeedReload=$true }
    return [pscustomobject]@{
        LastTransition=[Int64]$Transition
        NeedReload=$NeedReload
        TransitionChanged=$changed
        ResetStable=($changed -or $ValuesWritten) }
}

function Detach {
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    $script:handle=[IntPtr]::Zero; $script:gamePid=0; $script:process=$null; $script:base=0L
    $script:mode=""; $script:sites=@(); $script:writtenSites=@(); $script:devSlot=0L; $script:patched=$false
    $script:dev=0L; $script:lastTrans=-1L; $script:needRel=$false
    $script:pendingValueWrite=$false
    $script:stableReady=0; $script:stableSince=0L
    $script:scaleStock=$null; $script:maskStock=$null
    $script:scaleTouched=$false; $script:maskTouched=$false
    $script:deviceRestoreUncertain=$false
    $script:runtimeLoaded=$false; $script:lastRuntimeCheck=0L
    $script:lastWriteLog=[DateTime]::MinValue; $script:lastUi="" }

function Restore {
    if ($script:handle -eq [IntPtr]::Zero) { return $true }
    $ok=-not $script:deviceRestoreUncertain
    if ($script:dev -ne 0) {
        $deviceCurrent=$false
        try { $deviceCurrent=((Get-Dev) -eq $script:dev) } catch {}
        if (-not $deviceCurrent -and ($script:scaleTouched -or $script:maskTouched)) { $ok=$false }
        if ($deviceCurrent -and $script:scaleTouched) {
            $sb = $script:scaleStock; if ($null -eq $sb) { $sb = W2B $SCALE_STOCK }
            try {
                $cur=RB $script:handle ($script:dev+$OFF_SCALE) 16
                if (Same $cur (W2B $SCALE_FIX)) {
                    if ((Get-Dev) -ne $script:dev) { throw "device changed during restore" }
                    WB $script:handle ($script:dev+$OFF_SCALE) $sb
                    if (-not (Same (RB $script:handle ($script:dev+$OFF_SCALE) 16) $sb)) { $ok=$false } }
                elseif (-not (Same $cur $sb)) { $ok=$false } }
            catch { $ok=$false } }
        if ($deviceCurrent -and $script:maskTouched) {
            $mb = $script:maskStock; if ($null -eq $mb) { $mb = $MASK_STOCK }
            try {
                $cur=RB $script:handle ($script:dev+$OFF_MASK) 8
                if (Same $cur $MASK_FIX) {
                    if ((Get-Dev) -ne $script:dev) { throw "device changed during restore" }
                    WB $script:handle ($script:dev+$OFF_MASK) $mb
                    if (-not (Same (RB $script:handle ($script:dev+$OFF_MASK) 8) $mb)) { $ok=$false } }
                elseif (-not (Same $cur $mb)) { $ok=$false } }
            catch { $ok=$false } } }
    foreach ($s in $script:writtenSites) {
        try {
            $cur=RB $script:handle ($script:base+$s.RVA) $s.Fix.Length
            if (Same $cur $s.Fix) {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) { $ok=$false } }
            elseif (-not (Same $cur $s.Stock)) { $ok=$false } }
        catch { $ok=$false } }
    Log $(if($ok){"restored"}else{"restore incomplete - close HITMAN"})
    return $ok }

# --- window ----------------------------------------------------------------
$form=New-Object Windows.Forms.Form
$form.Text="HitmanVRFoveationFix"
$form.ClientSize=New-Object Drawing.Size(520,318)
$form.FormBorderStyle="FixedSingle"; $form.MaximizeBox=$false
$form.StartPosition="CenterScreen"
$form.Font=New-Object Drawing.Font("Segoe UI",9)

$title=New-Object Windows.Forms.Label
$title.Location=New-Object Drawing.Point(20,18); $title.Size=New-Object Drawing.Size(480,28)
$title.Text="Edge-to-edge sharpness for HITMAN in VR"
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
$steps.Text="Leave this window open while you play. No game file is changed - closing HITMAN undoes the renderer changes."
$form.Controls.Add($steps)

$btnStop=New-Object Windows.Forms.Button
$btnStop.Location=New-Object Drawing.Point(22,252); $btnStop.Size=New-Object Drawing.Size(200,36)
$btnStop.Text="Turn off"; $btnStop.Enabled=$false
$form.Controls.Add($btnStop)

$link=New-Object Windows.Forms.LinkLabel
$link.Location=New-Object Drawing.Point(240,260); $link.Size=New-Object Drawing.Size(260,22)
$link.Text="v1.3 by RealChrizzl - project page"
$link.LinkArea=New-Object Windows.Forms.LinkArea(22,12)
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
    $state.Text=$head; $detail.Text=$body; $note.Text=$warn }

Show-State "grey" "Waiting for HITMAN" "Start the game whenever you like - including straight into VR. This tool does the rest."

# --- attach ----------------------------------------------------------------
function Try-Attach {
    $procs=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $false }
    if ($procs.Count -gt 1) { $script:fatal="More than one HITMAN process is running. Close them all and start the game once."; return $false }
    $p=$procs[0]
    try { $path=$p.MainModule.FileName; $b=$p.MainModule.BaseAddress.ToInt64() } catch { return $false }

    $fs=[IO.File]::OpenRead($path)
    try { $br=New-Object IO.BinaryReader($fs); $fs.Position=0x3C; $pe=$br.ReadInt32(); $fs.Position=$pe+8; $stamp=$br.ReadInt32() }
    finally { $fs.Dispose() }

    $sites=@(); $mode=""; $slot=0L; $wno=0x31BL
    if ($stamp -eq $VERIFIED_TIMESTAMP) {
        $mode="verified"
        foreach ($c in $VERIFIED_CODE) {
            $sites += [pscustomobject]@{ RVA=$c.RVA; Stock=$c.Stock; Fix=$c.Fix } }
        $wno=$VERIFIED_WNO_OFF
    } else {
        $mode="scanned"
        try { $pe2 = Read-PE $path } catch { $script:fatal="Could not read the game executable."; return $false }
        foreach ($s in $SIGS) {
            $h=@(Find-Sig $pe2.Text $s.Pattern)
            if ($h.Count -ne 1) {
                $script:fatal="The code for '" + $s.What + "' could not be located uniquely in this build. Nothing was changed. Please report this build on the project page."
                return $false }
            $stock=New-Object byte[] $s.Fix.Length
            [Array]::Copy($pe2.Text,$h[0]+$s.Hit,$stock,0,$stock.Length)
            $sites += [pscustomobject]@{ RVA=[int64]($pe2.TextRVA+$h[0]+$s.Hit); Stock=$stock; Fix=$s.Fix } }
        $h=@(Find-Sig $pe2.Text $SIG_DEVICE_PAT)
        if ($h.Count -ne 1) { $script:fatal="The VR device reference could not be located uniquely in this build. Nothing was changed."; return $false }
        $at=$h[0]
        $rel=[BitConverter]::ToInt32($pe2.Text,$at+$SIG_DEVICE_REL)
        $slot=[int64]($pe2.TextRVA+$at+7+$rel)
        $wno =[int64][BitConverter]::ToUInt32($pe2.Text,$at+$SIG_DEVICE_DSP)
        if ($wno -le 0 -or $wno -gt 0x4000) { $script:fatal="Implausible device layout in this build. Nothing was changed."; return $false }
    }

    $hnd=[HmFix]::OpenProcess(0x1F0FFF,$false,$p.Id)
    if ($hnd -eq [IntPtr]::Zero) { $script:fatal="Access denied. Close this tool and start it as administrator."; return $false }

    $script:handle=$hnd; $script:gamePid=$p.Id; $script:process=$p; $script:base=$b
    $script:mode=$mode; $script:sites=$sites; $script:devSlot=$slot; $script:wnoOff=$wno
    Log ("attached pid {0}, build {1}, mode {2}" -f $p.Id,$stamp,$mode)
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

# only true when we are CONFIDENT VR is already up; uncertainty means patch
function VR-Running {
    $d = Get-Dev
    if ($d -le 0) { return $false }
    try { return ((U8 $script:handle ($d+$OFF_ACTIVE)) -eq 1) } catch { return $false } }

# Either backend is fine - the device layout is identical, verified on both.
function VR-Runtime-Loaded {
    try {
        # Process.Modules is cached by System.Diagnostics.Process. Refresh is
        # required or a runtime loaded after the first check is never observed.
        $script:process.Refresh()
        foreach ($m in $script:process.Modules) {
            if ($m.ModuleName -like "LibOVRRT*" -or $m.ModuleName -like "openvr_api*") { return $true } } } catch {}
    return $false }

# Read and neutralise the device values as soon as its geometry block is valid.
# In particular this runs before +0x319 becomes active.  OpenVR rebuilds the
# shader/constant-buffer state during mission and save-game loads; changing these
# fields only after that rebuild leaves the old centre mask cached on the GPU.
function Sync-RenderValues { param([Int64]$d)
    $result=[pscustomobject]@{ Initialized=$false; Fixed=$false; Wrote=$false; Error="" }

    $fb=RB $script:handle ($d+$OFF_FOV) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($fb,$i*4)
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.2 -or $f -gt 3.0) {
            return $result } }

    $sb=RB $script:handle ($d+$OFF_SCALE) 16
    for ($i=0;$i -lt 4;$i++) {
        $f=[BitConverter]::ToSingle($sb,$i*4)
        # All-zero scale fields mean the device builder has not reached this
        # block yet.  Do not capture or overwrite partially constructed data.
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt 0.05 -or $f -gt 20.0) {
            return $result } }

    $mb=RB $script:handle ($d+$OFF_MASK) 8
    for ($i=0;$i -lt 2;$i++) {
        $f=[BitConverter]::ToSingle($mb,$i*4)
        if ([Single]::IsNaN($f) -or [Single]::IsInfinity($f) -or $f -lt -0.01 -or $f -gt 4.0) {
            return $result } }

    $result.Initialized=$true
    $scaleFixBytes=W2B $SCALE_FIX
    $sOk=Same $sb $scaleFixBytes
    $mOk=Same $mb $MASK_FIX

    if (-not $sOk) {
        $wasTouched=$script:scaleTouched
        if (-not $wasTouched) { $script:scaleStock=$sb }
        # Claim ownership before the call. WriteProcessMemory may modify a prefix
        # (or even all bytes) and still report failure/a short write.
        $script:scaleTouched=$true; $result.Wrote=$true
        try { WB $script:handle ($d+$OFF_SCALE) $scaleFixBytes } catch {}
        try { $after=RB $script:handle ($d+$OFF_SCALE) 16 }
        catch {
            $script:deviceRestoreUncertain=$true
            $result.Error="Scale write could not be verified. Close HITMAN if this repeats."
            return $result }
        if (-not (Same $after $scaleFixBytes)) {
            $rolledBack=Same $after $sb
            if (-not $rolledBack) {
                try {
                    WB $script:handle ($d+$OFF_SCALE) $sb
                    $rolledBack=Same (RB $script:handle ($d+$OFF_SCALE) 16) $sb }
                catch { $rolledBack=$false } }
            if ($rolledBack -and -not $wasTouched) {
                $script:scaleTouched=$false; $script:scaleStock=$null }
            if (-not $rolledBack) { $script:deviceRestoreUncertain=$true }
            $result.Error=if($rolledBack){"Scale write failed and was rolled back; retrying."}else{"Scale write left an unknown value. Close HITMAN."}
            return $result } }
    if (-not $mOk) {
        $wasTouched=$script:maskTouched
        if (-not $wasTouched) { $script:maskStock=$mb }
        $script:maskTouched=$true; $result.Wrote=$true
        try { WB $script:handle ($d+$OFF_MASK) $MASK_FIX } catch {}
        try { $after=RB $script:handle ($d+$OFF_MASK) 8 }
        catch {
            $script:deviceRestoreUncertain=$true
            $result.Error="Mask write could not be verified. Close HITMAN if this repeats."
            return $result }
        if (-not (Same $after $MASK_FIX)) {
            $rolledBack=Same $after $mb
            if (-not $rolledBack) {
                try {
                    WB $script:handle ($d+$OFF_MASK) $mb
                    $rolledBack=Same (RB $script:handle ($d+$OFF_MASK) 8) $mb }
                catch { $rolledBack=$false } }
            if ($rolledBack -and -not $wasTouched) {
                $script:maskTouched=$false; $script:maskStock=$null }
            if (-not $rolledBack) { $script:deviceRestoreUncertain=$true }
            $result.Error=if($rolledBack){"Mask write failed and was rolled back; retrying."}else{"Mask write left an unknown value. Close HITMAN."}
            return $result } }

    # A failed or immediately overwritten value must not result in a green
    # status.  A later tick retries it during the same loading transition.
    try {
        $result.Fixed = (Same (RB $script:handle ($d+$OFF_SCALE) 16) $scaleFixBytes) -and
                        (Same (RB $script:handle ($d+$OFF_MASK) 8) $MASK_FIX) }
    catch {
        # Preserve Wrote=true so a write made after transition 3 still latches
        # the required reload even when this final verification read is lost.
        $result.Error="Render values were written but the final verification read failed; retrying."
        return $result }
    return $result }

function Apply-Code {
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

    if (VR-Running) {
        $script:fatal="VR was already running when this tool attached. Close HITMAN, start this tool first, then the game."
        return $false }

    $written=@()
    try {
        foreach ($s in $script:sites) {
            # Include the site before attempting the write: WriteProcessMemory
            # can modify a prefix and still report a short/failed write.
            $written += $s
            WB $script:handle ($script:base+$s.RVA) $s.Fix }
        Start-Sleep -Milliseconds 60
        foreach ($s in $script:sites) {
            if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Fix.Length) $s.Fix)) {
                throw "verification failed" } }
    } catch {
        # Never leave the game with only a subset of the five instructions
        # patched.  Roll back every site written by this attempt immediately.
        $rollbackOk=$true
        foreach ($s in $written) {
            try {
                WB $script:handle ($script:base+$s.RVA) $s.Stock
                if (-not (Same (RB $script:handle ($script:base+$s.RVA) $s.Stock.Length) $s.Stock)) {
                    $rollbackOk=$false } }
            catch { $rollbackOk=$false } }
        $script:writtenSites=@()
        if ($rollbackOk) {
            $script:fatal="A patch did not stick. The partial change was rolled back; please restart HITMAN." }
        else {
            $script:fatal="A patch failed and could not be rolled back safely. Close HITMAN now; all changes disappear when the game exits." }
        return $false }
    $script:writtenSites=$written
    $script:patched=$true; Log "code patched"
    return $true }

# --- main loop -------------------------------------------------------------
$timer=New-Object Windows.Forms.Timer
$timer.Interval=15
$timer.Add_Tick({
    try {
        if ($script:stopped) { return }

        if ($script:handle -ne [IntPtr]::Zero) {
            $gameClosed=$false
            try { $gameClosed=($null -eq $script:process -or $script:process.HasExited) } catch { $gameClosed=$true }
            if ($gameClosed) {
                Log "game closed"; Detach; $script:fatal=""
                Show-State "grey" "Waiting for HITMAN" "The game was closed. Start it again and this tool will patch it once more."
                $btnStop.Enabled=$false; return } }

        if ($script:fatal) { Show-State "red" "Not active" $script:fatal; return }

        if ($script:handle -eq [IntPtr]::Zero) {
            if (-not (Try-Attach)) { if ($script:fatal) { Show-State "red" "Not active" $script:fatal }; return } }

        $warn=""
        if ($script:mode -eq "scanned") {
            $warn="Untested build - the code was located by pattern. Please check the image looks right." }
        $ready="The game is patched. Put on your headset and start VR as usual, then load a mission."

        if (-not $script:patched) {
            if (-not (Apply-Code)) { return }
            $btnStop.Enabled=$true
            Show-State "amber" "Ready - start VR" $ready $warn
            return }

        $d = Get-Dev
        if ($d -eq -1L) {
            if ($script:dev -ne 0) { Reset-DeviceState $true }
            Show-State "red" "Unsupported backend" "The active VR device is neither the Oculus nor the SteamVR one this tool was verified against."
            return }
        if ($d -eq 0L) {
            if ($script:dev -ne 0) {
                Log "VR device became unavailable"
                Reset-DeviceState $true }
            Show-State "amber" "Ready - start VR" $ready $warn; return }
        if ($d -ne $script:dev) {
            if ($script:dev -ne 0) { Reset-DeviceState $true } else { Reset-DeviceState }
            $script:dev=$d
            Log ("VR device found at 0x{0:X}" -f $d) }

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
            $script:lastTrans=-1L; $script:needRel=$false
            if ($active -eq 1) {
                Show-State "red" "No VR runtime" "Neither the Oculus nor the SteamVR runtime is loaded in the game." }
            else { Show-State "amber" "Ready - start VR" $ready $warn }
            return }

        if ($active -eq 1 -and $wno -ne 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Not active" "VR started before the patch could take effect. Close HITMAN, start this tool first, then the game."
            return }

        $sync=Sync-RenderValues $d
        if ($sync.Wrote) {
            $script:pendingValueWrite=$true
            # Close the read/write race: classify the write using a fresh state
            # sample. The renderer may have reached transition 3 while the two
            # value groups were being written.
            $active=U8  $script:handle ($d+$OFF_ACTIVE)
            $wno   =U8  $script:handle ($d+$script:wnoOff)
            $trans =U32 $script:handle ($d+$OFF_TRANS)
            $layers=U16 $script:handle ($d+$OFF_LAYERS)
            $tex   =I64 $script:handle ($d+$OFF_TEX)
            $w     =U32 $script:handle ($d+$OFF_W)
            $h     =U32 $script:handle ($d+$OFF_H) }

        if ($active -eq 1 -and $wno -ne 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Not active" "VR started before the patch could take effect. Close HITMAN, start this tool first, then the game."
            return }

        $life=Advance-Lifecycle $script:lastTrans $script:needRel $trans $script:pendingValueWrite
        if ($life.TransitionChanged) {
            Log ("transition {0} -> {1}" -f $script:lastTrans,$trans) }
        $script:lastTrans=$life.LastTransition
        $script:needRel=$life.NeedReload
        $script:pendingValueWrite=$false
        if ($life.ResetStable) { $script:stableReady=0; $script:stableSince=0L }

        if ($sync.Wrote) {
            $now=Get-Date
            if (($now-$script:lastWriteLog).TotalSeconds -ge 1) {
                Log ("values synchronised, transition={0}, active={1}" -f $trans,$active)
                $script:lastWriteLog=$now } }

        if ($sync.Error) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "red" "Renderer write failed" $sync.Error $warn
            return }

        if ($active -ne 1) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Ready - start VR" $ready $warn; return }

        if (-not $sync.Initialized -or -not $sync.Fixed) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for the VR renderer" "The device is still initialising. The fix will arm before its render state is built." $warn
            return }

        if ($trans -ne 3 -or $layers -ne 2 -or $tex -eq 0) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Waiting for a mission" "VR is running in two-layer mode. Load a mission and the fix becomes active." $warn
            return }

        if ($script:needRel) {
            $script:stableReady=0; $script:stableSince=0L
            Show-State "amber" "Reload this mission once" "The fix is set, but this mission was already running when it was applied. Reload it once and the image will be sharp everywhere." $warn
        } else {
            $stableNow=[Diagnostics.Stopwatch]::GetTimestamp()
            if ($script:stableSince -eq 0) { $script:stableSince=$stableNow }
            if ($script:stableReady -lt 3) { $script:stableReady++ }
            $stableMs=($stableNow-$script:stableSince)*1000.0/[Diagnostics.Stopwatch]::Frequency
            if ($script:stableReady -lt 3 -or $stableMs -lt 250) {
                Show-State "amber" "Finishing the mission load" "The render values are correct. Waiting briefly to make sure they remain stable." $warn
            } else {
                Show-State "green" "Active" ("Sharp from edge to edge. Rendering {0} x {1} per eye in two layers instead of four." -f $w,$h) $warn } }
    } catch {
        Show-State "red" "Something went wrong" ($_.Exception.Message + "  Close HITMAN and try again.") }
})
$timer.Start()

$btnStop.Add_Click({
    $restored=Restore; Detach
    $script:stopped=$true; $script:fatal=""
    $btnStop.Enabled=$false
    if ($restored) {
        Show-State "grey" "Turned off" "Everything this tool changed was restored. Close and reopen it to use the fix again." }
    else {
        Show-State "amber" "Close HITMAN" "A live value could not be restored safely. Closing the game always discards every in-memory change." } })

$form.Add_FormClosing({
    $timer.Stop(); Restore | Out-Null
    if ($script:handle -ne [IntPtr]::Zero) { [HmFix]::CloseHandle($script:handle) | Out-Null }
    if ($script:mutexOwned) {
        try { $script:instanceMutex.ReleaseMutex() } catch {}
        $script:mutexOwned=$false }
    try { $script:instanceMutex.Dispose() } catch {}
    Log "closed" })

[void]$form.ShowDialog()
