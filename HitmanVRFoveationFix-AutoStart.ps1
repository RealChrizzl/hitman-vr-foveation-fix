<#
    HitmanVRFoveationFix - automatic start with the game

    Run once (double-click HitmanVRFoveationFix-AutoStart.bat). It registers a
    scheduled task that starts HitmanVRFoveationFix.ps1 with administrator
    rights on demand, so starting it later needs no UAC prompt. The task has no
    trigger of its own: it only runs when HitmanVRFoveationFix-Steam.bat asks
    for it, which Steam does on every game launch once the launch option is set.

    A task that grants administrator rights without a prompt must not run
    anything a normal program could change. So the task does not run the script
    in this folder. It runs a copy in %ProgramFiles%\HitmanVRFoveationFix, which
    only administrators can modify, and it starts PowerShell with the
    user-controlled inputs removed:
      - cmd /d: no per-user AutoRun command
      - COR_* / APPDOMAIN_MANAGER_*: no profiler or AppDomain manager DLL
        injected into the .NET runtime
      - PSModulePath: system modules only, no module from Documents
      - TEMP/TMP: Add-Type compiles into an admin-only folder, not %TEMP%

    Because of the copy, run this again after updating the fix. Running it
    again while the task exists offers to update or remove it.
#>

$ErrorActionPreference = "Stop"
$TASK_NAME = "HitmanVRFoveationFix"

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden",
            "-File","`"$PSCommandPath`"")
    } catch {}
    exit
}

Add-Type -AssemblyName System.Windows.Forms
function Say { param($text,$icon="Information",$buttons="OK")
    [Windows.Forms.MessageBox]::Show($text,"HitmanVRFoveationFix auto-start",$buttons,$icon) }

$dir = Split-Path -Parent $PSCommandPath
$fix = Join-Path $dir "HitmanVRFoveationFix.ps1"
$wrapper = Join-Path $dir "HitmanVRFoveationFix-Steam.bat"
$launchOption = "`"$wrapper`" %command%"

$installDir = Join-Path $env:ProgramFiles "HitmanVRFoveationFix"
$installedFix = Join-Path $installDir "HitmanVRFoveationFix.ps1"
$installTemp = Join-Path $installDir "temp"
$sys = [Environment]::GetFolderPath("System")
$cmdExe = Join-Path $sys "cmd.exe"
$psExe = Join-Path $sys "WindowsPowerShell\v1.0\powershell.exe"
$psModules = Join-Path $sys "WindowsPowerShell\v1.0\Modules"

function Remove-Install {
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
}

$existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
if ($existing) {
    $answer = Say ("Automatic start is installed.`n`n" +
                   "Yes - update it with the files in this folder`n" +
                   "No - remove it`n" +
                   "Cancel - leave it as it is") "Question" "YesNoCancel"
    if ($answer -eq "Cancel") { exit }
    if ($answer -eq "No") {
        try { Remove-Install }
        catch { Say ("Could not remove automatic start. Close the fix and try again.`n`n" + $_.Exception.Message) "Warning" | Out-Null; exit }
        Say "Automatic start was removed. Also delete the launch option from HITMAN's Steam properties." | Out-Null
        exit
    }
}

foreach ($needed in @($fix,$wrapper)) {
    if (-not (Test-Path -LiteralPath $needed)) {
        Say ("Missing file:`n$needed`n`nKeep all HitmanVRFoveationFix files in the same folder.") "Warning" | Out-Null
        exit
    }
}
foreach ($char in "'",'"','%','&','^') {
    if ($installDir.Contains($char)) {
        Say "The Program Files path contains a character this setup cannot quote safely:`n$installDir" "Warning" | Out-Null
        exit
    }
}

try {
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    New-Item -ItemType Directory -Path $installTemp -Force | Out-Null
    # Do not rely on inherited permissions: owner Administrators, full control
    # for Administrators and SYSTEM only, read/execute for Users.
    & icacls.exe $installDir /setowner "*S-1-5-32-544" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed ($LASTEXITCODE)" }
    & icacls.exe $installDir /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant failed ($LASTEXITCODE)" }
    Copy-Item -LiteralPath $fix -Destination $installedFix -Force
} catch {
    Say ("Could not install to $installDir. Close the fix and try again.`n`n" + $_.Exception.Message) "Warning" | Out-Null
    exit
}

$clearEnv = @("COR_ENABLE_PROFILING","COR_PROFILER","COR_PROFILER_PATH","COR_PROFILER_PATH_32",
              "COR_PROFILER_PATH_64","APPDOMAIN_MANAGER_ASM","APPDOMAIN_MANAGER_TYPE") |
            ForEach-Object { "set $_=&" }
$psCommand = "`$env:PSModulePath='$psModules'; & '$installedFix' -ExitWithGame"
$cmdLine = "/d /c `"" + ($clearEnv -join " ") +
           " set PSModulePath=$psModules& set TEMP=$installTemp& set TMP=$installTemp&" +
           " `"$psExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$psCommand`"`""

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $cmdExe -Argument $cmdLine -WorkingDirectory $installDir
# Interactive: the window must appear on this user's desktop. Highest: memory
# access to HITMAN needs administrator rights, granted here once instead of on
# every launch. The schtasks.exe defaults would refuse to start on battery and
# kill the tool after 72 hours, so the settings are spelled out.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Principal $principal -Settings $settings -Force `
    -Description "Starts HitmanVRFoveationFix when HITMAN is launched through HitmanVRFoveationFix-Steam.bat." | Out-Null

[Windows.Forms.Clipboard]::SetText($launchOption)
Say ("Automatic start is installed.`n`n" +
     "Last step, in Steam: right-click HITMAN World of Assassination > Properties > General > Launch Options, " +
     "and paste (already copied to the clipboard):`n`n$launchOption`n`n" +
     "From then on the fix starts minimized with the game and closes when the game closes.`n`n" +
     "The fix runs from $installDir. Its log is written there. Run this setup again after updating the fix.") | Out-Null
