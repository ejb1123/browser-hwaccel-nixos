# Single Intel GPU (a laptop, or a desktop running off the iGPU).
#
# The common case, and the least fiddly: there is only one render node, so both
# browsers find it without being told where to look. Leave pciAddress unset.
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "intel";
  };
}
