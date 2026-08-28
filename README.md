# HitmanVRFoveationFix

**Edge-to-edge sharpness for HITMAN World of Assassination in PC VR.**

HITMAN's PC VR renderer uses fixed foveation: a small high-resolution area in the centre of the image and lower-resolution coverage around it. On modern pancake-lens headsets, that software blur remains visible far into the periphery.

HitmanVRFoveationFix changes the renderer to use two full-resolution eye layers across the full field of view while preserving the four logical views HITMAN still expects for geometry and visibility.

## What's new in v1.6.1

Windows v1.6.1 keeps the v1.6 renderer fixes unchanged and makes startup on unverified HITMAN builds dramatically faster.

- **Unknown-build signature scanning is now compiled.** The conservative fallback matcher no longer walks tens of megabytes byte-by-byte in PowerShell. On the Issue #15 reporter's unverified build, the full 28,325,888-byte `.text` scan dropped from roughly 12 seconds to 343–366 ms, and 3/3 tests succeeded even when YES-to-VR was pressed as quickly as possible.
- **Unknown builds skip an unnecessary full-executable hash.** SHA-256 verification is still performed for the verified 3.270.1 fixed-address path; scanned builds no longer pay for a hash that was not used to trust them.
- **Safety rules are unchanged.** Every required pattern must still resolve uniquely, refraction targets are still cross-checked, and unknown builds still fail closed on ambiguity or if VR is already active.
- **Clearer startup status.** Unverified builds show `Scanning this HITMAN build` while signatures are located and write the scan duration to `foveationfix.log`.

The underlying v1.6 renderer changes remain unchanged:

- **Save/reload black circles fixed at the source.** HITMAN's own mask calculation is patched so the two foveation-mask values are generated as zero every time the renderer rebuilds, including save-game loads.
- **The polling renderer guard is gone.** v1.6 no longer writes Scale/Mask values into the VR device and no longer needs the ~1 ms worker thread, high-resolution timer, renderer-value ownership state or reload-recovery latch used by v1.5.
- **Lower background CPU use.** While attached, the normal validation/lifecycle loop remains; while idle, process scanning is throttled to 500 ms. In testing the script generally sat at 0% CPU with only brief peaks around 0.4%.
- **Status no longer depends on optional refraction paths.** The outer refraction pass is the readiness proof. CopyA/CopyB are still validated and tracked, but an unused path is reported as "not observed" diagnostic coverage rather than keeping the status amber forever.

The v1.5 second view-count fix and the v1.4 transparency/refraction fix are preserved unchanged.

## Compatibility

| Platform | Status |
|---|---|
| Windows / Oculus (LibOVR) | v1.6.1, supported |
| Windows / SteamVR (OpenVR) | v1.6.1, supported |
| Linux / Proton / SteamVR | Experimental v1.6.2 port (based on Windows v1.6.1) |
| Standalone Quest | Not supported |

The Windows implementation is verified against HITMAN World of Assassination build **3.270.1**. Other builds use conservative byte-pattern matching and fail closed if the required code cannot be located uniquely.

The v1.6 renderer changes were tested locally with Oculus Link, Air Link and SteamVR, including repeated mission/save reloads. The original v1.5 save/reload black-circle reproducer was also retested externally on the verified SteamVR/OpenVR build with repeated reloads and did not reproduce on v1.6. For v1.6.1, the Issue #15 reporter validated the optimized unknown-build path in three fast YES-to-VR runs; all three succeeded, with measured scan times of 343 ms and 366 ms in the supplied logs.

The improvement is most visible on pancake-lens headsets such as Quest 3 and Quest Pro, but the fix also works with Fresnel headsets.

## Comparison

Both examples below are crops from the outer part of the view at original resolution.

