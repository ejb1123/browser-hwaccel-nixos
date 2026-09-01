# Hardware video encode/decode for Chromium and Firefox.
#
# The whole point of this module is that three separate things have to line up
# before a browser will touch your video engine, and failing any one of them
# looks identical from the outside (a silent fall back to CPU):
#
#   1. a VA-API driver for your GPU exists somewhere the loader can find it,
#   2. the browser picks *that* GPU's render node -- not the one driving your
#      display, which is a different card on a hybrid machine,
#   3. the encode path is switched on, because it is still opt-in in both
#      browsers long after decode stopped being.
#
# See docs/how-it-works.md for the reasoning behind each block below.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.browserHwaccel;

  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    optional
    optionals
    concatStringsSep
    ;

  # Resolve the render node the browsers should use, or null to let each browser
  # pick for itself. pciAddress is the preferred spelling: /dev/dri/renderD128
  # is assigned in driver-registration order and is NOT stable across boots or
  # kernel updates, whereas the by-path symlink is derived from the PCI address
  # and is.
  renderNode =
    if cfg.videoDevice != null then
      cfg.videoDevice
    else if cfg.pciAddress != null then
      "/dev/dri/by-path/pci-${cfg.pciAddress}-render"
    else
      null;

  vaDriverName =
    {
      intel = if cfg.intel.legacyDriver then "i965" else "iHD";
      amd = "radeonsi";
      nvidia = "nvidia";
    }
    .${cfg.vendor};

  vaapiPackages =
    if cfg.vendor == "intel" then
      (if cfg.intel.legacyDriver then [ pkgs.intel-vaapi-driver ] else [ pkgs.intel-media-driver ])
      ++ optional cfg.intel.oneVPL pkgs.vpl-gpu-rt
    else if cfg.vendor == "amd" then
      # radeonsi_drv_video.so ships inside Mesa, which hardware.graphics already
      # installs. Nothing to add -- adding libva-vdpau-driver here would only
      # route you through the slower VDPAU shim.
      [ ]
    else
      [ (if cfg.nvenc.enable then cfg.nvenc.package else pkgs.nvidia-vaapi-driver) ];

  ##
  ## Chromium
  ##

  chromiumFeatures =
    optional cfg.encode "AcceleratedVideoEncoder"
    ++ optional cfg.chromium.forceDecode "AcceleratedVideoDecodeLinuxGL"
    ++ optional cfg.chromium.forceDecode "AcceleratedVideoDecodeLinuxZeroCopyGL"
    # Chromium hard-blocks VA-API on NVIDIA devices unless this is set. It has
    # no effect on other vendors, and on its own it does not make NVENC work --
    # see docs/nvenc.md.
    ++ optional (cfg.vendor == "nvidia") "VaapiOnNvidiaGPUs"
    # Repeating these is not redundant. Chromium does NOT merge duplicate
    # --enable-features switches -- base::CommandLine returns the LAST
    # occurrence -- and the nixpkgs wrappers emit their own earlier on the exec
    # line. Ours comes last, so anything the wrapper set and we do not repeat is
    # silently deleted.
    #
    # chromium emits: WaylandWindowDecorations
    # brave emits:    AcceleratedVideoDecodeLinuxGL, AcceleratedVideoEncoder,
    #                 WaylandWindowDecorations
    #
    # Brave is the cautionary case: omit its two and you strip the very video
    # acceleration you installed this module for.
    ++ optional cfg.chromium.preserveWaylandDecorations "WaylandWindowDecorations"
    ++ cfg.chromium.preserveFeatures
    ++ cfg.chromium.extraFeatures;

  chromiumFlags =
    # Highest-priority device override, checked before Chromium's active-GPU PCI
    # matching. Note this is NOT --render-node-override, which nearly every forum
    # post recommends: that switch is consulted later and loses. Chromium sets it
    # itself, to the active GPU, which on a hybrid box is the wrong node.
    optional (renderNode != null) "--hardware-video-device-path=${renderNode}"
    ++ optional (chromiumFeatures != [ ]) "--enable-features=${concatStringsSep "," chromiumFeatures}"
    ++ optional cfg.chromium.ignoreGpuBlocklist "--ignore-gpu-blocklist"
    # Measured, not assumed: this switch takes down the whole VA-API stack, not
    # decode alone. With it set, chrome://gpu reports zero encode entries. See
    # the assertion below -- decode = false and encode = true cannot both hold
    # on Chromium.
    ++ optional (!cfg.decode) "--disable-accelerated-video-decode"
    ++ cfg.chromium.extraFlags;

  chromiumPackage = cfg.chromium.package.override {
    commandLineArgs = concatStringsSep " " chromiumFlags;
  };

  ##
  ## Firefox
  ##

  firefoxPrefs = ''
    // Added by hardware.browserHwaccel. These are defaults, not locks -- you can
    // still flip them in about:config.
    pref("media.hardware-video-decoding.enabled", ${lib.boolToString cfg.decode});
    pref("media.hardware-video-encoding.enabled", ${lib.boolToString cfg.encode});
    ${lib.optionalString cfg.firefox.forceEnable ''
      // Bypass Firefox's own driver/codec blocklist. Needed on setups Mozilla has
      // not vetted, which includes every nvidia-vaapi-driver install.
      pref("media.hardware-video-decoding.force-enabled", ${lib.boolToString cfg.decode});
      pref("media.hardware-video-encoding.force-enabled", ${lib.boolToString cfg.encode});
    ''}
    ${cfg.firefox.extraPrefs}
  '';

  # Env vars are set on the Firefox wrapper only, never system-wide. Exporting
  # LIBVA_DRIVER_NAME globally is the single most common way people break a
  # working hybrid setup: it forces one driver onto every VA-API client on the
  # machine, including the ones that were picking correctly on their own.
  firefoxEnv =
    lib.optionalAttrs (renderNode != null) { MOZ_DRM_DEVICE = renderNode; }
    // lib.optionalAttrs cfg.firefox.forceVaDriver { LIBVA_DRIVER_NAME = vaDriverName; }
    // lib.optionalAttrs (cfg.vendor == "nvidia") { NVD_BACKEND = cfg.nvidia.backend; }
    // lib.optionalAttrs (cfg.vendor == "nvidia" && cfg.firefox.disableRddSandbox) {
      MOZ_DISABLE_RDD_SANDBOX = "1";
    }
    // cfg.firefox.extraEnv;

  firefoxWrapperArgs = lib.concatLists (
    lib.mapAttrsToList (name: value: [
      "--set"
      name
      value
    ]) firefoxEnv
  );

  firefoxPackage =
    let
      withPrefs = cfg.firefox.package.override { extraPrefs = firefoxPrefs; };
    in
    if firefoxWrapperArgs == [ ] then
      withPrefs
    else
      withPrefs.overrideAttrs (old: {
        makeWrapperArgs = (old.makeWrapperArgs or [ ]) ++ firefoxWrapperArgs;
      });

  wantsChromium = builtins.elem "chromium" cfg.browsers;
  wantsFirefox = builtins.elem "firefox" cfg.browsers;
