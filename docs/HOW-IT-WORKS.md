# How it works

The address examples below refer to HITMAN 3 / World of Assassination build
**3.270.1**, Windows, D3D11. Windows v1.6.2 also has a verified **3.290.1** profile
with its own addresses and full instruction contexts; the renderer changes are the
same. Both VR backends the game has are covered: Oculus (LibOVR) and
SteamVR (OpenVR). HITMAN has no native OpenXR backend.

---

## 1. What the game does

HITMAN's VR renderer uses **fixed foveation**, called *Wide/Narrow Overlay* (WNO) in
the code. A single `Texture2DArray` holds four slices:

| Slice | Role | Size | Covers |
|---|---|---|---|
| 0, 1 | wide, one per eye | provider / 2 | the whole field of view |
| 2, 3 | narrow, one per eye | provider / 2 | a small circle in the centre |

Both pairs are rendered at the same pixel count, but the narrow pair spends it on a
much smaller angle. Inside the centre circle the image is roughly full resolution;
outside it the wide layer is half resolution and upscaled.

The circle is fixed to the centre of the image. No gaze input is involved, so this is
not eye-tracked foveated rendering.

On Fresnel headsets the lens itself hides much of the peripheral loss. On pancake
headsets the optics remain sharp far from the centre, so HITMAN's software blur becomes
very obvious.

---

## 2. What the Windows v1.6 fix does

The target state is **two full-resolution physical eye layers across the full field of
view**, while retaining the four logical views that parts of HITMAN's renderer expect.

v1.6 applies **eight base code patches** before VR rendering begins:

| Address | Original | Patched | Effect |
|---|---|---|---|
| `0x011D8B9E` | `0F 94 C1` | `B1 00 90` | WNO writer A -> 0 |
| `0x011D8BC1` | `0F 94 C0` | `B0 00 90` | WNO writer B -> 0 |
| `0x012C1EAC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | full FOV path, Oculus |
| `0x012499CC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | full FOV path, OpenVR |
| `0x01161FE9` | `80 B8 1B 03 00 00 00` | `48 85 E4 90 90 90 90` | logical view count -> 4 |
| `0x01162E3C` | `80 B9 1B 03 00 00 00` | `48 85 E4 90 90 90 90` | second logical view count -> 4 |
| `0x011CDAC1` | `F3 0F 59 C0` | `0F 57 C0 90` | mask B source -> 0 |
| `0x011CDAC9` | `F3 0F 59 D2` | `0F 57 D2 90` | mask A source -> 0 |

The first six are the established v1.3/v1.5 base fixes. The last two are the v1.6
change that eliminates the save/reload race.

### Pixel cost

The fixed layout does roughly **twice the pixel work** of the original foveated layout:
four quarter-sized slices versus two full-sized slices. What remains approximately equal
is pixel density: 936 px across the old ~49-degree sharp centre is 19.1 px/degree, while
1872 px across the full ~99-degree view is 18.9 px/degree.

---

## 3. The v1.6 mask-source fix

Every Windows version through v1.5 wrote Scale and Mask values into the VR device after
HITMAN created them. That worked most of the time, but it was inherently a race:
HITMAN could rebuild the renderer, consume the stock mask into GPU state, and only then
would the external guard repair RAM.

Real logs showed scheduling gaps far beyond the intended polling interval. Making the
poller still faster could never guarantee ordering.

The useful source function is at `0x11CD890`. At the relevant point `rcx` is
`device+0x410`, so the two stores below land on `device+0x4C4` and `device+0x4C0`:

```text
0x11CDAB3  movss xmm0,[rcx+0x30]
0x11CDAB8  divss xmm0,[rcx+0x18]
0x11CDAC1  mulss xmm0,xmm0
0x11CDAC9  mulss xmm2,xmm2
0x11CDACD  movss [rcx+0xB4],xmm0    ; device+0x4C4, black-centre mask
0x11CDADE  movss [rcx+0xB0],xmm2    ; device+0x4C0, overlay-pass mask
```

v1.6 changes the two scalar multiplies to `xorps` plus a `nop`:

```text
mulss xmm0,xmm0  ->  xorps xmm0,xmm0 ; nop
mulss xmm2,xmm2  ->  xorps xmm2,xmm2 ; nop
```

The result is simple: **HITMAN itself computes and stores zero** every time it rebuilds
that geometry block, including mission loads and save-game reloads. There is no external
value to overwrite and therefore no timing race to defend against.

`xorps` clears the full 128-bit XMM register whereas `mulss` modifies only the low
scalar lane. That difference is safe here because both registers are reloaded shortly
after the stores before any later consumer can depend on their old upper lanes. The
unknown-build scanner deliberately includes those later reloads in the signature rather
than assuming that property from a short arithmetic pattern.

### No Scale writes

The four Scale values at `device+0x490 ... +0x49C` are no longer modified. They were
part of the original external value patch, but isolated testing with HITMAN's stock
values showed no visible difference. v1.6 reads them only as an initialization sanity
check.

### Read-only renderer check

The normal 15 ms UI/lifecycle timer still checks the VR device once attached:

- the FOV block must contain plausible finite values;
- Scale must be finite/plausible so an unbuilt device block is not mistaken for ready;
- both mask floats must be exactly zero.

v1.6 never writes those device fields. A readable non-zero mask is therefore not
"still initializing" and is not silently repaired; it is a real failure signal.

When HITMAN is not attached, process scanning is throttled to 500 ms instead of running
at the attached timer rate.

---

## 4. Why the logical view count stays at four

Turning WNO off immediately gives two full-resolution physical eye layers. It also
breaks geometry if the renderer context is allowed to use a count of two: objects can
pop in and out anywhere in the image.

The first count site is:

