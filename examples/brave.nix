# Brave (or any other Chromium-family browser).
#
# `browsers = [ "chromium" ]` means "the Chromium-family browser in
# chromium.package" -- point it at whichever one you use. Verified to accept
# commandLineArgs: chromium, ungoogled-chromium, brave, vivaldi, microsoft-edge,
# google-chrome.
#
# Brave needs preserveFeatures and the reason is worth understanding, because it
# bites silently. Chromium takes the LAST --enable-features switch on the command
# line instead of merging them, and this module's switch is appended after the
# packaged wrapper's. Brave's wrapper passes:
#
#     --enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder,...
#
# so leaving preserveFeatures empty deletes Brave's own video acceleration --
# the exact thing you installed this module to get. `browser-hwaccel-check`
# detects this and names the dropped features.
{
  pkgs,
  ...
}:
{
  hardware.browserHwaccel = {
    enable = true;
    vendor = "nvidia";
    encode = false;

    browsers = [ "chromium" ];

    chromium = {
      package = pkgs.brave;
      preserveFeatures = [
        "AcceleratedVideoDecodeLinuxGL"
        "AcceleratedVideoEncoder"
      ];
    };
  };

  # Brave is unfree.
  nixpkgs.config.allowUnfree = true;
}
