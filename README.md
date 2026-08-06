# HitmanVRFoveationFix

**Edge-to-edge sharpness for HITMAN World of Assassination in PC VR.**

If everything outside the middle of your view looks like mush, this fixes it.

The effect is most obvious on pancake-lens headsets — **Quest 3 and Quest Pro** —
because their optics are sharp all the way to the edge, so the software blur is the
only thing left blurring the picture. On Fresnel headsets (Quest 2, Quest 3S, Rift S)
it works too, the gain is just smaller because the lenses already soften the
periphery.

PC VR only, not the standalone version. Both of the game's VR backends work:
**Oculus** (Quest via Link or Air Link, Rift S) and **SteamVR** (anything on
OpenVR, including Quest headsets over Steam Link or Virtual Desktop, and Vive,
Index, Bigscreen Beyond and friends).

---

## See the difference

Both crops are from the **outer part of the view**, taken at the same spot, shown at
original resolution. This is what your eyes get whenever you are not staring dead
ahead — which is most of the time.

![Before and after, left side of the view](screenshots/comparison-left.png)

![Before and after, right side of the view](screenshots/comparison-right.png)

Look at the wall texture, the ivy, the paving stones, the dappled shadows — and the
pictograms on the bins. Same scene, same settings, same headset.

---

## Download and run

### Windows

1. Download the two files: `HitmanVRFoveationFix.ps1` and `HitmanVRFoveationFix.bat`
   — keep them in the same folder
3. Double-click **`HitmanVRFoveationFix.bat`** and allow the administrator prompt
4. Start HITMAN however you normally do, including straight into VR
5. Play

That is the whole procedure. Leave the small window open while you play.

The window tells you what is going on: grey while it waits for the game, amber while
VR or a mission is still loading, **green when the fix is active**. If something is
wrong it turns red and says what.

**Why a .bat and not an .exe**

Reading another program's memory is exactly what a debugger does — and also what
malware does. Packed PowerShell executables get flagged by antivirus software as a
category, regardless of what is inside them, so shipping one would mean asking you to
click past a virus warning. A plain script you can read is more honest.

The `.bat` is one line. Open it in Notepad if you like; it does nothing but start the
script next to it.

### Linux 
1. Download the two files: `HitmanVRFoveationFix-linux.py` and `HitmanVRFoveationFix-linux.sh`
   — keep them in the same folder
3. In your terminal make the shell script executable: `chmod +x HitmanVRFoveationFix-linux.sh`
4. Run the shell script: `./HitmanVRFoveationFix-linux.sh`
5. Start HITMAN via SteamVR/Steamlink
6. Play

As above, leave the script running in your terminal of choice while the game is active.

---

## What it actually does

HITMAN renders VR with **fixed foveation**: four layers per frame instead of two.

- Two **wide** layers at half resolution, covering the whole field of view
- Two **narrow** layers at full resolution, covering only a small circle in the centre

Everything outside that circle is upscaled from the half-resolution layer. On a
headset sharp enough to show the difference, the result is a small sharp island in a
sea of mush — and because the circle is fixed to the centre of the image and not to
where you are looking, you spend most of your time looking at the blurry part.

This tool switches the game to **two layers at full resolution**, covering the whole
field of view. There is no wide/narrow split left at all.

It costs **twice the pixel work**: before, four slices at 936 x 1008 each; after,
two at 1872 x 2016. Same total field of view, twice the pixels. In testing the frame
rate held up because the game is not GPU-bound at these resolutions, but that is a
happy accident, not a free lunch.

The number that does hold up is the pixel density:

| | pixels | across | density |
|---|---|---|---|
| old sweet spot | 936 | ~49° | 19.1 px/° |
| now, everywhere | 1872 | 99° | 18.9 px/° |

About one percent apart. You get the old sweet-spot density — you just get it across
the whole view instead of a small circle in the middle.

No resolution setting is changed. You do not need to raise anything.

---

## Is it safe

- **Nothing is written to disk.** No game file is modified, nothing is installed,
  nothing is left behind. Every change is made in the memory of the running process
  and disappears the moment you close HITMAN.
- It refuses to do anything if the game code is not in its original state, if VR is
  already running when it attaches, or if the VR device does not look the way it
  expects.
- Turning it off or closing the window restores everything.

**Said plainly:** it does write to the memory of a game that has an online connection.
That has been fine in testing, but you should know it before you decide. There is no
way to change what the renderer does without touching the renderer.

Verified on build **3.270.1**. On other builds the tool locates the relevant code by
byte pattern and tells you the build is untested — and if anything is ambiguous, it
refuses instead of guessing.

---

## To IO Interactive

If anyone at IOI reads this: you are welcome to take this. No permission needed, no
credit needed, no strings. The whole change is five instructions and three values,
all documented in [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md).

Two full-resolution layers instead of four half-resolution ones costs twice the
pixel work and looks dramatically better on modern headsets — and on hardware that
is not GPU-bound, which is most of it, that cost does not show. It would be a lovely
patch note.

---

## Reporting a problem

If the tool does not go green, or something looks wrong, please
[open an issue](https://github.com/RealChrizzl/hitman-vr-foveation-fix/issues) — and
include **the exact wording the window showed you**. Grey, amber and red all say
something different, and the message alone usually identifies the cause.

For anything beyond that there is a read-only diagnostic in
[`tools/`](tools/). Put `HitmanVRProbe.ps1` and `HitmanVRProbe.bat` in the same
folder, start the game, get into VR and into a mission, double-click the `.bat` and
press **Copy report**.

It imports only `OpenProcess`, `ReadProcessMemory` and `CloseHandle` — no write
function is declared at all, so it cannot modify the game even in principle.

---

## For the curious

- [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md) — how the foveation works, what the
  fix changes, and how it was found
- [`docs/UPDATING.md`](docs/UPDATING.md) — how to re-find everything if a future game
  update breaks the pattern search

You do not need either of these to use the tool.

---

## Credits

Made by **RealChrizzl**.

This is the result of roughly twenty hours of reverse engineering, and it would not
exist without the AI assistants that did the heavy lifting on the disassembly:
**Claude Opus 5** and **Sol 5.6**. I ran the tests, wore the headset and made the
calls about what looked right — that part is not something a model can do for you.

To be bloody honest: without AI I would not be here sharing software.

---

## Licence

MIT — see [`LICENSE`](LICENSE). Do what you like with it, including forking it if I
ever stop maintaining it. That is rather the point.
