[CmdletBinding()]
param(
    [string]$FixPath = '',
    [Parameter(Mandatory=$true)][string]$ExePath,
    [string]$ScannedReportPath = ''
)
$ErrorActionPreference='Stop'
if (-not $FixPath) { $FixPath=Join-Path $PSScriptRoot '..\HitmanVRFoveationFix.ps1' }
if (-not $ScannedReportPath) { $ScannedReportPath=Join-Path $PSScriptRoot 'fixtures\3.290.1-scanned.json' }
function Assert { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw $Message } }
function Hex { param([byte[]]$Bytes) ($Bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# Parse the script without loading its elevation, GUI or process-access code.
# Profile byte sequences are read as JSON data by Python, never dynamically executed.
$profileJson = & python (Join-Path $PSScriptRoot 'verify_profile_data.py') $FixPath
Assert ($LASTEXITCODE -eq 0) 'Literal profile extraction failed'
$profile=$profileJson | ConvertFrom-Json
$errors=$null; $tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($FixPath,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Production script has syntax errors'
foreach ($name in @('Read-PE','Same','Try-Attach','Get-Dev','Detach')) {
    $fn=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name)
    Assert ($fn.Count -eq 1) ('Function missing: '+$name)
    . ([ScriptBlock]::Create($fn[0].Extent.Text))
}
$pe=Read-PE $ExePath
$hash=(Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash
Assert ($pe.Stamp -eq 1792593790 -and $hash -eq $profile.SHA256) 'Wrong validation executable'
$report=Get-Content -LiteralPath $ScannedReportPath -Raw | ConvertFrom-Json
Assert ($report.Passed -and $report.ExeSHA256 -eq $hash) 'Scanner report belongs to another executable or failed'
foreach ($ctx in $profile.Contexts) {
    $off=[int64]$ctx.RVA-$pe.TextRVA
    Assert ($off -ge 0 -and $off+$ctx.Bytes.Count -le $pe.Text.Length) 'Context outside .text'
    Assert ((Hex $pe.Text[$off..($off+$ctx.Bytes.Count-1)]) -eq (Hex $ctx.Bytes)) ('Context mismatch '+$ctx.RVA)
}
foreach ($site in $profile.Code) {
    $match=@($report.BaseSites | Where-Object { [Convert]::ToInt64($_.RVA,16) -eq $site.RVA })
    Assert ($match.Count -eq 1) 'Verified site does not match scanned RVA'
    Assert ((Hex $site.Stock) -eq $match[0].Stock -and (Hex $site.Fix) -eq $match[0].Replacement) 'Patch payload differs from tested scanner'
    $off=$site.RVA-$pe.TextRVA
    Assert ((Hex $pe.Text[$off..($off+$site.Stock.Count-1)]) -eq (Hex $site.Stock)) 'Stock bytes mismatch'
    Assert (@($profile.Contexts | Where-Object { $_.RVA -le $site.RVA -and $_.RVA+$_.Bytes.Count -ge $site.RVA+$site.Stock.Count }).Count -gt 0) 'Base site lacks a full context'
}
foreach ($hook in $profile.Hooks) {
    $match=@($report.RefractionHooks | Where-Object { $_.Kind -eq $hook.Kind })
    Assert ($match.Count -eq 1 -and [Convert]::ToInt64($match[0].RVA,16) -eq $hook.RVA) 'Hook RVA differs from scanner'
    Assert ([Convert]::ToInt64($match[0].TargetRVA,16) -eq $hook.TargetRVA -and $match[0].Stock -eq (Hex $hook.Stock)) 'Hook payload differs from scanner'
    Assert ($hook.ContinuationRVA -eq $hook.RVA+$hook.Stock.Count) 'Wrong hook continuation'
    $callOffset=if($hook.Kind -eq 'Outer'){13}else{16}
    $stock=[byte[]]$hook.Stock
    Assert ($stock[$callOffset] -eq 0xE8) 'Expected direct CALL'
    Assert ($hook.RVA+$callOffset+5+[BitConverter]::ToInt32($stock,$callOffset+1) -eq $hook.TargetRVA) 'CALL target mismatch'
}
Assert ($profile.ManagerRVA+$profile.ManagerDeviceOffset -eq [Convert]::ToInt64($report.DeviceSlotRVA,16)) 'Manager locator differs from scanner'

# All native operations below use a test-only managed stub: no P/Invoke declarations.
Add-Type -TypeDefinition @'
using System;
public static class HmFix {
    public static int Opens;
    public static IntPtr OpenProcess(uint a, bool i, int p) { Opens++; return new IntPtr(1); }
    public static bool GetProcessMitigationPolicy(IntPtr h, uint p, out uint b, UIntPtr s) { b=0; return true; }
    public static bool CloseHandle(IntPtr h) { return true; }
}
'@
$realPe=$pe; $mockStamp=$pe.Stamp; $mockHash=$hash
$processStub=[pscustomobject]@{ HasExited=$false; Id=123; MainModule=[pscustomobject]@{FileName=$ExePath;BaseAddress=[IntPtr]0x140000000L} }
function Get-Process { param($Name,$ErrorAction) $processStub }
function Read-PE { param($path) [pscustomobject]@{Stamp=$mockStamp; TextRVA=$realPe.TextRVA; Text=$realPe.Text} }
function Get-FileHash { param($LiteralPath,$Algorithm) [pscustomobject]@{Hash=$mockHash} }
function Log { param($Message) }
function Show-State { param($Colour,$Head,$Body) }
function Find-Sig { throw 'TEST_UNKNOWN_FALLBACK' }
$ProcessName='HITMAN3'; $MODE_INFO=[pscustomobject]@{UsesHook=$true}
$VERIFIED_BUILDS=@{}; $VERIFIED_BUILDS[1792593790]=$profile
# A distinct legacy fixture tests routing, not the unavailable old executable bytes.
$legacy=[pscustomobject]@{Version='3.270.1'; SHA256=('A'*64); Code=@();Guards=@();Hooks=@();Contexts=@();WnoOff=0x31B}
$VERIFIED_BUILDS[1781013974]=$legacy
Assert (Try-Attach) 'New verified profile did not attach through managed mocks'
Assert ($script:verifiedProfile.Version -eq '3.290.1' -and $script:sites.Count -eq 8 -and $script:hookDescriptors.Count -eq 3) 'Wrong attached profile/state'
Detach
Assert ($null -eq $script:verifiedProfile -and $script:sites.Count -eq 0 -and $script:mode -eq '') 'Detach retained stale profile'
$opens=[HmFix]::Opens; $mockHash='0'*64
Assert (-not (Try-Attach)) 'Fingerprint mismatch was accepted'
Assert ([HmFix]::Opens -eq $opens -and $script:fatal -like '*different code*') 'Mismatch reached native operations'
$mockHash=$hash
$off=$profile.Contexts[0].RVA-$realPe.TextRVA
$saved=$realPe.Text[$off]; $realPe.Text[$off]=$saved -bxor 1
try { Assert (-not (Try-Attach)) 'Modified context accepted' } finally { $realPe.Text[$off]=$saved }
Assert ([HmFix]::Opens -eq $opens -and $script:fatal -like '*context does not match*') 'Bad context reached native operations'
$mockStamp=1781013974; $mockHash=$legacy.SHA256
Assert (Try-Attach) 'Legacy profile selection failed'
Assert ($script:verifiedProfile.Version -eq '3.270.1') 'New profile leaked into legacy attach'
Detach
$mockStamp=123; $mockHash=$hash
$SIGS=@([pscustomobject]@{Pattern='test';What='test'})
try { Try-Attach | Out-Null; throw 'Unknown build did not scan' } catch { Assert ($_.Exception.Message -eq 'TEST_UNKNOWN_FALLBACK') ('Unknown fallback changed: '+$_.Exception.Message) }

# Exercise production device lookup against separate profile addresses, using mock RAM.
$script:mode='verified'; $script:base=0x140000000L; $script:verifiedProfile=$profile
$manager=$script:base+$profile.ManagerRVA; $device=0x170000000L
$ram=@{}; $ram[$manager]=$script:base+$profile.ManagerVtableRVA
$ram[$manager+$profile.ManagerDeviceOffset]=$device
function I64 { param($Handle,[int64]$Address) if(-not $ram.ContainsKey($Address)){throw 'Unexpected read'}; $ram[$Address] }
foreach ($vtable in @($profile.OculusVtableRVA,$profile.OpenVRVtableRVA)) {
    $ram[$device]=$script:base+$vtable
    Assert ((Get-Dev) -eq $device) 'Backend profile lookup failed'
}
$ram[$device]=0x123456L
Assert ((Get-Dev) -eq -1L) 'Unknown backend accepted'
Detach
'PASS: actual 3.290.1 contexts/payloads, scanner equivalence, fingerprint/context refusal, mocked profile selection/device lookup/detach, unknown fallback; PowerShell '+$PSVersionTable.PSVersion