![Before and after, left side of the view](https://raw.githubusercontent.com/RealChrizzl/hitman-vr-foveation-fix/main/screenshots/comparison-left.png)

![Before and after, right side of the view](https://raw.githubusercontent.com/RealChrizzl/hitman-vr-foveation-fix/main/screenshots/comparison-right.png)

## Windows installation

1. Download the latest release ZIP.
2. Extract `HitmanVRFoveationFix.ps1` and `HitmanVRFoveationFix.bat` into the same folder.
3. Double-click **`HitmanVRFoveationFix.bat`** and accept the administrator prompt.
4. Start HITMAN normally, including directly into VR.
5. Leave the fix window open while playing.

Status colours:

- **Grey** — waiting for HITMAN
- **Amber** — VR or the mission is still initializing
- **Green** — fix active
- **Red** — the tool stopped because a validation or patch-integrity check failed

The tool writes `foveationfix.log` next to the script. If you report a problem, attach that log.

### Why PowerShell instead of an EXE?

The tool must read and write another process's memory. Packed PowerShell executables frequently trigger antivirus heuristics because the same techniques are also used by malware. The project therefore ships as a plain-text PowerShell script that can be inspected directly.

The `.bat` file only launches `HitmanVRFoveationFix.ps1` with the required privileges.

## Linux / Proton

The experimental Linux/Python port is **v1.6.2**, based on **Windows v1.6.1**. It includes the current transparency/refraction, view-count, source-level mask and unknown-build scan fixes, with Linux-specific process-memory and thread-control handling for Proton.

The old polling renderer guard and direct scale/mask writes have been removed. Linux-specific safety checks include `PTRACE_O_EXITKILL`, strict `SIGTRAP`/RIP validation, wrapper balance checks and stuck-active detection.

The Linux version is now distributed as a single executable Python file, `Linux-HitmanVRFoveationFix.py`, with version details kept inside the script.

Development and testing were carried out by **GREYBE4RD**, with assistance from ChatGPT, on Arch Linux / SwayWM / Wayland, SteamVR and an AMD Radeon RX 9070 XT. Other configurations may vary.

**To run it:**

```bash
chmod +x Linux-HitmanVRFoveationFix.py
./Linux-HitmanVRFoveationFix.py
```

The script requests `sudo` automatically when needed. Leave the terminal open while playing. Press `Ctrl+C` to stop the tool and restore live changes when safe.

## What the Windows fix changes

HITMAN normally renders four foveated layers per frame:

- two wide layers covering the full field of view at lower resolution;
- two narrow high-resolution layers covering the centre.

HitmanVRFoveationFix instead uses **two full-resolution eye layers covering the full field of view**.

HITMAN still expects four logical views in parts of the renderer. The Windows fix therefore keeps the required four-view geometry/visibility behaviour and restricts the refraction-depth copies to the two physical eye views.

v1.6 applies eight small base-code patches:

- two WNO writers are forced off;
- the Oculus and OpenVR field-of-view limits are forced to the full-view path;
- both logical view-count setup sites are forced to four;
- the two instructions that derive the foveation mask are changed so HITMAN itself stores zero for both mask values.

The v1.4 refraction wrappers remain separate from those eight base patches.

### Performance cost

The rendering change roughly doubles the pixel work compared with the original foveated layout. Whether that affects frame rate depends on available GPU headroom.

For the verified setup:

| | Pixels across | Approx. span | Density |
|---|---:|---:|---:|
| Original sharp centre | 936 | ~49° | 19.1 px/° |
| Fixed full view | 1872 | 99° | 18.9 px/° |

The goal is therefore not to increase the original centre density, but to extend approximately that density across the full view.

## Safety and restore behaviour

The tool does **not** modify HITMAN files or settings. All changes are made in the memory of the running game process and disappear when HITMAN exits.

The Windows implementation is deliberately fail-closed:

- expected code must match before it is patched;
- the verified build uses fixed, hand-checked instruction contexts;
- unknown builds must match every required byte pattern uniquely and consistently;
- all code writes are read back and verified;
- the VR device geometry block is checked for plausibility before the tool accepts renderer state as initialized;
- the two mask fields are read-only diagnostics in v1.6: any readable non-zero mask after initialization is treated as a failure rather than silently repaired;
- refraction wrappers keep active/call/restore telemetry and reject unexpected owner/count states;
- live removal suspends game threads and refuses to restore code if a thread is executing inside an owned patch/wrapper region or the wrapper state cannot be proven quiescent.

v1.6 does **not** write the VR device Scale or Mask fields. The old renderer-value guard, its lock and its restore/ownership machinery have been removed.

This still is not a zero-risk tool: it writes code into the memory of a game with online connectivity. Use it at your own discretion.

## Technical documentation

The repository contains additional material for maintenance and reverse engineering:

- [`docs/HOW-IT-WORKS.md`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/docs/HOW-IT-WORKS.md) — renderer architecture and patch rationale
- [`docs/UPDATING.md`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/docs/UPDATING.md) — signatures and update procedure
- [`tools/HitmanVRProbe.ps1`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/tools/HitmanVRProbe.ps1) — read-only diagnostic probe
- [`CHANGELOG-v1.6.1.md`](CHANGELOG-v1.6.1.md) — v1.6.1 unknown-build startup optimization
- [`CHANGELOG-v1.6.md`](CHANGELOG-v1.6.md) — v1.6 renderer changes

Detailed docs, screenshots, diagnostic tools and Linux-port files are intentionally **not** bundled into the Windows v1.6.1 release ZIP.

## Reporting problems

When opening an issue, include:

1. headset and VR runtime;
2. whether the problem occurs on a new mission, mission restart or save-game load;
3. `foveationfix.log`;
4. a fresh probe report from `tools/HitmanVRProbe.bat` if the game was updated or the tool refuses to patch.

## License

MIT. See [`LICENSE`](LICENSE).
