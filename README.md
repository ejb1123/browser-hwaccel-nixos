# browser-hwaccel-nixos

Hardware video **encode and decode** for Chromium and Firefox on NixOS, in one
import.

```nix
# flake.nix
inputs.browser-hwaccel.url = "github:ejb1123/browser-hwaccel-nixos";

# configuration.nix
imports = [ inputs.browser-hwaccel.nixosModules.default ];

hardware.browserHwaccel = {
  enable = true;
  vendor = "intel";          # or "amd" / "nvidia"
  pciAddress = "0000:00:02.0";  # hybrid machines only
};
```

Rebuild, then run `browser-hwaccel-check`.

## Why this exists

Getting a browser to use your video engine on Linux is three separate problems
that all fail the same way — a silent fall back to the CPU, no error anywhere a
person would think to look:

1. **The VA-API driver isn't installed.** On NixOS, `intel-media-driver` is not
   in `hardware.graphics.extraPackages` by default, so `iHD_drv_video.so`
   doesn't exist anywhere the loader can find it. Every VA-API client on the
   machine is blind.
2. **The browser opens the wrong GPU.** Chromium picks its VA-API device by
   matching the *active* GPU's PCI IDs. On a hybrid machine that's whichever
   card drives your monitors — often not the one with the usable video engine.
   It matches that card, rejects it, and stops. It never tries the other node.
3. **Encode is still opt-in.** Decode has defaulted on in Chromium under Wayland
   since ~143. Encode has not, in either browser.

Each fix is a one-liner. Finding out which one you need is the hard part, which
is what `browser-hwaccel-check` is for.

## What you get

- A NixOS module that installs the right VA-API driver for your vendor, pins the
  render node when you need it pinned, and sets the encode flags and prefs for
  both browsers.
- `browser-hwaccel-check` — a read-only diagnostic that enumerates your GPUs,
  says which one drives your displays, reports what each can actually encode and
  decode, and tells you whether you have the hybrid problem.
- Experimental **NVENC encode on NVIDIA** via a fork of `nvidia-vaapi-driver`
  ([docs/nvenc.md](docs/nvenc.md)). Upstream is decode-only; this adds an encode
  path. It is a work in progress and labelled as such.

## Start here

Run the check first. It will tell you which vendor to set and whether you need
`pciAddress` at all:

```console
$ nix run github:ejb1123/browser-hwaccel-nixos
```

Then pick the example that matches:

| Your machine | Example |
|---|---|
| One Intel GPU | [`examples/intel-igpu.nix`](examples/intel-igpu.nix) |
| One AMD GPU | [`examples/amd.nix`](examples/amd.nix) |
| Intel iGPU + NVIDIA, displays on NVIDIA | [`examples/hybrid-intel-nvidia.nix`](examples/hybrid-intel-nvidia.nix) |
| NVIDIA only, decode | [`examples/nvidia.nix`](examples/nvidia.nix) |
| NVIDIA, experimental encode | [`examples/nvidia-nvenc.nix`](examples/nvidia-nvenc.nix) |

## Set expectations before you start

**Encode is not playback.** Hardware encode is used when your machine *produces*
video: WebRTC calls, screen sharing, `MediaRecorder`, WebCodecs. If you want
YouTube to be lighter on the CPU, that's decode — a different path with
different flags, also covered here.

**Your GPU decides what's possible.** No amount of configuration adds a codec
the silicon doesn't have. Intel Gen9.5 (UHD 630) has no VP9 encode and no AV1 at
all; Ampere has no AV1 encode. `browser-hwaccel-check` section 3 reads the real
capability list off the hardware rather than guessing from the model name.

**Partial hardware use in a call is normal.** Encoders have a minimum frame size
— 321×241 on Gen9.5. WebRTC simulcast sends smaller layers as well, and those
encode on the CPU while the full-size layer uses the GPU. Seeing both is correct
behaviour, not a broken configuration.

**On hybrid machines, prefer the GPU that drives your displays.** Pinning video
to a *different* GPU is what makes VA-API visible at all — but it also means
every decoded frame crosses GPUs, and on at least one measured system that
crashes Chromium's GPU process until it disables hardware video entirely. There
is no flag that keeps encode while dropping decode. Same-GPU video costs you
codecs; cross-GPU video can cost you the whole feature.
[docs/hybrid-gpu.md](docs/hybrid-gpu.md) has the measurements.

## Options

Full descriptions live in [`modules/browser-hwaccel.nix`](modules/browser-hwaccel.nix).
The ones that matter:

| Option | Default | |
|---|---|---|
| `vendor` | — | `"intel"`, `"amd"`, `"nvidia"`. Required. |
| `pciAddress` | `null` | Pin the GPU that does the video work. Hybrid machines only. |
| `browsers` | both | `[ "chromium" "firefox" ]` |
| `encode` / `decode` | `true` | |
| `chromium.package` | `pkgs.chromium` | Point at `ungoogled-chromium`, `brave`, … |
| `firefox.forceEnable` | `false` | Bypass Firefox's driver blocklist. Needed on NVIDIA. |
| `nvenc.enable` | `false` | Experimental NVIDIA encode. Read the doc first. |

There is deliberately no `vendor = "auto"`. Nix evaluates on the build machine,
and a build machine cannot see the target's PCI bus. Run the check and write
down what it says.

## Documentation

- [How it works](docs/how-it-works.md) — what each flag does and why that
  specific flag, including the two that most guides get wrong.
- [Hybrid GPUs](docs/hybrid-gpu.md) — the failure mode in detail, and the
  trade-off you accept by fixing it.
- [NVENC on NVIDIA](docs/nvenc.md) — the fork: what works, what doesn't, how it
  was verified.
- [Verified hardware](docs/verified-hardware.md) — what has actually been tested
  by someone, versus what should work in principle.

## Contributing

Hardware reports are the most useful thing you can send. Run
`browser-hwaccel-check`, open an issue with the output and your working config,
and it goes in [docs/verified-hardware.md](docs/verified-hardware.md).

## Licence

MIT. The NVENC fork inherits `nvidia-vaapi-driver`'s MIT licence.
