{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkEnableOption mkIf mkOption types mkMerge mapAttrsToList optionalString;

  cfg = config.services.comfyContainers;

  # Copy upstream source into a writable directory, but do NOT overwrite
  # custom_nodes/ or user/ (these are typically mutated by ComfyUI-Manager).
  mkStageScript = name: c: pkgs.writeShellScript "stage-comfyui-${name}" ''
    set -euo pipefail

    mkdir -p "${c.stateDir}"

    # If first run, seed the working tree from Nix-fetched upstream.
    if [ ! -e "${c.comfyuiPath}/main.py" ]; then
      echo "[comfyui:${name}] seeding ${c.comfyuiPath} from ${c.comfyuiSrc}"
      mkdir -p "${c.comfyuiPath}"
      cp -R --no-preserve=mode,ownership "${c.comfyuiSrc}/." "${c.comfyuiPath}/"
    fi

    # Optional: refresh safe paths on rebuild (keeps your tree close to upstream)
    if [ "${if c.refreshOnRebuild then "1" else "0"}" = "1" ]; then
      echo "[comfyui:${name}] refreshOnRebuild enabled; syncing safe upstream paths"

      # rsync is ideal; fallback to cp if needed
      if command -v ${pkgs.rsync}/bin/rsync >/dev/null 2>&1; then
        ${pkgs.rsync}/bin/rsync -a --delete \
          --exclude 'custom_nodes/' \
          --exclude 'user/' \
          --exclude 'models/' \
          --exclude 'input/' \
          --exclude 'output/' \
          "${c.comfyuiSrc}/" "${c.comfyuiPath}/"
      else
        echo "[comfyui:${name}] rsync not found; skipping refresh"
      fi
    fi
  '';

  mkComfyService = name: c: {
    systemd.services."comfyui-${name}" = {
      description = "ComfyUI (${name})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = c.user;
        WorkingDirectory = c.comfyuiPath;
        Restart = "on-failure";
        RestartSec = 3;
        EnvironmentFile = lib.mkIf (c.environmentFile != null) c.environmentFile;

        ExecStart = pkgs.writeShellScript "start-comfyui-${name}" ''
          set -euo pipefail

          ${mkStageScript name c}

          export CUDA_HOME="${c.cudaHome}"
          export LD_LIBRARY_PATH="${c.openglLibPath}:$LD_LIBRARY_PATH"

          eval "$(${pkgs.micromamba}/bin/micromamba shell hook -s bash)"
          micromamba activate "${c.mambaEnv}"

          mkdir -p "${c.sharedModels}" "${c.sharedInput}" "${c.sharedOutput}" "${c.sharedWorkflows}"

          ${optionalString c.ensureSymlinks ''
            ln -sfn "${c.sharedModels}" "${c.comfyuiPath}/models"
            ln -sfn "${c.sharedInput}"  "${c.comfyuiPath}/input"
            ln -sfn "${c.sharedOutput}" "${c.comfyuiPath}/output"
            mkdir -p "${c.comfyuiPath}/user/default"
            ln -sfn "${c.sharedWorkflows}" "${c.comfyuiPath}/user/default/workflows"
          ''}

          ${optionalString (c.preStart != "") c.preStart}

          exec python main.py \
            --listen ${c.listen} \
            --port ${toString c.port} \
            ${lib.escapeShellArgs c.extraArgs}
        '';
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf c.openFirewall [ c.port ];

    services.nginx = lib.mkIf c.reverseProxy.enable {
      enable = true;
      virtualHosts."${c.reverseProxy.hostName}" = {
        forceSSL = c.reverseProxy.forceSSL;
        enableACME = c.reverseProxy.acme;
        locations."${c.reverseProxy.path}" = {
          proxyPass = "http://127.0.0.1:${toString c.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            client_max_body_size 0;
          '';
        };
      };
    };
  };

in {
  options.services.comfyContainers = {
    enable = mkEnableOption "Enable ComfyUI instances";

    defaults = {
      user = mkOption { type = types.str; default = "jsampson"; };
      cudaHome = mkOption { type = types.str; default = "/run/opengl-driver"; };
      openglLibPath = mkOption { type = types.str; default = "/run/opengl-driver/lib"; };

      # NEW: upstream source path (from flake boundary)
      comfyuiSrc = mkOption { type = types.path; };

      # NEW: where per-instance working dirs live
      baseStateDir = mkOption { type = types.str; default = "/var/lib/comfyui"; };

      sharedModels = mkOption { type = types.str; default = "/home/jsampson/ComfyUI/models"; };
      sharedInput = mkOption { type = types.str; default = "/home/jsampson/ComfyUI/input"; };
      sharedOutput = mkOption { type = types.str; default = "/home/jsampson/ComfyUI/output"; };
      sharedWorkflows = mkOption { type = types.str; default = "/home/jsampson/ComfyUI/workflows"; };

      ensureSymlinks = mkOption { type = types.bool; default = true; };

      listen = mkOption { type = types.str; default = "127.0.0.1"; };
      port = mkOption { type = types.int; default = 8188; };
      openFirewall = mkOption { type = types.bool; default = false; };

      extraArgs = mkOption { type = types.listOf types.str; default = [ ]; };

      environmentFile = mkOption { type = types.nullOr types.str; default = null; };
      preStart = mkOption { type = types.str; default = ""; };
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          enable = mkEnableOption "Enable this ComfyUI instance";

          user = mkOption { type = types.str; default = cfg.defaults.user; };
          mambaEnv = mkOption { type = types.str; default = "comfyui-01"; };

          # NEW: writable state dir and comfyui working tree derived from it
          stateDir = mkOption {
            type = types.str;
            default = "${cfg.defaults.baseStateDir}/${name}";
          };

          comfyuiSrc = mkOption { type = types.path; default = cfg.defaults.comfyuiSrc; };

          comfyuiPath = mkOption {
            type = types.str;
            default = "${config.services.comfyContainers.instances.${name}.stateDir}/ComfyUI";
          };

          refreshOnRebuild = mkOption {
            type = types.bool;
            default = false;
            description = "If true, sync safe upstream paths on rebuild (excluding custom_nodes/user/models/input/output).";
          };

          cudaHome = mkOption { type = types.str; default = cfg.defaults.cudaHome; };
          openglLibPath = mkOption { type = types.str; default = cfg.defaults.openglLibPath; };

          sharedModels = mkOption { type = types.str; default = cfg.defaults.sharedModels; };
          sharedInput = mkOption { type = types.str; default = cfg.defaults.sharedInput; };
          sharedOutput = mkOption { type = types.str; default = cfg.defaults.sharedOutput; };
          sharedWorkflows = mkOption { type = types.str; default = cfg.defaults.sharedWorkflows; };
          ensureSymlinks = mkOption { type = types.bool; default = cfg.defaults.ensureSymlinks; };

          listen = mkOption { type = types.str; default = cfg.defaults.listen; };
          port = mkOption { type = types.int; default = cfg.defaults.port; };
          openFirewall = mkOption { type = types.bool; default = cfg.defaults.openFirewall; };

          extraArgs = mkOption { type = types.listOf types.str; default = cfg.defaults.extraArgs; };

          environmentFile = mkOption { type = types.nullOr types.str; default = cfg.defaults.environmentFile; };
          preStart = mkOption { type = types.str; default = cfg.defaults.preStart; };

          reverseProxy = mkOption {
            type = types.submodule {
              options = {
                enable = mkOption { type = types.bool; default = false; };
                hostName = mkOption { type = types.str; default = "comfyui.local"; };
                path = mkOption { type = types.str; default = "/"; };
                forceSSL = mkOption { type = types.bool; default = true; };
                acme = mkOption { type = types.bool; default = false; };
              };
            };
            default = { };
          };
        };
      }));
      default = { };
    };
  };

  config = mkIf cfg.enable (mkMerge (
    mapAttrsToList (name: c: mkIf c.enable (mkComfyService name c)) cfg.instances
  ));
}

