# A `nix run`-able browser with hardware video acceleration set up at runtime.
#
# The NixOS module is the right answer if you run NixOS. This is for everyone
# else -- any distro with Nix installed -- and for trying things without
# rebuilding a system. It detects the GPU when it starts rather than when it is
# built, which is something the module fundamentally cannot do.

{
  lib,
  writeShellApplication,
  symlinkJoin,
  libva-utils,
  coreutils,
  gnugrep,
  pciutils,
  intel-media-driver,
  mesa,
  vpl-gpu-rt,

  # The browser to wrap, and the binary name inside it.
  browser,
  binaryName ? lib.getName browser,
}:

let
  # One directory containing every VA-API driver we can ship. libva selects the
  # right one per device from the DRM driver name (i915 -> iHD, amdgpu ->
  # radeonsi), so bundling them all is safe and removes a configuration step.
  #
  # NVIDIA is deliberately absent: nvidia-vaapi-driver dlopens libnvidia-encode
  # from the running driver installation, which cannot be pinned in a store path
  # without matching the host kernel module. On NixOS the script picks it up from
  # /run/opengl-driver instead.
  driverBundle = symlinkJoin {
    name = "vaapi-drivers";
    paths = [
      intel-media-driver
      mesa
      vpl-gpu-rt
    ];
  };

  script = builtins.replaceStrings
    [ "@driverdir@" "@browser@" ]
    [ "${driverBundle}/lib/dri" "${browser}/bin/${binaryName}" ]
    (builtins.readFile ./run.sh);
in
writeShellApplication {
  name = "${binaryName}-hwaccel";

  runtimeInputs = [
    libva-utils
    coreutils
    gnugrep
    pciutils
  ];

  # errexit off: a GPU probe that fails is information, not a reason to abort
  # before the browser ever starts.
  bashOptions = [
    "nounset"
    "pipefail"
  ];

  text = script;

  meta = {
    description = "${binaryName} with hardware video acceleration configured at runtime";
    mainProgram = "${binaryName}-hwaccel";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
