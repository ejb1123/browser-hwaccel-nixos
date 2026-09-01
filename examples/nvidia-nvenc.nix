# NVIDIA with experimental hardware encode via the NVENC fork.
#
# Read docs/nvenc.md first. This replaces nvidia-vaapi-driver system-wide with a
# work-in-progress fork. H.264 and HEVC encode work and have been verified
# pixel-for-pixel, but reference-frame management and packed headers are
# unfinished, which is precisely what WebRTC simulcast depends on.
#
# Reasonable for WebCodecs, MediaRecorder, and single-layer calls. Not something
# to put on a machine you need to be dependable.
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "nvidia";

    encode = true;
    decode = true;

    nvenc.enable = true;

    firefox = {
      forceEnable = true;
      disableRddSandbox = true;
    };
  };
}
