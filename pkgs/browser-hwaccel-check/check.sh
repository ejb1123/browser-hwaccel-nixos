# browser-hwaccel-check -- report why your browser is (or is not) using the GPU
# to encode and decode video.
#
# Read-only. Run it before configuring anything to find out what you have, and
# after rebuilding to confirm the pieces line up.
#
# Shebang and shell options come from writeShellApplication; errexit is
# deliberately off, because a probe that fails is a result to report rather than
# a reason to abort.

bold=$'\e[1m'
dim=$'\e[2m'
red=$'\e[31m'
grn=$'\e[32m'
ylw=$'\e[33m'
rst=$'\e[0m'
if [ ! -t 1 ]; then
  bold=""; dim=""; red=""; grn=""; ylw=""; rst=""
fi

FAILED=0
ACTIVE_PCI=""
DRIVERS=""
CAPABLE_NODES=()

ok()    { printf '  %s[ ok ]%s %s\n' "$grn" "$rst" "$*"; }
warn()  { printf '  %s[warn]%s %s\n' "$ylw" "$rst" "$*"; }
bad()   { printf '  %s[fail]%s %s\n' "$red" "$rst" "$*"; FAILED=1; }
note()  { printf '         %s%s%s\n' "$dim" "$*" "$rst"; }
title() { printf '\n%s== %s ==%s\n' "$bold" "$*" "$rst"; }

##############################################################################
title "1. GPUs on this machine"
##############################################################################

# Which card drives a display matters more than it sounds. That card is the one
# Chromium treats as "active", and it matches candidate render nodes against
# that card's PCI IDs -- which is exactly what goes wrong on a hybrid machine.
for card in /sys/class/drm/card*; do
  base=${card##*/}
  case "$base" in
    *-*) continue ;; # connector entries like card0-DP-1
  esac
  [ -e "$card/device" ] || continue

  pci=$(basename "$(readlink -f "$card/device")")
  drv="?"
  if [ -e "$card/device/driver" ]; then
    drv=$(basename "$(readlink -f "$card/device/driver")")
  fi
  desc=$(lspci -s "$pci" 2>/dev/null | cut -d' ' -f2- | head -1)
  connected=$(grep -lx connected "$card"-*/status 2>/dev/null | wc -l)
  render="/dev/dri/by-path/pci-${pci}-render"

  printf '  %s%s%s  %s\n' "$bold" "$pci" "$rst" "${desc:-unknown device}"
  note "driver: $drv"
  if [ -e "$render" ]; then
    note "render node: $render -> $(readlink -f "$render")"
  else
    note "render node: none (no /dev/dri/by-path entry)"
  fi
  if [ "$connected" -gt 0 ]; then
    note "drives $connected connected display(s)  <-- ACTIVE GPU"
    ACTIVE_PCI="$pci"
  else
    note "drives no display"
  fi
done

if [ -z "$ACTIVE_PCI" ]; then
  warn "could not determine which GPU drives your displays"
fi

##############################################################################
title "2. VA-API drivers installed system-wide"
##############################################################################

DRIDIR=/run/opengl-driver/lib/dri
if [ -d "$DRIDIR" ]; then
  DRIVERS=$(find "$DRIDIR" -maxdepth 1 -name '*_drv_video.so' -printf '%f\n' 2>/dev/null | sort)
  if [ -n "$DRIVERS" ]; then
    ok "$(echo "$DRIVERS" | wc -l) driver(s) in $DRIDIR"
    while IFS= read -r driver; do
      note "$driver"
    done <<<"$DRIVERS"
  else
    bad "no *_drv_video.so found in $DRIDIR"
    note "nothing on this system can use VA-API at all"
  fi
else
  bad "$DRIDIR does not exist -- is hardware.graphics.enable set?"
fi

##############################################################################
title "3. What each GPU can actually encode and decode"
##############################################################################

if ! command -v vainfo >/dev/null 2>&1; then
  bad "vainfo not installed (add pkgs.libva-utils)"
else
  for node in /dev/dri/by-path/*-render; do
    [ -e "$node" ] || continue
    pci=${node##*/pci-}
    pci=${pci%-render}

    # Scrubbing LIBVA_* is the point: this must test the system configuration,
    # not whatever overrides happen to be exported in your shell.
    out=$(env -u LIBVA_DRIVER_NAME -u LIBVA_DRIVERS_PATH -u NVD_BACKEND \
      vainfo --display drm --device "$node" 2>/dev/null)

    printf '\n  %s%s%s\n' "$bold" "$pci" "$rst"
    if [ -z "$out" ]; then
      warn "vainfo returned nothing -- no usable VA-API driver for this device"
      continue
    fi

    drv=$(echo "$out" | grep -m1 'Driver version' | sed 's/.*: //')
    dec=$(echo "$out" | grep -c 'VAEntrypointVLD')
    enc=$(echo "$out" | grep -cE 'VAEntrypointEnc')
    note "driver: ${drv:-unknown}"

    if [ "$dec" -gt 0 ]; then
      ok "$dec decode entrypoint(s)"
    else
      warn "no decode entrypoints"
    fi

    if [ "$enc" -gt 0 ]; then
      ok "$enc encode entrypoint(s)"
      echo "$out" | grep -E 'VAEntrypointEnc' | awk '{print $1}' | sed 's/^VAProfile//; s/:$//' \
        | sort -u | tr '\n' ' ' | fold -s -w 66 | sed 's/^/         /'
      echo
      CAPABLE_NODES+=("$pci")
    else
      warn "no encode entrypoints -- this GPU cannot hardware-encode via VA-API"
      case "$drv" in
        *VA-API\ NVDEC\ driver* | *nvidia* )
          note "expected: stock nvidia-vaapi-driver wraps NVDEC only, never NVENC"
          ;;
      esac
    fi
  done