in
{
  options.hardware.browserHwaccel = {
    enable = mkEnableOption "hardware video encode/decode for web browsers";

    vendor = mkOption {
      type = types.enum [
        "intel"
        "amd"
        "nvidia"
      ];
      example = "intel";
      description = ''
        Which GPU should do the video work. On a hybrid machine this is the card
        with the video engine you want used, which is often *not* the card
        driving your displays -- set {option}`pciAddress` as well in that case.

        There is deliberately no "auto": Nix evaluates on the build machine, and
        a build machine cannot see the target's PCI bus. Run
        `browser-hwaccel-check` to find out what you have.
      '';
    };

    pciAddress = mkOption {
      type = types.nullOr (
        types.strMatching "[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-9a-fA-F]"
      );
      default = null;
      example = "0000:00:02.0";
      description = ''
        PCI address of the GPU whose render node the browsers should open, as
        shown by `lspci -D`. Resolves to
        `/dev/dri/by-path/pci-''${pciAddress}-render`.

        Required on hybrid systems. On a single-GPU machine leave it null: both
        browsers find the only render node without help, and pinning a path you
        do not need is one more thing to break on a hardware change.
      '';
    };

    videoDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/dev/dri/renderD128";
      description = ''
        Escape hatch: use this exact render node path instead of deriving one
        from {option}`pciAddress`. Takes precedence when both are set.

        Prefer {option}`pciAddress`. `renderD*` numbering follows driver
        registration order and can change across boots and kernel updates.
      '';
    };

    browsers = mkOption {
      type = types.listOf (
        types.enum [
          "chromium"
          "firefox"
        ]
      );
      default = [
        "chromium"
        "firefox"
      ];
      description = ''
        Which browsers to configure and install. "chromium" covers any
        Chromium-based browser you build from {option}`chromium.package` --
        point it at `ungoogled-chromium`, `brave`, or `chromium` itself.
      '';
    };

    encode = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable hardware video *encode*. Still opt-in in both browsers.

        Encode only matters when your machine produces video: WebRTC calls,
        screen sharing, `MediaRecorder`, WebCodecs. It does nothing for ordinary
        playback -- that is decode.
      '';
    };

    decode = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable hardware video decode. On by default in recent Chromium under
        Wayland and in Firefox, so this mostly affects the Firefox prefs; see
        {option}`chromium.forceDecode` to force Chromium's flags on too.
      '';
    };

    intel = {
      legacyDriver = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use the old i965 driver (`intel-vaapi-driver`) instead of
          `intel-media-driver` (iHD). Needed for Broadwell and older
          (roughly pre-2015); iHD covers Skylake/Gen9 onward.
        '';
      };

      oneVPL = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Also install the oneVPL GPU runtime (`vpl-gpu-rt`). Not used by the
          browsers, but it is what ffmpeg and OBS want for QSV, and having both
          present costs nothing.
        '';
      };
    };

    nvidia = {
      backend = mkOption {
        type = types.enum [
          "direct"
          "egl"
        ];
        default = "direct";
        description = ''
          `NVD_BACKEND` for nvidia-vaapi-driver. "direct" is required when you
          are on the open kernel module (`nvidia-open`), and is the working
          default on recent drivers generally.
        '';
      };
    };

    nvenc = {
      enable = mkEnableOption ''
        the experimental NVENC-capable fork of nvidia-vaapi-driver.

        This replaces the stock driver system-wide and adds hardware *encode* on
        NVIDIA GPUs, which upstream does not have. It is a work in progress:
        H.264 and HEVC encode work and are pixel-verified, but packed headers and
        reference-frame management are not finished, so WebRTC simulcast/SVC will
        misbehave. Read docs/nvenc.md before switching this on'';

      src = mkOption {
        type = types.nullOr types.path;
        default = null;
        internal = true;
        description = "Source tree for the NVENC fork, injected by the flake.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../pkgs/nvidia-vaapi-driver-nvenc {
          src = cfg.nvenc.src;
        };
        defaultText = lib.literalMD "the fork pinned by this flake";
        description = "Package providing the NVENC-capable `nvidia_drv_video.so`.";
      };
    };

    chromium = {
      install = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Add the configured Chromium to {option}`environment.systemPackages`.
          Set false if you install it elsewhere (per-user via Home Manager, say)
          and read {option}`chromium.finalPackage` yourself.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.chromium;
        defaultText = lib.literalExpression "pkgs.chromium";
        example = lib.literalExpression "pkgs.ungoogled-chromium";
        description = ''
          Base Chromium-family package. Must accept `commandLineArgs` in its
          override arguments, which the nixpkgs chromium wrapper and its
          derivatives do.
        '';
      };

      finalPackage = mkOption {
        type = types.package;
        readOnly = true;
        description = "The Chromium package with acceleration flags applied.";
      };

      ignoreGpuBlocklist = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Pass `--ignore-gpu-blocklist`. Usually necessary, because a GPU that
          drives no display tends to be blocklisted on general principle.
        '';
      };

      forceDecode = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also pass the explicit VA-API decode feature flags. Normally
          unnecessary -- Chromium has defaulted decode on under Wayland since
          ~143 -- so try without it first. Only relevant on X11 or older builds.
        '';
      };

      preserveWaylandDecorations = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Re-add `WaylandWindowDecorations` to our `--enable-features` list.

          Keep this on. Chromium takes the *last* `--enable-features` switch on
          the command line rather than merging them, and the nixpkgs wrapper
          already passed one containing `WaylandWindowDecorations`. Dropping it
          here removes server-side window decorations under Wayland -- a
          confusing, seemingly unrelated regression.
        '';
      };

      preserveFeatures = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "AcceleratedVideoDecodeLinuxGL"
          "AcceleratedVideoEncoder"
        ];
        description = ''
          Feature names your browser's own wrapper already passes, which must be
          repeated here so they survive.

          Chromium takes the *last* `--enable-features` switch on the command
          line rather than merging them, and this module's switch comes last.
          Anything the packaged wrapper set and you do not repeat is silently
          dropped.

          **Brave needs this.** Its wrapper passes
          `AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder,WaylandWindowDecorations`,
          so leaving this empty removes Brave's own video acceleration. Set it to
          the first two (this module re-adds the third for you).

          Run `browser-hwaccel-check`; it inspects the built wrapper and reports
          any feature that gets clobbered.
        '';
      };

      extraFeatures = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "VaapiIgnoreDriverChecks" ];
        description = "Extra names to append to `--enable-features`.";
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "--enable-logging=stderr" ];
        description = "Extra command-line switches for Chromium.";
      };
    };

    firefox = {
      install = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Add the configured Firefox to {option}`environment.systemPackages`.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.firefox;
        defaultText = lib.literalExpression "pkgs.firefox";
        description = ''
          Firefox package. Must be a `wrapFirefox` result, so that `extraPrefs`
          is available in its override arguments.
        '';
      };

      finalPackage = mkOption {
        type = types.package;
        readOnly = true;
        description = "The Firefox package with prefs and environment applied.";
      };

      forceVaDriver = mkOption {
        type = types.bool;
        default = renderNode != null;
        defaultText = lib.literalMD "true when a render node is pinned";
        description = ''
          Set `LIBVA_DRIVER_NAME` on the Firefox wrapper.

          Only ever on the wrapper. libva normally picks the right driver from
          the DRM driver name of whichever node gets opened (`i915` to `iHD`),
          and forcing a name system-wide breaks every other VA-API client that
          was choosing correctly.
        '';
      };

      forceEnable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also set the `force-enabled` prefs, which bypass Firefox's internal
          driver blocklist. Required for nvidia-vaapi-driver; try without it on
          Intel and AMD, where the normal path usually just works.
        '';
      };

      disableRddSandbox = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Set `MOZ_DISABLE_RDD_SANDBOX=1` (NVIDIA only). nvidia-vaapi-driver
          needs device access the RDD sandbox denies, and without this Firefox
          falls back to software with no visible error.

          This genuinely weakens the sandbox around media decoding, which is
          exposed to hostile input from the network. It is the standard
          workaround and it is why the option exists rather than being implied.
        '';
      };

      extraPrefs = mkOption {
        type = types.lines;
        default = "";
        example = ''pref("media.ffmpeg.vaapi.force-surface-zero-copy", true);'';
        description = "Extra autoconfig lines appended to the Firefox prefs.";
      };

      extraEnv = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra environment variables for the Firefox wrapper.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.browsers != [ ];
        message = "hardware.browserHwaccel.browsers is empty; nothing to configure.";
      }
      {
        assertion = cfg.nvenc.enable -> cfg.vendor == "nvidia";
        message = "hardware.browserHwaccel.nvenc.enable requires vendor = \"nvidia\".";
      }
      {
        assertion = !(wantsChromium && cfg.encode && !cfg.decode);
        message = ''
          hardware.browserHwaccel: encode = true with decode = false is not
          achievable on Chromium.

          Disabling decode requires --disable-accelerated-video-decode, and that
          switch disables the entire VA-API stack -- measured on Chromium 152,
          chrome://gpu then lists no encode entries at all. There is no flag that
          keeps hardware encode while turning hardware decode off.

          Either accept hardware decode (decode = true), or drop Chromium from
          `browsers` and keep this combination for Firefox, where the two prefs
          are genuinely independent.
        '';
      }
      {
        assertion = !(cfg.videoDevice != null && cfg.pciAddress != null);
        message = ''
          Set only one of hardware.browserHwaccel.pciAddress or .videoDevice.
          pciAddress is the one you want unless you have a specific reason.
        '';
      }
    ];

    warnings =
      lib.optional (cfg.vendor == "nvidia" && !cfg.nvenc.enable && cfg.encode) ''
        hardware.browserHwaccel: encode is enabled with vendor = "nvidia", but the
        stock nvidia-vaapi-driver has no encode support at all -- it is a NVDEC
        wrapper. Encode will silently fall back to CPU. Either set decode-only
        (encode = false) or see docs/nvenc.md for the experimental fork.
      ''
      ++ lib.optional (cfg.vendor == "nvidia" && cfg.nvenc.enable) ''
        hardware.browserHwaccel: the NVENC fork is experimental and replaces
        nvidia-vaapi-driver system-wide. Reference-frame management and packed
        headers are unfinished; expect WebRTC simulcast to misbehave, and
        encode throughput is roughly 6x slower than software pending the
        zero-copy input path. See docs/nvenc.md.
      ''
      ++ lib.optional (renderNode != null && cfg.decode && wantsChromium) ''
        hardware.browserHwaccel: you have pinned a video device AND left
        hardware decode on. If the GPU you pinned is not the one driving your
        displays, decoded NV12 frames have to be imported across GPUs, and on at
        least one measured system that fails outright:

            gbm_bo_import -> "Cannot create bo with format=(Y_UV, 420, ...)"

        Chromium's GPU process then crashes, and after three crashes it disables
        accelerated video encode AND decode for the rest of the session. Run
        `browser-hwaccel-check` and read docs/hybrid-gpu.md before relying on
        this. Prefer putting video on the same GPU that drives your displays.
      '';

    hardware.graphics = {
      enable = true;
      enable32Bit = lib.mkDefault true;
      extraPackages = vaapiPackages;
    };

    hardware.browserHwaccel.chromium.finalPackage = chromiumPackage;
    hardware.browserHwaccel.firefox.finalPackage = firefoxPackage;

    environment.systemPackages = [
      # vainfo. Every diagnosis in docs/ starts here, so install it always.
      pkgs.libva-utils
      (pkgs.callPackage ../pkgs/browser-hwaccel-check { })
    ]
    ++ optionals (wantsChromium && cfg.chromium.install) [ chromiumPackage ]
    ++ optionals (wantsFirefox && cfg.firefox.install) [ firefoxPackage ];
  };
}
