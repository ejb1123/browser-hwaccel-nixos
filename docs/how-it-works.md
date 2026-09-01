# How it works

What the module actually sets, and why each piece is the way it is. Most of this
is here because the obvious version is wrong in a way that takes a while to
notice.

## The VA-API driver

```nix
hardware.graphics.extraPackages = [ pkgs.intel-media-driver ];
```

Provides `iHD_drv_video.so`. Without it there is no Intel VA-API driver anywhere
on a NixOS system — `intel-media-driver` is frequently *in* the store already as
some other package's dependency, which makes this easy to miss. It's only
reachable if it's in `extraPackages`, because that's what builds the
`/run/opengl-driver` symlink farm.

Vendor by vendor:

- **Intel** — `intel-media-driver` (iHD) for Gen9 / Skylake and newer.
  `intel-vaapi-driver` (i965) for Broadwell and older; set
  `intel.legacyDriver = true`.
- **AMD** — nothing. `radeonsi_drv_video.so` ships inside Mesa, which
  `hardware.graphics` already installs. This module contributes only the flags.
- **NVIDIA** — `nvidia-vaapi-driver`, which wraps NVDEC. Decode only; see
  [nvenc.md](nvenc.md).

`/run/opengl-driver` is rebuilt during activation, so a reboot usually isn't
needed — but the path is resolved at session start, so log out and back in if a
driver you just added doesn't show up.

## `LIBVA_DRIVER_NAME`: don't set it globally

Every forum thread tells you to export it. On a machine with one GPU it's
harmless and unnecessary; on a machine with two it is actively destructive.

Once both `iHD_drv_video.so` and `nvidia_drv_video.so` are in the same directory,
libva picks the right one per device from the DRM driver name — `i915` gives you
iHD, `nvidia` gives you the NVIDIA driver. That's automatic and correct. Forcing
a single name in the environment applies it to *every* VA-API client on the
system, including the ones that were choosing correctly on their own.

This module only ever sets it on the Firefox wrapper, and only when you've pinned
a specific render node (`firefox.forceVaDriver`, which defaults to exactly that
condition).

## Chromium: `--hardware-video-device-path`

```
--hardware-video-device-path=/dev/dri/by-path/pci-0000:00:02.0-render
```

This is the flag that matters on a hybrid machine, and it is **not** the one most
guides recommend.

`VADisplayStateSingleton::PreSandboxInitialization()` in
[`media/gpu/vaapi/vaapi_wrapper.cc`](https://github.com/chromium/chromium/blob/main/media/gpu/vaapi/vaapi_wrapper.cc)
consults, in order:

1. `--hardware-video-device-path` — used outright if set,
2. `--render-node-override`,
3. otherwise, enumerate DRM devices and filter by the active GPU's PCI IDs.

The widely-recommended switch is `--render-node-override`. It loses, because
Chromium sets it *itself* — pointed at the active GPU. On the test machine
`chrome://gpu` shows `--render-node-override=/dev/dri/renderD129` (the NVIDIA
card) appended by Chromium, while encode runs on `renderD128` because
`--hardware-video-device-path` was checked first. If you set
`--render-node-override` and nothing changes, this is why.

### Use the PCI-derived path

`renderD128` / `renderD129` numbering follows driver registration order and is
**not stable across boots or kernel updates**. `/dev/dri/by-path/pci-*-render` is
derived from the PCI address and is. The module builds it from `pciAddress` for
exactly this reason; `videoDevice` exists as an escape hatch, not a
recommendation.

## Chromium: `--enable-features`, and a trap

```
--enable-features=AcceleratedVideoEncoder,WaylandWindowDecorations
```

`AcceleratedVideoEncoder` is the opt-in for hardware encode. Decode defaults on
under Wayland since Chromium ~143, so `chromium.forceDecode` is off by default —
try without it first.

`WaylandWindowDecorations` looks like it doesn't belong. It's load-bearing.

**Chromium does not merge duplicate `--enable-features` switches.**
`base::CommandLine` returns the *last* occurrence, and the nixpkgs Chromium
wrapper already emits its own `--enable-features=WaylandWindowDecorations`
earlier on the exec line. Append a second one without repeating it and you
silently lose server-side window decorations under KDE — a cosmetic regression
with no obvious connection to video, which is a bad afternoon if you don't know
to look for it.

`chromium.preserveWaylandDecorations` handles this and defaults to on. Leave it
alone unless you're adding features some other way.

`--ignore-gpu-blocklist` is on by default because a GPU driving no display gets
blocklisted more or less on principle.

## Firefox

Firefox has no command-line equivalent, so the module works through the wrapper
and autoconfig instead.

**Environment, set on the wrapper only:**

| Variable | When | Why |
|---|---|---|
| `MOZ_DRM_DEVICE` | a render node is pinned | Firefox's equivalent of Chromium's device override |
| `LIBVA_DRIVER_NAME` | a render node is pinned | see above — wrapper scope only |
| `NVD_BACKEND=direct` | vendor is NVIDIA | required by `nvidia-vaapi-driver` on the open kernel module |
| `MOZ_DISABLE_RDD_SANDBOX=1` | vendor is NVIDIA | see the warning below |

**Prefs, via `extraPrefs`:**

```
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-encoding.enabled", true);
```

These are `pref`, not `lockPref` — they set defaults you can still change in
`about:config`. The `force-enabled` variants, behind `firefox.forceEnable`,
bypass Mozilla's internal driver blocklist. Required on NVIDIA, since
`nvidia-vaapi-driver` was never on Mozilla's vetted list. On Intel and AMD, try
without them.

> **`MOZ_DISABLE_RDD_SANDBOX=1` is a real security trade-off.** It weakens the
> sandbox around the media decoder — a process whose whole job is parsing
> hostile input from the network. It's the standard workaround for
> `nvidia-vaapi-driver`, which needs device access the sandbox denies, and
> without it Firefox falls back to software with no visible error. It is an
> option (`firefox.disableRddSandbox`) rather than something implied by
> `vendor = "nvidia"`, so that turning it off is a decision you can make.

## Verifying

`browser-hwaccel-check` covers everything that can be checked without a window.
The two tests that actually prove the path can't be automated:

- **Chromium** — `chrome://gpu` → *Video Acceleration Information* should list
  `Encode h264 …` with resolution ranges. Then `chrome://webrtc-internals`
  during a real call: `encoderImplementation = VaapiVideoEncodeAccelerator`.
  Software fallback reports `libvpx` or `OpenH264`.
- **Firefox** — `about:support` → *Media*, then `about:webrtc` during a call.

Absence of VA-API errors in the Chromium log is only negative evidence. The
device can open cleanly and encode can still land on the CPU.
