# How it works

Everything below refers to HITMAN 3 / World of Assassination build **3.270.1**,
Windows, D3D11. Both VR backends the game has are covered: Oculus (LibOVR) and
SteamVR (OpenVR). It has no OpenXR backend at all.

---

## 1. What the game does

HITMAN's VR renderer uses **fixed foveation**, called *Wide/Narrow Overlay* (WNO) in
the code. A single `Texture2DArray` holds four slices:

| Slice | Role | Size | Covers |
|---|---|---|---|
| 0, 1 | wide, one per eye | provider ÷ 2 | the whole field of view |
| 2, 3 | narrow, one per eye | provider ÷ 2 | a small circle in the centre |

Both pairs are rendered at the same pixel count, but the narrow pair spends it on a
much smaller angle — so inside the circle you get roughly full resolution, and outside
it you get half, upscaled.

A pixel shader composites the two. The circle's radius comes from a geometry block at
`device+0x430`; the blend ring runs from `r0 = r1 − blend` to `r1`, where `r1` is half
the smaller of the two field-of-view spans.

The circle is **fixed to the centre of the image**. There is no gaze input anywhere in
the block — this is not eye-tracked foveated rendering, and a headset with eye
tracking gains nothing here.

**The consequence:** on a Fresnel headset the lens blurs the periphery anyway and the
software blur hides in it. On a pancake headset the lens is sharp to the edge, so the
software blur is the only thing left — and it is very visible.

---

## 2. What the fix does

Switch the renderer to **two slices at full resolution**, covering the whole field of
view. Five instructions and three values.

Note on cost, since this is easy to get wrong: it is **twice** the pixel work, not
the same. Each slice doubles in both dimensions while the slice count halves — four
quarters against two wholes. What stays equal is the *density*: 936 px across the old
~49° narrow zone is 19.1 px/°, and 1872 px across the full 99° is 18.9 px/°. About a
percent apart. The old sweet-spot sharpness, everywhere.

### Before VR initialises

| Address | Original | Patched | Effect |
|---|---|---|---|
| `0x011D8B9E` | `0F 94 C1` | `B1 00 90` | WNO flag writer A → 0 |
| `0x011D8BC1` | `0F 94 C0` | `B0 00 90` | WNO flag writer B → 0 |
| `0x012C1EAC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | constant-buffer flag = 1, raises the shader's radius limit so the image fills the field of view instead of leaving a black border — **Oculus device** |
| `0x012499CC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | the same thing again for the **OpenVR device** |
| `0x01161FE9` | `80 B8 1B 03 00 00 00` | `48 85 E4 90 90 90 90` | **view count 4** — see below |

`48 85 E4` is `test %rsp,%rsp`. It clears the zero flag without touching any register,
so the `cmovne` that follows always fires.

The last two are the same method in two different classes. Both device classes
carry it at vtable slot `+0x208`:

```
ZRenderVRDeviceOculus  vtable RVA 0x1F016C0  +0x208 -> 0x12C1CB0  (0x12C1EAC)
ZRenderVRDeviceOpenVR  vtable RVA 0x1EFE020  +0x208 -> 0x12497D0  (0x12499CC)
```

Patch only one and the other backend keeps its narrow field of view. Everything
else — the device layout, the field offsets, the other three patches — is shared
between them, which was confirmed by comparing probe reports from both runtimes on
the same machine.

### While VR and a mission initialise

| Field | Value | Effect |
|---|---|---|
| `device+0x490 … +0x49C` | `1.0` ×4 | small/large scale ratios neutralised |
| `device+0x4C0` | `0` | overlay pass off — removes the ghost images |
| `device+0x4C4` | `0` | removes the black circle in the centre |

OpenVR rebuilds the render state during mission, scene, and save-game loads. These
fields must therefore be neutralised before that state reaches transition 3, not
merely after a new texture pointer appears. v1.3 watches the transition at 15 ms,
writes as soon as the device geometry is plausible (including before `active=1`),
reads the values back, and requires multiple samples plus a 250 ms monotonic stable
window before showing green. A write first observed after transition 3 remains amber
and asks for one real reload.

This lifecycle has been visually verified in the headset across new missions,
mission restarts, save-game loads, scene changes and Freelancer mode. Polling is
still not the same as synchronising with the render thread; if a future game build
reintroduces a fast-load race, the next step is to re-derive and patch the scale/mask
producer or constant-buffer builder from that build's binary.

Stock values for reference: `+0x490…` = `3EDF2BF0 3ECE8B44 4012D426 401EA625`,
`+0x4C0/+0x4C4` = `3D 2D 66 3F  DA B9 4D 3E`.

---

## 3. The interesting one: the view count

Turning off WNO gets you two full-resolution layers immediately. It also breaks the
game: geometry disappears and reappears as you move — a car's front wheel, a door, a
person's torso, a whole building façade. Not at the edges; anywhere, including dead
centre.

The cause is a single value:

```
0x1161FC9  mov    $0x2,%r15d          ; 2
0x1161FD6  lea    0x2(%r15),%edi      ; 4
0x1161FDA  lea    -0x3(%rdi),%ebx     ; 1
0x1161FDF  mov    0x141A0(%r13),%rax  ; VR device
0x1161FE6  mov    %r15d,%ecx          ; default 2
0x1161FE9  cmpb   $0, 0x31B(%rax)     ; WNO flag
0x1161FF0  cmovne %edi,%ecx           ; WNO on -> 4
0x1161FF5  mov    %ebx,%ecx           ; no VR   -> 1
0x1162015  incl   0x14(%rdx)          ; stack counter
0x116201B  mov    %ecx,(%rdx,%rax,4)  ; push the count
```

A **count**, pushed onto a stack in the render context: 1 without VR, 2 with WNO off,
4 with WNO on. Whatever consumes it does not cope with 2. Force it to 4 and the
geometry stays put.

This is safe even though only two views exist, because the central view-matrix
accessor at `0x1306EFC` masks every requested index with `& 1` when WNO is off — a
request for view 2 returns view 0. The fallback was already in the code.

---

## 4. How it was found

Six hypotheses were tested and all six were wrong: the skipped halving of the render
target, the Hi-Z buffer (which turned out to belong to screen-space reflections, not
occlusion culling), the frustum and view matrices, LOD via entity properties, a buffer
size, and a wrong projection scale.

Two things actually worked.

**A precise observation.** "A house façade in the centre of the image, missing at
00:11, back at 00:13 after tilting my head down — and the hillside behind it renders
fine." That one sentence ruled out object size, edge culling, draw-call budgets and
depth-buffer corruption in a single stroke, because a façade is the largest possible
object, it was in the centre, and something further away was still being drawn.

**A backwards sweep.** The WNO flag is read at 26 places. Rather than guess which one
mattered, the game was left running normally in four-layer mode — a state known to be
correct — and individual read sites were forced to take the two-layer branch, one
group at a time. Backwards, because with four views all matrix slots are populated, so
a patch can only make the code read *less*, never something uninitialised.

Four rounds of bisection later, 24 of 25 sites were eliminated and one instruction was
left.

The lesson, for anyone doing this on another game: **observation before hypothesis.**
Measuring which change causes a symptom is slower to set up and enormously faster than
being clever about where the bug ought to be.
