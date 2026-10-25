{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (lib) mkOption mkIf types mkEnableOption;

  cfg = config.MODULES.virtualisation.docker-images-update;

  # Whatever backend the oci-containers module is set to - the repo runs docker
  # everywhere today, but the pull script should follow the setting, not assume it.
  backend = config.virtualisation.oci-containers.backend;
  backendCmd =
    if backend == "docker"
    then "${config.virtualisation.docker.package or pkgs.docker}/bin/docker"
    else "${config.virtualisation.podman.package or pkgs.podman}/bin/podman";

  # The unit oci-containers actually starts for a container: serviceName when set
  # (litellm.nix/omniroute.nix/trilium.nix pin theirs), docker-<name> otherwise
  # (fastdds.nix leaves it alone).
  containerUnit = name: c: c.serviceName or "docker-${name}";

  entries =
    lib.mapAttrsToList (name: c: {
      inherit name;
      image = c.image;
      unit = containerUnit name c;
    })
    config.virtualisation.oci-containers.containers;
in {
  options.MODULES.virtualisation.docker-images-update = {
    enable = mkEnableOption ''
      a nightly timer that pulls every image declared via
      virtualisation.oci-containers.containers, so unpinned tags (":latest" - omniroute)
      and version tags both stay fresh without a rebuild, and recreates a container only
      when its pull actually changed the image digest.
    '';

    startTime = mkOption {
      type = types.str;
      default = "04:15";
      example = "weekly 03:00";
      description = ''
        OnCalendar for the pull. Off the sanoid/znapzend :00/:20 snapshot window on
        purpose, and the container recreates (a few seconds of per-service downtime)
        land while nobody is looking at the dashboards.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = entries != [];
        message = ''
          MODULES.virtualisation.docker-images-update.enable is set but no host declares any
          virtualisation.oci-containers.containers - the timer would pull nothing forever.
        '';
      }
    ];

    systemd.services.docker-images-update = {
      description = "Pull updated OCI container images and recreate changed ones";
      # Wakes docker if a laptop/server came up without it; the timer runs hours after
      # boot, so this is insurance, not a boot dependency.
      requires = ["${backend}.service" "network-online.target"];
      after = ["${backend}.service" "network-online.target"];
      path = [
        backendCmd
        config.systemd.package
        pkgs.coreutils
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      # Per image: digest before, pull, digest after; restart only on change (and only
      # if the image was already present - an absent image means the unit will start it
      # anyway, and a pull failure (registry hiccup, rate limit) must never take a
      # running container away, hence `|| true` around the pull and the absent guard.
      script = ''
        for e in ${lib.concatStringsSep " " (map (e: "'${e.image}|${e.unit}'") entries)}; do
          image=''${e%%|*}
          unit=''${e#*|}
          before=$(${backendCmd} image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo absent)
          if ! ${backendCmd} pull "$image"; then
            echo "pull failed for $image (keeping current)" >&2
            continue
          fi
          after=$(${backendCmd} image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo absent)
          if [ "$before" != "$after" ]; then
            if [ "$before" = absent ]; then
              echo "$image updated; nothing running to recreate"
            else
              echo "$image updated ($before -> $after); restarting $unit"
              systemctl restart "$unit"
            fi
          fi
        done
      '';
    };

    systemd.timers.docker-images-update = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.startTime;
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
    };
  };
}
