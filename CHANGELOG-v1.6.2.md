# Windows v1.6.2

Adds verified HITMAN World of Assassination **3.290.1** support while preserving
the verified **3.270.1** profile and the existing renderer behavior.

- Added a 3.290.1 profile with its executable timestamp, SHA-256, exact addresses,
  stock bytes and full instruction contexts for eight base patches and three
  refraction hooks.
- Integrated zlondrej's [PR #23](https://github.com/RealChrizzl/hitman-vr-foveation-fix/pull/23):
  one full-FOV signature covers Oculus and OpenVR with exactly two required
  matches. The OpenVR field offset changed from `0x950` to `0x8E0`; a third match
  still causes refusal.
- Kept runtime patching, telemetry and restore checks unchanged.

## Validation

- Both Oculus and SteamVR were tested successfully on 3.290.1.
- The maintainer also tested the final v1.6.2 verified profile successfully;
  its log confirms the SHA-256 match, verified-mode attach and balanced
  CopyA/CopyB telemetry.
- Supplied runtime telemetry shows balanced CopyA/CopyB changes and restores and
  a normal game exit.
- Offline validation checked all required sites and instruction contexts against
  the 3.290.1 executable.
- The live startup scan of its 28,682,240-byte `.text` section took 645 ms in
  `foveationfix.log`.

3.290.1 executable fingerprint:

```text
PE timestamp: 1792593790
SHA-256: 0A337C7979A48B1C2D2E4CF7E80A63BF634C527B6BD301DFE46DB8BB7F977B52
```

The experimental **Linux v1.6.2** port is unchanged and remains based on
**Windows v1.6.1**. The new Windows 3.290.1 support has not been tested on Linux.
