# Launch a browser with hardware video acceleration configured at RUNTIME.
#
# The NixOS module cannot autodetect your GPU, because Nix evaluates on the build
# machine and a build machine cannot see the target's PCI bus. A launcher can --
# it runs on the machine in question. That is the whole reason this exists
# alongside the module.
#
# Set BROWSER_PKG (store path) and BROWSER_BIN (basename) before sourcing.
# Shell options come from writeShellApplication; errexit is off on purpose.

VERBOSE=${HWACCEL_VERBOSE:-0}
say() { [ "$VERBOSE" = 1 ] && printf '[hwaccel] %s\n' "$*" >&2; return 0; }
warn() { printf '[hwaccel] %s\n' "$*" >&2; }

##############################################################################
# 1. Where do VA-API drivers live?
##############################################################################
# On NixOS /run/opengl-driver is the symlink farm that includes the proprietary
# NVIDIA bits, which cannot be bundled here because they must match the running
# kernel module. Prefer it when present; otherwise fall back to the drivers
# built into this package, which is what makes the launcher work on other
# distributions.
if [ -d /run/opengl-driver/lib/dri ]; then
  export LIBVA_DRIVERS_PATH="/run/opengl-driver/lib/dri:@driverdir@"
  say "using system VA-API drivers (/run/opengl-driver) with bundled fallback"
else
  export LIBVA_DRIVERS_PATH="@driverdir@"
  say "no /run/opengl-driver -- using bundled VA-API drivers only"
fi

##############################################################################
# 2. Which GPU should do the video work?
##############################################################################
# Findings that shaped this: prefer the GPU that drives the displays. Pinning a
# different one means decoded NV12 frames are imported across GPUs, which on at
# least one measured system crashes Chromium's GPU process until it disables
# hardware video entirely. See docs/hybrid-gpu.md.

ACTIVE_PCI=""
ALL_PCI=""
for card in /sys/class/drm/card*; do
  base=${card##*/}
  case "$base" in *-*) continue ;; esac
  [ -e "$card/device" ] || continue
  pci=$(basename "$(readlink -f "$card/device")")
  [ -e "/dev/dri/by-path/pci-${pci}-render" ] || continue
  ALL_PCI="$ALL_PCI $pci"
  if [ "$(grep -lx connected "$card"-*/status 2>/dev/null | wc -l)" -gt 0 ]; then
    ACTIVE_PCI="$pci"
  fi
done

# Does a node offer VA-API at all? Empty output means no usable driver.
has_vaapi() {
  env -u LIBVA_DRIVER_NAME -u NVD_BACKEND vainfo \
    --display drm --device "/dev/dri/by-path/pci-$1-render" 2>/dev/null \
    | grep -q 'VAEntrypoint'
}

TARGET_PCI=""
if [ -n "${HWACCEL_PCI:-}" ]; then
  TARGET_PCI="${HWACCEL_PCI:-}"
  say "using HWACCEL_PCI override: $TARGET_PCI"
elif [ -n "$ACTIVE_PCI" ] && has_vaapi "$ACTIVE_PCI"; then
  # Best case: the display GPU can do video. No cross-GPU import, no pinning.
  TARGET_PCI="$ACTIVE_PCI"
  say "display GPU $TARGET_PCI has VA-API; using it (no device override needed)"
  TARGET_PCI=""   # deliberately leave the flag off; the default already picks it
else
  for pci in $ALL_PCI; do
    if has_vaapi "$pci"; then TARGET_PCI="$pci"; break; fi
  done
  if [ -n "$TARGET_PCI" ]; then
    warn "the GPU driving your displays (${ACTIVE_PCI:-unknown}) has no usable VA-API driver."
    warn "Falling back to $TARGET_PCI. This means decoded frames cross GPUs, which"
    warn "can crash the GPU process on some systems -- if video misbehaves, run"
    warn "with HWACCEL_NO_DECODE=1, or accept software video."
  else
    warn "no GPU on this system offers VA-API; the browser will use the CPU."
  fi
fi

##############################################################################
# 3. Assemble flags
##############################################################################
FEATURES="WaylandWindowDecorations"
[ "${HWACCEL_NO_ENCODE:-0}" = 1 ] || FEATURES="AcceleratedVideoEncoder,$FEATURES"

# Chromium refuses VA-API on NVIDIA devices without this. Harmless elsewhere.
if [ -n "$TARGET_PCI" ] || [ -n "$ACTIVE_PCI" ]; then
  drv=$(basename "$(readlink -f "/sys/bus/pci/devices/${TARGET_PCI:-$ACTIVE_PCI}/driver" 2>/dev/null)" 2>/dev/null || echo "")
  case "$drv" in
    nvidia*) FEATURES="VaapiOnNvidiaGPUs,$FEATURES"; export NVD_BACKEND="${NVD_BACKEND:-direct}" ;;
  esac
fi

ARGS=("--enable-features=$FEATURES" "--ignore-gpu-blocklist")
[ -n "$TARGET_PCI" ] && ARGS+=("--hardware-video-device-path=/dev/dri/by-path/pci-${TARGET_PCI}-render")
# Note this disables the whole VA-API stack, encode included -- there is no
# decode-only switch in Chromium. Offered because a crashing GPU process is
# worse than software video.
[ "${HWACCEL_NO_DECODE:-0}" = 1 ] && ARGS+=("--disable-accelerated-video-decode")

say "flags: ${ARGS[*]}"

if [ "${HWACCEL_PRINT_ONLY:-0}" = 1 ]; then
  printf '%s\n' "LIBVA_DRIVERS_PATH=$LIBVA_DRIVERS_PATH"
  printf '%s\n' "${ARGS[@]}"
  exit 0
fi

exec "@browser@" "${ARGS[@]}" "$@"
