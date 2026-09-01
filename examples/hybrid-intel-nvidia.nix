# Intel iGPU + NVIDIA dGPU, with the displays on the NVIDIA card.
#
# This is the configuration that fails silently without help, and the one this
# project was built to fix. The Intel iGPU has the video engine we want; the
# NVIDIA card is "active" because it drives the monitors. Both browsers follow
# the active GPU by default, find no VA-API there, and quietly fall back to the
# CPU with nothing in any log a user would think to read.
#
# pciAddress is what breaks the tie. Get yours from `browser-hwaccel-check`.
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "intel";
    pciAddress = "0000:00:02.0";

    browsers = [
      "chromium"
      "firefox"
    ];
  };

  # Worth knowing: pinning the device moves *decode* to the Intel GPU as well --
  # the setting is not encode-only. Decoded frames then land on a different GPU
  # from the compositor, costing a cross-GPU copy per frame. If playback picks up
  # stutter or artefacts after this change, that is the cause, and
  # `decode = false;` keeps hardware encode while handing playback back to the CPU.
}
