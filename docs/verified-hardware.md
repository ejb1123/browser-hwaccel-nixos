# Verified hardware

What has actually been observed working by a person, versus what should work in
principle. The distinction is the point of this file — everything below the line
is a guess until someone runs it.

To add yours: run `browser-hwaccel-check` and open an issue with the output and
your config.

## Tested

### Intel UHD 630 + NVIDIA RTX 3080 (hybrid, displays on NVIDIA)

| | |
|---|---|
| OS | NixOS unstable 26.11, kernel 7.1.9-zen1 |
| Session | KDE, Wayland |
| iGPU | Intel UHD 630, CoffeeLake-S GT2 (Gen9.5) `8086:3e98` @ `0000:00:02.0` |
| dGPU | NVIDIA RTX 3080, GA102 `10de:2216` @ `0000:01:00.0`, driver 595.91.07 open |
| Displays | both on the NVIDIA card — the iGPU drives nothing |
| Config | [`examples/hybrid-intel-nvidia.nix`](../examples/hybrid-intel-nvidia.nix) |

**Chromium 151 — confirmed working.** `chrome://gpu` reports *Video Encode:
Hardware accelerated*:

```
Encode h264 baseline : 321x241 to 4096x4096 pixels, and/or 30.000 fps.
Encode h264 main     : 321x241 to 4096x4096 pixels, and/or 30.000 fps.
Encode h264 high     : 321x241 to 4096x4096 pixels, and/or 30.000 fps.
Encode vp8           : 321x241 to 4096x4096 pixels, and/or 30.000 fps.
```

Decode came up alongside it: h264, vp8, vp9 profile 0/2, hevc main/main10/still.
The 8192×8192 VP9 and HEVC decode limits are the UHD 630's signature, confirming
both paths landed on the iGPU rather than somewhere else.

Exactly the H.264 + VP8 encode set `vainfo` predicted. Gen9.5 predates VP9 encode
(Icelake/Gen11+) and AV1 entirely — no configuration adds either.

Two details from the dump worth carrying forward:

- **Chromium appended `--render-node-override=/dev/dri/renderD129` by itself**,
  pointing at the NVIDIA card. Encode still worked, because
  `--hardware-video-device-path` is checked first and wins outright. Direct
  evidence that the flag choice matters: the switch every forum post recommends
  was already set, to the wrong node, and lost.
- **Minimum encode resolution is 321×241**, not 16×16. Smaller frames fall back
  to software, so a WebRTC simulcast ladder uses hardware for the large layer and
  the CPU for small ones. Partial, not all-or-nothing. Decode goes down to 16×16.

**NVIDIA RTX 3080 with the NVENC fork — encode confirmed.** H.264 baseline/main/
high in `chrome://gpu`, WebCodecs output pixel-verified, `ffmpeg -vaapi` SSIM
0.9998. Caveats in [nvenc.md](nvenc.md).

## Untested

Should work from the code paths involved, but nobody has run it. Reports wanted.

| Hardware | Expectation |
|---|---|
| Intel Gen11+ (Ice Lake and newer) | VP9 encode as well as H.264/VP8 |
| Intel Arc / Xe | AV1 encode; `intel-media-driver` should cover it |
| Intel Gen8 and older | needs `intel.legacyDriver = true` (i965) |
| AMD RDNA2/3 | H.264 + HEVC encode, AV1 on RDNA3; Mesa radeonsi, no extra driver |
| AMD Vega / Polaris | H.264 + HEVC encode via VCE/VCN |
| AMD + NVIDIA hybrid | same `pciAddress` fix as Intel + NVIDIA |
| Intel iGPU laptop, displays on the iGPU | should need no `pciAddress` at all |
| X11 sessions | `chromium.forceDecode = true` likely needed for decode |
| NVENC fork on Turing / Ada | untested; NVENC generations differ in caps |

## Known not to work

| | |
|---|---|
| VP9 or AV1 encode on Intel Gen9.5 | absent from the silicon |
| AV1 encode on NVIDIA Ampere | absent from the silicon |
| Stock `nvidia-vaapi-driver` encode | it wraps NVDEC; there is no encode path |
| WebRTC simulcast via the NVENC fork | reference management unfinished — [nvenc.md](nvenc.md) |
