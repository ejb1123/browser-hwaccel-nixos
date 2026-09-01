{
  lib,
  writeShellApplication,
  libva-utils,
  pciutils,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  gawk,
}:

writeShellApplication {
  name = "browser-hwaccel-check";

  runtimeInputs = [
    libva-utils
    pciutils
    coreutils
    findutils
    gnugrep
    gnused
    gawk
  ];

  # No errexit: the script deliberately tolerates failing probes -- a missing
  # driver is a result to report, not a reason to abort -- and manages its own
  # exit code.
  bashOptions = [
    "nounset"
    "pipefail"
  ];

  text = builtins.readFile ./check.sh;

  meta = {
    description = "Diagnose hardware video encode/decode support for web browsers";
    mainProgram = "browser-hwaccel-check";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
