# Keeping this working after a game update

The Windows tool has two ways of finding the code it needs.

**On build 3.270.1** it uses fixed RVAs and instruction contexts that were verified by
hand.

**On any other build** it searches the `.text` section for conservative byte patterns.
Addresses move when IO Interactive rebuilds the game; surrounding instruction shapes
often survive. If every required site can still be found uniquely and consistently, the
tool can run in scanned mode. If not, it refuses to write.

This document is for whoever has to update those signatures after a future build.

---

## Base signatures

v1.6 has **eight patched base sites** plus one device-locator signature that is never
patched. The two v1.6 mask sites deliberately share one long signature and use different
hit offsets.

`??` matches any byte. The **hit offset** is the byte offset from the start of the
matched pattern to the instruction being patched.

### 1. WNO writer A — hit offset 9

```text
8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00
```

Patch `0F 94 C1` to:

```text
B1 00 90
```

That is `mov cl,0` + `nop`.

### 2. WNO writer B — hit offset 9

```text
8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00
```

Patch `0F 94 C0` to:

```text
B0 00 90
```

### 3 + 4. Full-field flag, Oculus and OpenVR — hit offset 44, exactly two matches

```text
?? ?? 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28
48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14
0F B6 87 1B 03 00 00
```

Patch the final `movzx` at **both** matches to:

```text
B8 01 00 00 00 90 90
```

The game contains two near-identical copies of this method, one per VR backend
(vtable slot 65 of `ZRenderVRDeviceOculus` and `ZRenderVRDeviceOpenVR`). They
differ only in the first four bytes of the pattern, a device field offset:
 * Oculus: `0x8C0`
 * OpenVR:
   * `0x950` in 3.270.1
   * `0x8E0` in 3.290.1

Earlier versions used two exact patterns, and the four bytes change in OpenVR
broke one of them.

The offset is therefore left as `??`, and this is the one pattern that must
match **exactly twice** instead of once (`Sites=2` in the script). Both matches
get the same patch, so the scanner does not need to know which is Oculus and
which is OpenVR; the four offset bytes are only written to the log as a label.
Any other number of matches refuses the build.

The long prefix matters: the short tail has a near-twin elsewhere.

### 5. Logical view count A — hit offset 12

```text
74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF
```

Patch the `cmpb` to:

```text
48 85 E4 90 90 90 90
```

`test rsp,rsp` clears ZF without changing a general-purpose register, forcing the
following `cmovne` to select four.

### 6. Logical view count B — hit offset 9

```text
49 8B 8D A0 41 01 00 74 1A 80 B9 1B 03 00 00 00 BF 02 00 00
```

Same seven-byte patch as site 5.

Patch one count site without the other and geometry may be fixed while one eye still
keeps the black oval / Instinct smear.

### 7. Mask B source — hit offset 14

### 8. Mask A source — hit offset 22

Both use this **same 66-byte pattern**:

```text
F3 0F 10 41 30 F3 0F 5E 41 18 F3 0F 5E D1 F3 0F 59 C0
41 0F 28 C8 F3 0F 59 D2 F3 0F 11 81 B4 00 00 00
F3 0F 10 41 44 F3 0F 58 C0 F3 0F 11 91 B0 00 00 00
0F 11 99 80 00 00 00 41 0F 28 D8 41 0F 28 D0
```

At hit 14, patch:

```text
F3 0F 59 C0  ->  0F 57 C0 90
```

At hit 22, patch:

```text
F3 0F 59 D2  ->  0F 57 D2 90
```

The signature is intentionally much longer than the arithmetic sequence. `mulss`
changes only the low scalar lane; `xorps` clears the whole XMM register. The context
therefore continues through both stores and the later XMM reloads that make the
full-register clear safe. On an unknown build, do not shorten this to a cute four- or
eight-byte signature just because it still matches.

### 9. VR device locator — not patched

```text
48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84
```

Two values are decoded from the match:

- bytes 3-6: RIP-relative displacement to the VR device pointer;
- bytes 15-18: WNO-field displacement inside the device (`0x31B` on 3.270.1).

---

## v1.4 refraction-hook signatures

The production transparency fix still uses three strong patterns. The direct `E8`
displacements are wildcarded, decoded and range-checked. Both Copy sites must resolve to
the same `CopyRefractionDepth` target.

### Outer owner scope — hit 0, replaced length 18

```text
48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 ?? ?? ?? ??
48 8D 8C 24 60 02 00 00
```

### CopyA — hit 18, replaced length 21

```text
48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28
4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ??
48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D ?? ?? ?? ??
4C 8D 0D ?? ?? ?? ??
```

### CopyB — hit 18, replaced length 21

```text
48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28
4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ??
48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00
4C 8B 40 60 4D 85 C0
```

Do not patch the shared fullscreen helper globally. The outer wrapper establishes the
owner scope only. Each inner wrapper changes the current context count from 4 to 2 only
for its direct call, verifies it, and restores 4 before returning.

---

## Device layout checks in v1.6

The current verified offsets include:

```text
+0x319  active
+0x420  field of view
+0x490  scale block
+0x4C0  mask A
+0x4C4  mask B
+0x4D8  transition
+0x510  width
+0x514  height
+0x520  layers
+0x530  texture
```

Important change from v1.5: **v1.6 does not write Scale or Mask.**

- FOV is a plausibility/initialization gate.
- Scale is a plausibility/initialization gate only.
- Mask is a read-only correctness check and must be exactly zero once initialized.

If a future class-layout change moves these fields, the plausibility checks should fail
rather than authorize a data write, because there is no renderer-field data write left
to perform. The code patches still require their own instruction verification.

---

## Updating after a game patch

Work from what the code does, not from old absolute addresses.

### WNO writers

Find byte stores to the WNO displacement. The two intended writers sit after a compare
of `[reg+0x4D8]` against 1.

### Full-field flag and logical counts

Both read the WNO byte. The count sites feed the 1/2/4 renderer-context view count.
Retain both count sites; v1.5 demonstrated that treating them as duplicates and keeping
only one is wrong.

### Mask source

Find the function that derives the two mask floats from the FOV geometry and stores to
`device+0x4C0/+0x4C4`. Re-prove the full-register lifetime before reusing `xorps` on a
changed build. The later XMM reloads are part of the proof, not signature decoration.

### Refraction calls

Locate the outer transparent/refractive owner call and both direct
`CopyRefractionDepth` calls. Decode the CALL targets and require both Copy sites to
resolve to the same function before constructing wrappers.

---

## Verification after an update

There is no substitute for an HMD test. At minimum verify:

1. **Sharpness** — full field of view has the former centre sharpness in both eyes.
2. **No edge/centre masks** — no one-eye black oval and no centre black circle.
3. **Geometry** — move head and position through busy scenes; no view-count pop-in.
4. **Transparency/refraction** — glass, water, bottles, emissive/light materials and
   large windows remain stereo-correct while turning and leaning.
5. **Save/reload stress** — repeat save loads many times. v1.6 should not need a repair
   interval because the mask is regenerated as zero at the source.
6. **Telemetry** — owner acquisitions/releases and every observed Copy Changed/Restored
   pair remain balanced. A scene is allowed to leave one or both Copy paths unobserved.
7. **Restore** — close the tool while HITMAN is live and verify that it restores only
   owned code when the wrappers are quiescent; unsafe states must fail closed.

If an unknown build scanner match is being changed, also verify uniqueness of every
base signature, both mask hit offsets, both Copy target decodes and every stock guard
context before shipping it.
