# AMD GPU (integrated or discrete).
#
# Nothing extra to install: radeonsi_drv_video.so ships inside Mesa, which
# hardware.graphics already pulls in. All this module contributes on AMD is the
# encode feature flags, which are still opt-in in both browsers.
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "amd";
  };
}
