{
  description = "BinaryBlaze ComfyUI services (flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream ComfyUI source (non-flake)
    comfyui = {
      url = "github:comfyanonymous/ComfyUI";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, comfyui, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in
  {
    nixosModules.default = { lib, pkgs, ... }: {
      imports = [ ./modules/comfy-containers.nix ];

      # Provide defaults at the module boundary so host configs stay clean.
      services.comfyContainers.defaults = {
        # This is a *path* in the Nix store pointing to the fetched upstream tree.
        comfyuiSrc = comfyui;
        baseStateDir = "/var/lib/comfyui";
      };
    };

    # Optional: expose upstream source as a package (useful for inspection/debugging)
    packages = forAllSystems (system: {
      upstream-src = comfyui;
    });
  };
}

