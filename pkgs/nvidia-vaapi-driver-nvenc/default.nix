# nvidia-vaapi-driver with NVENC encode support.
#
# Upstream (elFarto/nvidia-vaapi-driver) is an NVDEC wrapper: decode only. This
# is a fork that additionally exposes NVIDIA's *encoder* through VA-API, which
# is what makes hardware encode possible in Chromium and Firefox on an NVIDIA
# GPU at all.
#
# It is deliberately not something to reach for casually -- see docs/nvenc.md
# for what works, what does not, and how it was verified.
#
# Built as an overrideAttrs of the nixpkgs package rather than from scratch, so
# that dependency and runpath fixes upstream in nixpkgs keep applying here.

{
  lib,
  nvidia-vaapi-driver,
  src ? null,
}:

assert lib.assertMsg (src != null) ''
  nvidia-vaapi-driver-nvenc needs a `src`.

  Use this flake's nixosModules.default or overlays.default, which pin the fork,
  rather than calling the package directly with no arguments.
'';

nvidia-vaapi-driver.overrideAttrs (old: {
  pname = "nvidia-vaapi-driver-nvenc";
  version = "${old.version}-nvenc-unstable";

  inherit src;

  # nixpkgs carries a patch for this; the fork shifts meson.build by a line and
  # a textual substitution is less brittle than a context diff we did not write.
  patches = [ ];
  postPatch = ''
    substituteInPlace meson.build \
      --replace-fail \
        "nvidia_install_dir = libva_deps.get_variable(pkgconfig: 'driverdir')" \
        "nvidia_install_dir = get_option('libdir') / 'dri'"
  '';

  # Inherited from nixpkgs and load-bearing for encode specifically:
  #   nv-codec-headers-11    provides nvEncodeAPI.h next to the decode headers,
  #                          so the encode path adds no new dependency
  #   gst-plugins-bad        gstreamer-codecparsers-1.0 gates src/vp9.c; drop it
  #                          and you silently lose VP9 decode
  #   addDriverRunpath       libnvidia-encode.so.1 is dlopened at runtime from
  #                          the driver profile, not the store closure

  meta = old.meta // {
    homepage = "https://github.com/ejb1123/nvidia-vaapi-driver";
    description = "VA-API implementation using NVIDIA NVDEC and NVENC (experimental encode fork)";
  };
})
