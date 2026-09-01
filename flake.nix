{
  description = "Hardware video encode and decode for Chromium and Firefox on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The experimental NVENC-capable fork of nvidia-vaapi-driver. Only fetched
    # when hardware.browserHwaccel.nvenc.enable is set; see docs/nvenc.md.
    nvidia-vaapi-driver-nvenc = {
      url = "github:ejb1123/nvidia-vaapi-driver/nvenc-encode";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nvidia-vaapi-driver-nvenc,
    }:
    let
      # Aliased because `packages` below is a `rec` whose attribute of the same
      # name would otherwise shadow this input.
      nvencSrc = nvidia-vaapi-driver-nvenc;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.default = {
        imports = [ ./modules/browser-hwaccel.nix ];
        # Make the pinned fork source available to the module without the module
        # itself needing flake plumbing.
        hardware.browserHwaccel.nvenc.src = nixpkgs.lib.mkDefault nvencSrc;
      };
      nixosModules.browser-hwaccel = self.nixosModules.default;

      overlays.default = final: prev: {
        browser-hwaccel-check = final.callPackage ./pkgs/browser-hwaccel-check { };
        nvidia-vaapi-driver-nvenc = final.callPackage ./pkgs/nvidia-vaapi-driver-nvenc {
          src = nvencSrc;
        };
      };

      packages = forAllSystems (pkgs: rec {
        browser-hwaccel-check = pkgs.callPackage ./pkgs/browser-hwaccel-check { };
        nvidia-vaapi-driver-nvenc = pkgs.callPackage ./pkgs/nvidia-vaapi-driver-nvenc {
          src = nvencSrc;
        };
        default = browser-hwaccel-check;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            libva-utils
            nixfmt-rfc-style
            shellcheck
            pciutils
          ];
        };
      });

      # `nix flake check` evaluates the module against every example, so a broken
      # option or a typo in a package name fails CI rather than someone's rebuild.
      #
      # Evaluation only. Discarding the string context on drvPath forces the whole
      # config to evaluate without pulling a full NixOS system into the build --
      # otherwise `nix flake check` would compile a browser four times.
      checks = forAllSystems (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
          evalExample =
            name: module:
            let
              sys = nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.default
                  module
                  (
                    { lib, ... }:
                    {
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "/dev/null";
                        fsType = "ext4";
                      };
                      system.stateVersion = lib.trivial.release;
                    }
                  )
                ];
              };
            in
            pkgs.runCommand "eval-${name}" { } ''
              echo ${builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath} > $out
            '';
        in
        nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          example-intel = evalExample "intel" ./examples/intel-igpu.nix;
          example-hybrid = evalExample "hybrid" ./examples/hybrid-intel-nvidia.nix;
          example-amd = evalExample "amd" ./examples/amd.nix;
          example-nvidia = evalExample "nvidia" ./examples/nvidia.nix;
          example-nvidia-nvenc = evalExample "nvidia-nvenc" ./examples/nvidia-nvenc.nix;
        }
        // {
          inherit (self.packages.${system}) browser-hwaccel-check;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
