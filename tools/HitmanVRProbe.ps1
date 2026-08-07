<#
    HitmanVRProbe  v1.1
    Read-only diagnostic for HitmanVRFoveationFix.

    WHAT THIS IS FOR
      This tool verifies the live patch bytes and reads the renderer lifecycle
      values needed to diagnose Oculus and SteamVR / OpenVR problems. It prints a
      report you can paste into a GitHub issue.

    IT WRITES NOTHING TO HITMAN
      No game patching or process-memory modification. Verify it yourself: the
      only three functions it imports from kernel32 are OpenProcess,
      ReadProcessMemory and CloseHandle. No process-memory write function is
      declared at all, so it could not modify the game even if it tried. The
      Copy and Save buttons only copy or save the displayed report on request.

      The process is opened with access mask 0x0410, which is
      PROCESS_QUERY_INFORMATION together with PROCESS_VM_READ. No write right is
      requested from Windows either.

    HOW TO USE IT
      1. Start HITMAN and get into VR, in a mission
      2. Double-click HitmanVRProbe.bat
      3. Click "Copy report" and paste it into the GitHub issue

    Project page: https://github.com/RealChrizzl/hitman-vr-foveation-fix
    MIT licensed. Made by RealChrizzl.
#>

[CmdletBinding()]
param([string]$ProcessName = "HITMAN3")

