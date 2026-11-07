# Read-only profile checks

Requires Windows PowerShell 5.1, Python 3 on PATH, and your own unmodified
HITMAN 3.290.1 executable. No game process is opened or modified.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-VerifiedProfiles.ps1 -ExePath "C:\path\to\HITMAN3.exe"
```

The fixture records the independent PR #23 signature scan on the same executable
fingerprint. It contains only patch metadata, not game files or runtime logs.
The tests check the production profile against this scan and the actual executable,
then exercise production attach/device/detach functions with managed mocks.

Coverage includes exact contexts, patch payloads and hook targets; hash and context
rejection before process access; profile selection; both backend vtables; stale
profile cleanup; and unknown-build fallback routing. Legacy 3.270.1 routing uses a
fixture; these checks do not claim a fresh run against the old executable or replace
testing in a headset.
