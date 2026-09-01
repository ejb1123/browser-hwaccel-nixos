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

  # WARNING, measured rather than assumed: pinning the device moves *decode* to
  # the Intel GPU too -- the setting is not encode-only. Decoded NV12 frames then
  # have to be imported by a compositor living on the other GPU, and on the test
  # machine that fails: gbm_bo_import errors, three GPU-process crashes, and then
  # Chromium disables accelerated video encode AND decode for the whole session.
  #
  # There is no way to keep encode and drop decode on Chromium -- see
  # docs/hybrid-gpu.md for the numbers. If you hit this, the fix is to run video
  # on the same GPU that drives your displays (examples/nvidia-nvenc.nix), not to
  # tune flags.
}