$ErrorActionPreference = "Stop"

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
            "This tool needs administrator rights to read the game's memory.`n`nIt does not write anything.",
            "HitmanVRProbe","OK","Warning") | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("HmProbe" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HmProbe {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
'@
}

# PROCESS_QUERY_INFORMATION | PROCESS_VM_READ  - no write access requested
$ACCESS = 0x0410

$VERIFIED_TIMESTAMP = 1781013974

$SIGS = [ordered]@{
  "layer writer A"   = @{ Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00"; Hit=9; Stock=[byte[]](0x0F,0x94,0xC1); Fix=[byte[]](0xB1,0x00,0x90) }
  "layer writer B"   = @{ Pattern="8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00"; Hit=9; Stock=[byte[]](0x0F,0x94,0xC0); Fix=[byte[]](0xB0,0x00,0x90) }
  "field of view A"  = @{ Pattern="C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"; Hit=44; Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00); Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  "field of view B"  = @{ Pattern="50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28 48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14 0F B6 87 1B 03 00 00"; Hit=44; Stock=[byte[]](0x0F,0xB6,0x87,0x1B,0x03,0x00,0x00); Fix=[byte[]](0xB8,0x01,0x00,0x00,0x00,0x90,0x90) }
  "view count"       = @{ Pattern="74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF"; Hit=12; Stock=[byte[]](0x80,0xB8,0x1B,0x03,0x00,0x00,0x00); Fix=[byte[]](0x48,0x85,0xE4,0x90,0x90,0x90,0x90) }
  "device locator"   = @{ Pattern="48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84"; Hit=0 }
}

# shared offsets observed on the Oculus and OpenVR device classes
$FIELDS = [ordered]@{
  "mode          +0x220" = @{ Off=0x220L; Type="u32" }
  "cached mode   +0x30C" = @{ Off=0x30CL; Type="u32" }
  "active        +0x319" = @{ Off=0x319L; Type="u8"  }
  "foveation     +0x31B" = @{ Off=0x31BL; Type="u8"  }
  "wide FovPort  +0x420" = @{ Off=0x420L; Type="f4"  }
  "scales        +0x490" = @{ Off=0x490L; Type="f4"  }
  "mask a        +0x4C0" = @{ Off=0x4C0L; Type="f1"  }
  "mask b        +0x4C4" = @{ Off=0x4C4L; Type="f1"  }
  "transition    +0x4D8" = @{ Off=0x4D8L; Type="u32" }
  "eye width     +0x510" = @{ Off=0x510L; Type="u32" }
  "eye height    +0x514" = @{ Off=0x514L; Type="u32" }
  "layers        +0x520" = @{ Off=0x520L; Type="u16" }
  "texture       +0x530" = @{ Off=0x530L; Type="ptr" }
  "view          +0x538" = @{ Off=0x538L; Type="ptr" }
}

function RB { param([IntPtr]$h,[Int64]$a,[int]$n)
    $b=New-Object byte[] $n; $r=[IntPtr]::Zero
    if (-not [HmProbe]::ReadProcessMemory($h,[IntPtr]$a,$b,$n,[ref]$r) -or $r.ToInt64() -ne $n) { return $null }
    return ,$b }
function Hex { param([byte[]]$B) if ($null -eq $B) { "unreadable" } else { ($B|ForEach-Object{$_.ToString("X2")}) -join " " } }
function Same { param([byte[]]$A,[byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    for ($i=0;$i -lt $A.Length;$i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true }

function Find-Sig { param([byte[]]$hay,[string]$pat)
    $tok=$pat.Split(" "); $n=$tok.Count
    $val=New-Object int[] $n
    for ($i=0;$i -lt $n;$i++) { if ($tok[$i] -eq "??") { $val[$i]=-1 } else { $val[$i]=[Convert]::ToInt32($tok[$i],16) } }
    $a=0; while ($a -lt $n -and $val[$a] -lt 0) { $a++ }
    $first=[byte]$val[$a]; $hits=@(); $limit=$hay.Length-$n
    for ($p=0;$p -le $limit;$p++) {
        if ($hay[$p+$a] -ne $first) { continue }
        $ok=$true
        for ($i=0;$i -lt $n;$i++) { if ($val[$i] -ge 0 -and $hay[$p+$i] -ne $val[$i]) { $ok=$false; break } }
        if ($ok) { $hits+=$p; if ($hits.Count -gt 2) { return $hits } } }
    return $hits }

function Build-Report {
    $L = New-Object Collections.Generic.List[string]
    $L.Add("HitmanVRProbe 1.1 - read-only report")
    $L.Add("generated " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    $L.Add("")

    $procs=@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { $L.Add("HITMAN is not running. Start the game, get into VR and a mission, then press Refresh."); return ($L -join "`r`n") }
    if ($procs.Count -gt 1) { $L.Add("More than one HITMAN process is running - close them all and start the game once."); return ($L -join "`r`n") }
    $p=$procs[0]
    try { $path=$p.MainModule.FileName; $base=$p.MainModule.BaseAddress.ToInt64() }
    catch { $L.Add("Could not read the process module list. Try running as administrator."); return ($L -join "`r`n") }

    # PE header + .text
    $b=[IO.File]::ReadAllBytes($path)
    $pe=[BitConverter]::ToInt32($b,0x3C)
    $stamp=[BitConverter]::ToInt32($b,$pe+8)
    $nsec=[BitConverter]::ToUInt16($b,$pe+6); $opt=[BitConverter]::ToUInt16($b,$pe+20)
    $tRVA=0;$tOff=0;$tSize=0
    for ($i=0;$i -lt $nsec;$i++){
        $o=$pe+24+$opt+$i*40
        if ([Text.Encoding]::ASCII.GetString($b,$o,8).TrimEnd([char]0) -eq ".text") {
            $tSize=[BitConverter]::ToInt32($b,$o+16); $tRVA=[BitConverter]::ToInt32($b,$o+12); $tOff=[BitConverter]::ToInt32($b,$o+20); break } }
    $text=New-Object byte[] $tSize; [Array]::Copy($b,$tOff,$text,0,$tSize)

    $L.Add("game build timestamp : $stamp" + $(if($stamp -eq $VERIFIED_TIMESTAMP){"   (3.270.1, the verified build)"}else{"   (NOT the verified build)"}))
    $L.Add("file                 : " + (Split-Path -Leaf $path))
    $L.Add("")

    # loaded VR runtime modules
    $mods=@()
    try { foreach ($m in $p.Modules) { if ($m.ModuleName -match "LibOVR|openvr|vrclient|VDXR|OpenXR|ovr") { $mods += $m.ModuleName } } } catch {}
    $L.Add("VR modules loaded    : " + $(if($mods.Count){($mods|Sort-Object -Unique) -join ", "}else{"none found"}))
    $L.Add("")

    # patterns
    $L.Add("--- code patterns ---")
    $devRVA=0L; $wnoOff=0L; $patchSites=@()
    foreach ($k in $SIGS.Keys) {
        $h=@(Find-Sig $text $SIGS[$k].Pattern)
        if ($h.Count -eq 1) {
            $rva=$tRVA+$h[0]+$SIGS[$k].Hit
            $L.Add(("{0,-16} : found, 1 hit, RVA 0x{1:X7}" -f $k,$rva))
            if ($null -ne $SIGS[$k].Fix) {
                $patchSites += [pscustomobject]@{ Name=$k; RVA=[int64]$rva; Stock=$SIGS[$k].Stock; Fix=$SIGS[$k].Fix } }
            if ($k -eq "device locator") {
                $rel=[BitConverter]::ToInt32($text,$h[0]+3)
                $devRVA=[int64]($tRVA+$h[0]+7+$rel)
                $wnoOff=[int64][BitConverter]::ToUInt32($text,$h[0]+15)
                $L.Add(("{0,-16}   -> device pointer at RVA 0x{1:X7}, foveation flag at +0x{2:X}" -f "",$devRVA,$wnoOff)) }
        } else {
            $L.Add(("{0,-16} : NOT FOUND ({1} hits)" -f $k,$h.Count)) } }
    $L.Add("")

    # live device
    $hnd=[HmProbe]::OpenProcess($ACCESS,$false,$p.Id)
    if ($hnd -eq [IntPtr]::Zero) { $L.Add("Could not open the process for reading. Run as administrator."); return ($L -join "`r`n") }
    try {
        $L.Add("--- live code ---")
        foreach ($s in $patchSites) {
            $cur=RB $hnd ($base+$s.RVA) $s.Fix.Length
            $status=if ($null -eq $cur) { "unreadable" } elseif (Same $cur $s.Fix) { "fixed" } elseif (Same $cur $s.Stock) { "stock" } else { "other: " + (Hex $cur) }
            $L.Add(("{0,-16} : {1}" -f $s.Name,$status)) }
        $L.Add("")

        $L.Add("--- live device ---")
        if ($devRVA -eq 0) { $L.Add("device pointer could not be located, nothing further to read") }
        else {
            $pb = RB $hnd ($base+$devRVA) 8
            $dev = if ($null -ne $pb) { [BitConverter]::ToInt64($pb,0) } else { 0 }
            if ($dev -eq 0) { $L.Add("device pointer is null - VR is not running yet. Get into VR and a mission, then Refresh.") }
            else {
                $vt = RB $hnd $dev 8
                $L.Add(("device object        : 0x{0:X}" -f $dev))
                if ($null -ne $vt) {
                    $vtRVA=[BitConverter]::ToInt64($vt,0)-$base
                    $L.Add(("device vtable RVA    : 0x{0:X7}   <-- this identifies the backend class" -f $vtRVA)) }
                else { $L.Add("device vtable RVA    : unreadable") }
                $L.Add("")
                foreach ($k in $FIELDS.Keys) {
                    $f=$FIELDS[$k]; $a=$dev+$f.Off
                    switch ($f.Type) {
                        "u8"  { $r=RB $hnd $a 1;  $v=if($null -ne $r){"{0}" -f $r[0]}else{"unreadable"} }
                        "u16" { $r=RB $hnd $a 2;  $v=if($null -ne $r){"{0}" -f [BitConverter]::ToUInt16($r,0)}else{"unreadable"} }
                        "u32" { $r=RB $hnd $a 4;  $v=if($null -ne $r){"{0}" -f [BitConverter]::ToUInt32($r,0)}else{"unreadable"} }
                        "ptr" { $r=RB $hnd $a 8;  $v=if($null -ne $r){"0x{0:X}" -f [BitConverter]::ToInt64($r,0)}else{"unreadable"} }
                        "f1"  { $r=RB $hnd $a 4;  $v=if($null -ne $r){"{0,-12:0.######}  raw {1}" -f [BitConverter]::ToSingle($r,0),(Hex $r)}else{"unreadable"} }
                        "f4"  { $r=RB $hnd $a 16
                                if ($null -ne $r) { $fl=@(); for($i=0;$i -lt 4;$i++){$fl+=("{0:0.######}" -f [BitConverter]::ToSingle($r,$i*4))}
                                          $v=("{0}   raw {1}" -f (($fl -join ", ").PadRight(38)),(Hex $r)) } else { $v="unreadable" } }
                    }
                    $L.Add(("{0,-22} : {1}" -f $k,$v)) } } }
    } finally { [HmProbe]::CloseHandle($hnd) | Out-Null }

    $L.Add("")
    $L.Add("--- end of report ---")
    return ($L -join "`r`n")
}

# --- window ----------------------------------------------------------------
$form=New-Object Windows.Forms.Form
$form.Text="HitmanVRProbe - read-only diagnostic"
$form.ClientSize=New-Object Drawing.Size(760,560)
$form.StartPosition="CenterScreen"
$form.Font=New-Object Drawing.Font("Segoe UI",9)

$hdr=New-Object Windows.Forms.Label
$hdr.Location=New-Object Drawing.Point(14,12); $hdr.Size=New-Object Drawing.Size(732,40)
$hdr.Text="This only reads the running game; Copy/Save affect the report, never game memory. Start HITMAN, enter VR and a mission, then press Refresh."
$form.Controls.Add($hdr)

$box=New-Object Windows.Forms.TextBox
$box.Location=New-Object Drawing.Point(14,58); $box.Size=New-Object Drawing.Size(732,432)
$box.Multiline=$true; $box.ScrollBars="Both"; $box.WordWrap=$false; $box.ReadOnly=$true
$box.Font=New-Object Drawing.Font("Consolas",9)
$form.Controls.Add($box)

$btnR=New-Object Windows.Forms.Button
$btnR.Location=New-Object Drawing.Point(14,502); $btnR.Size=New-Object Drawing.Size(150,34)
$btnR.Text="Refresh"; $form.Controls.Add($btnR)

$btnC=New-Object Windows.Forms.Button
$btnC.Location=New-Object Drawing.Point(174,502); $btnC.Size=New-Object Drawing.Size(190,34)
$btnC.Text="Copy report"; $form.Controls.Add($btnC)

$btnS=New-Object Windows.Forms.Button
$btnS.Location=New-Object Drawing.Point(374,502); $btnS.Size=New-Object Drawing.Size(190,34)
$btnS.Text="Save to file"; $form.Controls.Add($btnS)

$lbl=New-Object Windows.Forms.Label
$lbl.Location=New-Object Drawing.Point(574,510); $lbl.Size=New-Object Drawing.Size(172,20)
$lbl.ForeColor=[Drawing.Color]::FromArgb(0,130,50)
$form.Controls.Add($lbl)

function Refresh-Report {
    $lbl.Text=""
    try { $box.Text = Build-Report } catch { $box.Text = "Failed: " + $_.Exception.Message }
}
$btnR.Add_Click({ Refresh-Report })
$btnC.Add_Click({
    try { [Windows.Forms.Clipboard]::SetText($box.Text); $lbl.Text="copied" } catch { $lbl.Text="copy failed" } })
$btnS.Add_Click({
    try {
        $dir = if ($PSScriptRoot) { $PSScriptRoot } else { [Environment]::GetFolderPath("Desktop") }
        $f = Join-Path $dir "hitman-vr-probe-report.txt"
        [IO.File]::WriteAllText($f,$box.Text)
        $lbl.Text="saved"
        Start-Process explorer.exe "/select,`"$f`""
    } catch { $lbl.Text="save failed" } })

Refresh-Report
[void]$form.ShowDialog()
