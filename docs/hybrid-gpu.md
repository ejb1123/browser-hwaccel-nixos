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

## The trade-off you're accepting

**The device override is not encode-only.** It selects the device for the whole
VA-API stack, so hardware *decode* moves to the same GPU.

On a split-GPU desktop that means decoded frames land on the Intel GPU while the
compositor and GL context live on NVIDIA — a cross-GPU copy per frame. It's a
known source of stutter and, in some reports, visible corruption.

Whether that's a regression depends on where you started:

- **No VA-API at all before** (the usual case — Chromium had rejected the NVIDIA
  device and given up): anything is an improvement.
- **Working NVDEC decode before**: you may be trading good decode for encode.

If playback picks up artefacts or stutter after this change, the cause is
decode, not encode. `decode = false;` keeps hardware encode and hands playback
back to the CPU.

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