fi

##############################################################################
title "4. Hybrid-GPU check"
##############################################################################

if [ "${#CAPABLE_NODES[@]}" -eq 0 ]; then
  warn "no GPU on this machine offers VA-API encode"
  note "decode may still work -- check section 3 for VLD entrypoints"
elif [ -n "$ACTIVE_PCI" ] && [[ " ${CAPABLE_NODES[*]} " == *" $ACTIVE_PCI "* ]]; then
  ok "the encode-capable GPU ($ACTIVE_PCI) is also driving your displays"
  note "leave hardware.browserHwaccel.pciAddress unset -- no override needed"
else
  warn "the encode-capable GPU is NOT the one driving your displays"
  note "active GPU: ${ACTIVE_PCI:-unknown}"
  note "encode GPU: ${CAPABLE_NODES[0]}"
  note ""
  note "This is the case that fails silently. Chromium matches render nodes"
  note "against the ACTIVE GPU's PCI IDs, finds that card, rejects it for"
  note "VA-API, and stops -- it never tries the other one. Firefox likewise"
  note "opens the wrong node. Point both at the right device:"
  note ""
  note "  hardware.browserHwaccel.vendor     = \"intel\";  # or amd / nvidia"
  note "  hardware.browserHwaccel.pciAddress = \"${CAPABLE_NODES[0]}\";"
fi

##############################################################################
title "5. Browser configuration"
##############################################################################

if command -v chromium >/dev/null 2>&1; then
  wrapper=$(readlink -f "$(command -v chromium)")
  args=$(grep -o -- '--[a-z0-9-]*[^ "]*' "$wrapper" 2>/dev/null | tr '\n' ' ')

  if echo "$args" | grep -q 'hardware-video-device-path'; then
    ok "chromium: --hardware-video-device-path is set"
    note "$(echo "$args" | tr ' ' '\n' | grep hardware-video-device-path)"
  else
    note "chromium: no --hardware-video-device-path (fine on a single-GPU machine)"
  fi

  if echo "$args" | grep -q 'AcceleratedVideoEncoder'; then
    ok "chromium: AcceleratedVideoEncoder is enabled"
  else
    warn "chromium: AcceleratedVideoEncoder not enabled -- encode will use the CPU"
  fi

  if echo "$args" | grep -q 'render-node-override'; then
    note "chromium: --render-node-override present. It is the older, lower-priority"
    note "switch; --hardware-video-device-path is consulted first and wins."
  fi
else
  note "chromium not on PATH -- skipping"
fi

echo
if command -v firefox >/dev/null 2>&1; then
  ff=$(readlink -f "$(command -v firefox)")
  if grep -q 'MOZ_DRM_DEVICE' "$ff" 2>/dev/null; then
    ok "firefox: MOZ_DRM_DEVICE is set on the wrapper"
  else
    note "firefox: no MOZ_DRM_DEVICE (fine on a single-GPU machine)"
  fi
  if grep -q 'MOZ_DISABLE_RDD_SANDBOX' "$ff" 2>/dev/null; then
    note "firefox: RDD sandbox disabled (required by nvidia-vaapi-driver)"
  fi
else
  note "firefox not on PATH -- skipping"
fi

##############################################################################
title "6. The tests only you can run"
##############################################################################

cat <<'EOF'
  Everything above is necessary but not sufficient. Two checks prove the path
  end to end, and neither can be automated -- both need a real window.

  Chromium
    chrome://gpu -> "Video Acceleration Information"
        want: "Encode h264 ..." entries with resolution ranges.
        an empty section means encode is still on the CPU.
    chrome://webrtc-internals during an actual video call
        want: encoderImplementation = VaapiVideoEncodeAccelerator
        software fallback reports "libvpx" or "OpenH264".

  Firefox
    about:support -> "Media" section; look for HARDWARE decoders/encoders.
    about:webrtc during a call; check the outbound video stream's encoder.

  Two things that look like bugs and are not:
    - Hardware encode has a minimum frame size (321x241 on Intel Gen9.5).
      WebRTC simulcast also sends smaller layers, and those encode on the CPU.
      Partial hardware use during a call is normal.
    - Encode is not used for video playback. That is decode, a separate path.
EOF

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%s== no blocking problems found ==%s\n' "$grn" "$rst"
else
  printf '%s== problems found; see the [fail] lines above ==%s\n' "$red" "$rst"
fi
exit "$FAILED"
