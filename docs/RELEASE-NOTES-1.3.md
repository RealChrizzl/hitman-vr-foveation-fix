# HitmanVRFoveationFix v1.3

Version 1.3 fixes the timing-sensitive SteamVR / OpenVR loading behavior that could
leave a bright image, black circles in the center of the view, or make the fix work
only on some game starts.

This release addresses the SteamVR / OpenVR reports in #1, #2, #3 and #4.

## Highlights

- Fixed SteamVR / OpenVR initialization, mission reload and save-game loading.
- Fixed intermittent black circles and overbright rendering caused by stale render
  state.
- Render values are now neutralized as soon as the VR device geometry is ready,
  including before the device becomes active.
- Mission generations are tracked through renderer transitions instead of texture
  pointer changes, which also covers pointer reuse.
- The renderer is checked every 15 ms during initialization and must remain correct
  for a 250 ms stability window before the tool reports **Active**.
- A write that occurs too late is remembered reliably and the tool requests one real
  mission reload instead of showing a false green status.
- Device recreation, transient read failures and partial writes are handled safely.
- Code patching is transactional: incomplete patches are rolled back immediately.
- Restore only touches bytes owned by the current tool instance and refuses unsafe
  restoration when the game state has changed underneath it.
- A named mutex prevents two fix windows from modifying the same game process.

## Probe 1.1

- Fixed zero-valued fields being reported as `unreadable`; a foveation flag of `0`
  is now displayed correctly.
- Added live status for every code patch site: `stock`, `fixed`, `other` or
  `unreadable`.
- Added the SteamVR / OpenVR field-of-view patch site.
- Clarified that the probe never writes to HITMAN; Copy and Save only affect the
  generated report.

## Verified scenarios

The v1.3 lifecycle fix has been visually tested in the headset with:

- a newly loaded mission;
- a mission restart;
- loading a save game;
- changing scenes; and
- Freelancer mode.

The existing Oculus / LibOVR path remains supported. The SteamVR / OpenVR device
layout and live rendering behavior are verified on HITMAN World of Assassination
build 3.270.1.

## Updating from v1.2

1. Close HITMAN and every older HitmanVRFoveationFix window.
2. Replace the old files with the contents of the v1.3 ZIP.
3. Start `HitmanVRFoveationFix.bat` before starting HITMAN.
4. Leave the fix window open while playing.

The tool does not modify game files or settings. Renderer changes remain in the
running process and disappear when HITMAN closes. Version 1.3 writes a small
`foveationfix.log` beside the script for diagnostics.

If a problem returns after a future game update, attach that log and a fresh report
from `tools/HitmanVRProbe.bat` to a GitHub issue.
