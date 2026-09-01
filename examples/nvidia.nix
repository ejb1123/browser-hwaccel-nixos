# NVIDIA only, decode.
#
# Note `encode = false`. The stock nvidia-vaapi-driver is a wrapper around
# NVDEC and has no encode path whatsoever, so asking for hardware encode here
# gets you a silent CPU fallback rather than an error. Leaving it on would just
# be a lie in your configuration.
#
# If you want NVIDIA hardware encode, see docs/nvenc.md and
# examples/nvidia-nvenc.nix -- with the caveats there taken seriously.
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "nvidia";

    decode = true;
    encode = false;

    firefox = {
      # nvidia-vaapi-driver is not on Mozilla's vetted list, so the normal path
      # refuses it; and the RDD sandbox denies the device access it needs.
      forceEnable = true;
      disableRddSandbox = true;
    };
  };
}
