# The hybrid-GPU failure

If your machine has two GPUs and the one driving your displays isn't the one with
the video engine you want, both browsers will quietly encode and decode on the
CPU and tell you nothing useful about it.

This document is the long version, because the short version — "set
`pciAddress`" — doesn't help you recognise the problem in the first place.

## What it looks like

`vainfo` works. `chrome://gpu` shows an empty *Video Acceleration Information*
section. Every guide you find says to install the driver, which you already did.

With `--vmodule='*vaapi*=3'`, Chromium says exactly this and nothing more:

```
WARNING:media/gpu/vaapi/vaapi_wrapper.cc:130]
    Should skip nVidia device named: nvidia-drm
VERBOSE1:media/gpu/vaapi/vaapi_wrapper.cc:1750]
    GetHandle(): ... failed to find a suitable render node
```

Two lines. Both technically accurate, neither pointing at the actual problem.

## What's happening

`VADisplayStateSingleton::PreSandboxInitialization()` enumerates DRM devices with
`drmGetDevices2()`. When active-GPU information is available, it filters
candidates by **matching the active GPU's PCI vendor and device ID**, takes the
first match, and stops.

On a desktop with an Intel iGPU and an NVIDIA card driving both monitors, the
active GPU is the NVIDIA card. So Chromium:

1. matches the NVIDIA device,
2. correctly refuses it — `nvidia-vaapi-driver` has no encode path,
3. **stops**, with no fallback to the Intel node.

Chromium never attempts `renderD128`. The Intel encoder is sitting right there,
fully functional, and is never asked.

Note the shape of this: installing the driver is necessary and does nothing on
its own. Two independent blockers, and fixing only the obvious one produces no
observable change — which is why this eats an afternoon.

Firefox reaches the same place by a different route: it opens the default DRM
device rather than searching for a capable one.

## The fix

```nix
hardware.browserHwaccel = {
  enable = true;
  vendor = "intel";              # the GPU with the video engine
  pciAddress = "0000:00:02.0";   # its PCI address, from `lspci -D`
};
```

That becomes `--hardware-video-device-path=…` for Chromium and `MOZ_DRM_DEVICE=…`
for Firefox. `browser-hwaccel-check` section 4 detects this situation and prints
the exact address to use.

## The trade-off you're accepting — read this before committing to it

**The device override is not encode-only.** It selects the device for the whole
VA-API stack, so hardware *decode* moves to the same GPU. On a split-GPU desktop
that means decoded frames land on the Intel GPU while the compositor and GL
context live on NVIDIA, and every frame must be imported across GPUs.

On the measured system that import **fails**, and it does not fail gracefully.

### What was measured

Chromium 152, Intel UHD 630 pinned for video, both displays on an RTX 3080, KDE
Wayland. Load a page that decodes H.264, wait 35 seconds:

| Configuration | GPU crashes | NV12 import failures | Outcome |
|---|---|---|---|
| Intel pinned, decode on | 3 | 3 | encode **and** decode disabled |
| `--disable-accelerated-video-decode` | 0 | 0 | no crashes, but encode gone too |
| `--disable-gpu-memory-buffer-video-frames` | 3 | 3 | no help |
| Video on the NVIDIA GPU instead | **0** | **0** | encode and decode both fine |

The error, once per crash:

```
gbm_bo_import returned nullptr
Cannot create bo with format=(Y_UV, 420, 8unorm, ExtSamplerOn)
CreateSharedImage: could not create backing
Restarting GPU process due to unrecoverable error
```

After three GPU-process crashes Chromium gives up permanently and `chrome://gpu`
reports *"Accelerated video encode has been disabled"* for the rest of the
session. The failure mode is not stutter — it is hardware video switching itself
off partway through your browsing, which looks exactly like the
misconfiguration you were trying to fix.

### There is no encode-only escape hatch on Chromium

An earlier version of this page said `decode = false` keeps hardware encode and
hands playback back to the CPU. **That was wrong.** Row 2 above is the
measurement: `--disable-accelerated-video-decode` takes the whole VA-API stack
with it, and `chrome://gpu` then lists zero encode entries. The module now
refuses that combination with an assertion instead of pretending it works.

Firefox is genuinely different — `media.hardware-video-decoding.enabled` and
`media.hardware-video-encoding.enabled` are independent prefs there.

### So what should you do?

**Prefer the GPU that drives your displays**, even when its codec support is
worse. Same-GPU video costs you codecs. Cross-GPU video can cost you the whole
feature, at an unpredictable moment.

Pin a different GPU only when it is the only one with a codec you actually need,
and test with real video playback before relying on it. Some hybrid pairings
import NV12 across GPUs without complaint; this one does not, and there is no
way to tell which you have without trying.

On this particular machine the answer turned out to be the NVIDIA card with the
[NVENC fork](nvenc.md): video and compositor on the same GPU, zero crashes, plus
HEVC and AV1 decode the Intel iGPU does not have at all.

## Finding your PCI address

```console
$ browser-hwaccel-check      # sections 1 and 4 do this for you
$ lspci -D | grep -i vga     # or the manual version
0000:00:02.0 VGA compatible controller: Intel Corporation CoffeeLake-S GT2 [UHD Graphics 630]
0000:01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3080]
```

Use the address of the GPU whose encoder you want — the one that showed
`VAEntrypointEnc*` entries in section 3 of the check.

## Laptops with muxless hybrid graphics

The common Intel-iGPU-plus-NVIDIA laptop is usually the *easy* case: the iGPU
drives the internal panel, so it's already the active GPU and no override is
needed. Leave `pciAddress` unset.

It flips when you run PRIME offload with an external monitor wired directly to
the NVIDIA card. Then the NVIDIA GPU is active and you're back in the case above.
Which means the right `pciAddress` can depend on what's plugged in — one more
reason to run the check on the machine as you actually use it rather than
reasoning about it from the model number.
