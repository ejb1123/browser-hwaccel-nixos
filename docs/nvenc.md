# NVENC encode on NVIDIA

**Status: experimental. Works, incompletely, and knowing which parts are
incomplete is the whole point of this page.**

`nvidia-vaapi-driver` wraps NVDEC. It is a decode driver and has never claimed
otherwise, which means there is no VA-API encode on NVIDIA and therefore no
hardware encode in either browser — WebRTC calls, screen sharing and
`MediaRecorder` all run on the CPU no matter how you configure them.

[`ejb1123/nvidia-vaapi-driver@nvenc-encode`](https://github.com/ejb1123/nvidia-vaapi-driver/tree/nvenc-encode)
adds an encode path via NVENC. Chromium 151 hardware-encodes H.264 through it
today, verified frame by frame.

```nix
hardware.browserHwaccel = {
  enable = true;
  vendor = "nvidia";
  encode = true;
  nvenc.enable = true;
  firefox = {
    forceEnable = true;
    disableRddSandbox = true;
  };
};
```

Enabling this **replaces `nvidia-vaapi-driver` system-wide**, for every VA-API
client, not just browsers.

## What works

| | |
|---|---|
| H.264 encode (baseline / main / high) | ✅ up to 4096×4096 |
| HEVC encode (main / main10) | ✅ up to 8192×8192 |
| Decode, all upstream profiles | ✅ unaffected |
| `ffmpeg -vaapi` | ✅ SSIM 0.9998 vs source |
| Chromium WebCodecs `VideoEncoder` | ✅ pixel-verified output |
| Rate control (CBR / VBR / CQP), bitrate, framerate, GOP | ✅ honoured |
| Non-16-aligned sizes (1080p, 1600×900, 1366×768) | ✅ since `739bd6d` — see below |
| AV1 encode | ❌ absent — correctly, Ampere has no AV1 encoder |

The SSIM number matters more than "it produced a file". A wrong NV12 layout or
swapped chroma planes still yields a structurally valid bitstream that plays as
garbage. 0.9998 says the pixel path is right, not just the syntax.

Verified on an RTX 3080 (GA102), driver 595.91.07, open kernel module,
`NVD_BACKEND=direct`.

### Encode throughput is currently poor

Measured in Chromium 152 via WebCodecs, H.264, 120 frames, RTX 3080:

| Resolution | NVENC fork | software | Intel UHD 630 for comparison |
|---|---|---|---|
| 640×480 | 17.3 ms/frame | 2.8 | 2.0 |
| 1280×720 | 39.5 ms/frame | 6.4 | 4.6 |
| 1920×1080 | 78.4 ms/frame | 12.2 | 8.0 |

That is roughly **6× slower than software** and **8× slower than a 2017 Intel
iGPU**. Cost per megapixel is near-constant (55.8 → 43.0 → 37.9 ms/MPix), which
is the signature of a copy-bound path rather than an encode-bound one — a 3080's
NVENC should do 720p in 2–3 ms/frame.

The cause is the input path below: device → host → device with a CPU repack per
frame. Until that is fixed, 1080p encodes correctly but only at ~13 fps, so this
is not yet usable for real-time 1080p30.

### The 16-alignment bug (fixed)

Worth recording because the symptom pointed nowhere near the cause. Chromium
creates the VA encode context with **16-aligned** dimensions but hands the driver
surfaces at the **real** frame size, so 1920×1080 arrives as a 1080-row buffer for
an encoder built at 1088. `nvencUploadNV12` validated and copied against
`enc->height` and rejected every frame:

```
NVENC: upload too small: 3110400 < 3133440     (1920*1080*3/2 vs 1920*1088*3/2)
```

Every size whose width *or* height was not a multiple of 16 failed — 1920×1080,
1600×900, 1366×768 — while 1920×1088, 1600×896 and 1344×768 worked. Eight extra
rows flipped 1080p from broken to working, which is what identified it as
alignment rather than a size limit.

Fixed by taking the source geometry explicitly, deriving the chroma plane offset
from it (the old offset read past the end of the buffer), and padding the
alignment rows and columns by replicating the last real pixel. Verified by
encoding a known pattern in hardware and decoding it in software: MAE 8.1 at
every size, identical to the 1280×720 case that always worked.

## What does not work

**Packed headers.** The driver advertises `VAConfigAttribEncPackedHeaders`,
which is a promise: Chromium builds its own SPS/PPS and submits them expecting
them to be used. They currently aren't — NVENC emits its own. The resulting
stream is coherent (a NAL scan shows exactly 1 SPS, 1 PPS, 1 IDR, 29 P slices,
no duplicates), but Chromium believes its parameter sets describe the stream and
they don't.

**Reference-frame management.** `enablePTD=1` leaves NVENC owning picture types
and the DPB, so `frame_num`, POC and reference lists sent by the client are
ignored. **This is what blocks WebRTC simulcast and SVC.** VA-API assumes
client-driven reference management; NVENC owns its DPB and exposes only LTR. The
two models do not fully map onto each other, and closing the gap is a design
problem, not a missing function.

**Input path.** Frames go device → host → device. `nvEncRegisterResource` would
remove two copies per frame. Correctness first — but see the throughput table
above: this is now the single biggest problem with the fork, costing roughly 6×
versus software and making 1080p30 real-time encode unreachable.

### What that means in practice

| Use | Verdict |
|---|---|
| WebCodecs / `MediaRecorder` | works |
| Single-layer WebRTC call | works, lightly tested |
| WebRTC with simulcast or SVC (Meet, most SFUs at higher quality) | expect misbehaviour |
| A machine you need to be dependable | not yet |

## Notes from building it

Kept because they generalise, and because each one cost real time.

**Any failure while probing one entrypoint takes down the whole profile.**
Twice, adding *encode* caused H.264 and HEVC **decode** to vanish from
`chrome://gpu` — a symptom that points nowhere near the cause. Once from
`ctx->max_entrypoints` still being 1, so clients sized `entrypoint_list` too
small and discarded the profile whole; once from encode configs falling through
to the decode branch of `nvQuerySurfaceAttributes`. Fail closed narrowly in this
driver.

**`nvPutImage` was a silent no-op upstream.** It returned `VA_STATUS_SUCCESS`
without copying anything. Harmless when surfaces are only ever decoder outputs;
fatal once encode needs a way in.

**Chromium doesn't use `vaPutImage` at all.** It hands the encoder dma-buf backed
surfaces, so the ffmpeg upload path never fires. NV12 dma-bufs don't go through
`importExternalBufferToCuda` either — that's RGB-only — so `arrays[]` is NULL and
`cuMemcpy2D` fails. The pixels live in a CPU mmap with per-plane offsets and
strides. Both sources have to be handled.

**The 10× bitrate bug.** In VA-API, `bits_per_second` is the *peak* rate and
`target_percentage` scales it to the target. Chromium sends 20 Mbps at 10% for a
2 Mbps stream. Using `bits_per_second` directly configured NVENC at 20 Mbps — in
a WebRTC call that's a network flood, not a quality nicety. Only shows up against
a real client; `ffmpeg` never exposed it.

## Roadmap

- [x] Advertise NVENC encode entrypoints
- [x] Encode real frames (`ffmpeg -vaapi`, SSIM-verified)
- [x] Chromium acceptance (WebCodecs, pixel-verified)
- [x] Rate control, framerate, GOP
- [x] Non-16-aligned frame sizes (1080p, 1600×900, 1366×768)
- [ ] **Zero-copy input via `nvEncRegisterResource`** — the throughput blocker
- [ ] Honour client packed headers (`disableSPSPPS` + header insertion)
- [ ] Explicit picture types and reference management — unblocks simulcast
- [ ] Upstream discussion with `elFarto/nvidia-vaapi-driver`

Issues and patches welcome, particularly on the reference-management design —
that's the part where an extra opinion is worth more than extra code.

## Turning it off

Set `nvenc.enable = false` and rebuild. That restores the stock
`nvidia-vaapi-driver`. Set `encode = false` too, or the module will warn you that
you've asked for encode from a driver that has none.