```text
0x1161FC9  mov    $0x2,%r15d          ; 2
0x1161FD6  lea    0x2(%r15),%edi      ; 4
0x1161FDF  mov    0x141A0(%r13),%rax  ; VR device
0x1161FE6  mov    %r15d,%ecx          ; default 2
0x1161FE9  cmpb   $0,0x31B(%rax)      ; WNO flag
0x1161FF0  cmovne %edi,%ecx           ; WNO on -> 4
```

The patch replaces the comparison with `test rsp,rsp` plus NOPs. `rsp` cannot be zero,
so the zero flag is cleared without changing a general-purpose register and the
following `cmovne` always selects four.

A second equivalent setup site at `0x1162E3C` must also be patched. v1.3 found only the
first. Leaving the second at two produces the one-eye black oval / Instinct-smear
problem fixed in v1.5.

Four logical views are correct for geometry even though only two physical eyes exist.
The view-matrix accessor maps logical indices 2/3 back to physical eyes 0/1 when WNO is
off.

---

## 5. Why refraction copies temporarily need two

Most of the renderer is happy with four logical views because those extra indices are
mapped back to the two eyes. `CopyRefractionDepth` is different: it consumes the
numeric context count through a fullscreen instance multiplier. Giving it four causes
narrow/foveal data to leak into glass, water, bottles and some emissive/light materials.

v1.4 therefore keeps the outer `DrawRefractiveAndTransparent` pass at four but wraps its
two direct `CopyRefractionDepth` calls:

| Address | Role |
|---|---|
| `0x011B892A` | owner scope around `DrawRefractiveAndTransparent` |
| `0x01290BA2` | CopyA: local 4 -> 2 -> call -> 4 |
| `0x01291386` | CopyB: local 4 -> 2 -> call -> 4 |

The two Copy sites are **not left eye/right eye**. They are two distinct call sites to
the same target function.

The wrappers gate on thread ID, render-context pointer and expected current count. A
Copy path changes the count only while the correct owner scope is active. After the
original call returns, the wrapper verifies that the count still equals two and restores
four before returning.

Telemetry tracks calls, changes, restores and active state independently for Outer,
CopyA and CopyB. Unexpected owner/count state, unbalanced restores or a wrapper that
stays active without progress are errors.

### Readiness versus coverage in v1.6

Earlier status logic required both CopyA and CopyB to have changed at least once before
the window could turn green. Real sessions showed that this is not a correctness
requirement: a scene can run the outer refraction pass for a long time without needing
either copy site, or can use CopyA long before CopyB.

v1.6 separates the concepts:

- **Ready / Active**: the outer owner path has been observed successfully.
- **CopyA observed**: at least one complete CopyA 4 -> 2 -> call -> 4 round trip has
  been seen.
- **CopyB observed**: same for CopyB.
- **FullCoverage**: both copy paths have been observed.

Coverage is logged as diagnostic information and is not an additional green-status
gate. If an unobserved path runs later and misbehaves, all existing safety checks still
apply.

---

## 6. Patch transaction and live restore

The eight base patches and the v1.4 refraction hook are installed as an ownership-aware
transaction. Expected stock bytes are checked before writing, patched bytes are read
back, and unknown builds must pass exact expected pattern-match counts first.

The refraction wrappers live in private executable memory allocated inside HITMAN. For
installation and live removal, game threads are suspended and their instruction
pointers are checked so the tool does not rewrite an owned call block or wrapper while a
thread is executing inside it.

Live removal is allowed only when wrapper activity is quiescent and the bytes still
match what this instance owns. If safe restoration cannot be proven, the tool fails
closed rather than guessing.

The code cave is not freed while HITMAN remains alive.

---

## 7. Unknown-build matching

Windows v1.6.2 selects a verified profile for builds 3.270.1 and 3.290.1 using the
PE timestamp and full executable SHA-256. Each profile supplies fixed RVAs, stock
bytes and full instruction contexts for all eight base sites and three hooks. Other
builds use patterns and fail closed on an unexpected match count or inconsistent
targets. See [UPDATING.md](UPDATING.md) for the 3.290.1 fingerprint.

The combined full-FOV signature requires exactly two matches, one for each backend.
Its first two bytes are wildcarded because the OpenVR field displacement changed
from `0x950` in 3.270.1 to `0x8E0` in 3.290.1; both matches still require the same
full instruction sequence and receive the same seven-byte patch at offset 44.
The matcher detects a third match and refuses the build. This compatibility fix
comes from zlondrej's [PR #23](https://github.com/RealChrizzl/hitman-vr-foveation-fix/pull/23).

The v1.6 mask scanner uses a 66-byte context for both source instructions. It extends
past both stores and through the later XMM reloads; the same unique match yields hit
offset 14 for mask B and hit offset 22 for mask A.

The refraction scanner independently locates Outer, CopyA and CopyB, decodes the direct
CALL targets and requires both Copy sites to resolve to the same `CopyRefractionDepth`
function.

The important rule is the same throughout this project: **prove instruction context,
not just opcode shape**.

---

## 8. How the fix was found

The project was mostly solved by measurement rather than by assuming which renderer
subsystem ought to be responsible.

The geometry fix came from backwards sweeps over WNO-flag readers after several more
obvious hypotheses failed. The second view-count site was found by sweeping remaining
readers after the first count fix solved pop-in but left a one-eye oval.

The v1.6 mask fix came from the same approach. v1.5 logs showed that the external guard
was successfully detecting and repairing rewritten values, yet some users still saw the
black circle after save reloads. That separated **RAM correctness** from **renderer
consumption timing** and pointed upstream to the producer. Patching the calculation
itself removed both the race and the need for the polling architecture.

For maintenance work on future game builds: observation before hypothesis, and source
before increasingly aggressive repair loops.
