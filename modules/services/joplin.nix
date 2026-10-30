{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkAfter mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.joplin;
  hermesModule = config.MODULES.services.hermes-agent;
  hermes = config.services.hermes-agent;

  dataDir = "/var/lib/joplin";
  # PUID/PGID (+ the basic-auth password when webUser is set), rewritten by the ExecStartPre
  # below right before every `docker run` (the oci-containers unit runs `docker run`, not
  # `docker start`, so the file is re-read on every start/restart).
  envFile = "${dataDir}/container.env";

  authOn = cfg.webUser != null;

  containerEnvScript = pkgs.writeShellScript "joplin-container-env" ''
    set -eu
    ${
      lib.optionalString authOn ''
        pw=""
        if [ -s ${envFile} ]; then
          pw=$(${pkgs.gnused}/bin/sed -n 's/^PASSWORD=//p' ${envFile} | ${pkgs.coreutils}/bin/head -n1)
        fi
        if [ -z "$pw" ]; then
          pw=$(${pkgs.openssl}/bin/openssl rand -hex 12)
        fi
      ''
    }
    # The ids resolve HERE, at unit start: hermes is a system user whose numeric ids nixpkgs
    # allocates at activation, so they are not knowable at eval time. Re-resolved on every
    # start, so a uid churn is never baked into a running container. The password (auth on)
    # is carried over from the previous file - the browser login depends on it staying put;
    # delete the PASSWORD line (or the file) to roll it, or set webUser back to a string to
    # turn auth on again (writing this file without the line is what switches auth off).
    {
      echo "PUID=$(${pkgs.coreutils}/bin/id -u ${hermes.user})"
      echo "PGID=$(${pkgs.coreutils}/bin/id -g ${hermes.user})"
      ${lib.optionalString authOn "echo \"PASSWORD=$pw\""}
    } > ${envFile}
    ${pkgs.coreutils}/bin/chmod 0400 ${envFile}
  '';
in {
  options.MODULES.services.joplin = {
    enable = mkEnableOption ''
      Joplin as the sibling note app to compare against Trilium: the DESKTOP client streamed to
      the browser (lscr.io/linuxserver/joplin, a Selkies single-app container), at
      https://joplin.<host> on the tailnet (loopback container behind Traefik, like trilium.nix;
      nginx's HTTP listener is the proxied one, exactly as the image intends). Where Hermes
      reaches Trilium through ETAPI, it reaches Joplin through FILES: the notes sync as plain
      markdown into syncDir inside Hermes' own state dir, written by a container that drops to
      the hermes uid. The image is amd64-only.
    '';

    image = mkOption {
      type = types.str;
      default = "lscr.io/linuxserver/joplin:v3.7.21-ls73";
      description = ''
        Container image, pinned to the latest release at the time of writing (the -lsNN suffix is
        LSIO's own build revision; the leading part is the Joplin desktop version). LSIO mirrors
        its GitHub release tags verbatim, v prefix included - `3.7.21-ls73` without the v is
        `manifest unknown` (hp, 2026-10-27 first boot). Bumping the tag is the upgrade path; the
        nightly docker-images-update timer only ever pulls this same tag, so the app updates
        exactly when a rebuild says it does.
      '';
    };

    syncDir = mkOption {
      type = types.str;
      default = "${hermes.stateDir}/joplin";
      description = ''
        Where Joplin keeps the notes as plain markdown (one .md per note in notebook folders,
        attachments under .resource/) - and where Hermes reads and writes them directly. It lives
        inside the hermes state dir on purpose: Hermes' sandbox already bind-mounts that tree
        rw (hermes-agent.nix), and the container runs as PUID/PGID = exactly that uid, so every
        file carries both sides as OWNER - no group tricks, no `hermes-notes-edit grant`, no
        chmod pass (the syncthing share in hermes-agent.nix needs all of those because its files
        belong to a foreign uid; these belong to hermes).

        One-time manual step, because the sync target is a Joplin preference and the image takes
        no env var for it: open https://joplin.<host> (login only if webUser is set - user
        webUser, password `sudo cat /var/lib/joplin/container.env`), then Options -> Sync ->
        Sync target "File system", path = the containerSyncPath value, and Synchronise. Until
        then the container serves an empty desktop.

        Hermes' side of the comparison, honestly: this is a SYNCED copy, not a live view. Agent
        writes land in the app on the NEXT sync (auto-sync is off by default; enable it in the
        same options page), and Joplin owns the folder the way syncthing users use it - whole
        files, last-write-wins. Trilium's ETAPI round-trips are live; file edits are batch.
      '';
    };

    containerSyncPath = mkOption {
      type = types.str;
      default = "/joplin-sync";
      description = ''
        Where syncDir is mounted inside the container - the path to type into Joplin's sync
        dialog. Deliberately NOT under /config: the image's init owns that tree's permissions,
        and the notes should outlive it as their own bind.
      '';
    };

    webUser = mkOption {
      type = types.nullOr types.str;
      default = "akos";
      example = null;
      description = ''
        Username for the container's nginx basic auth. null removes it entirely: the image
        switches auth on only by the presence of PASSWORD, so a null here means no
        CUSTOM_USER, no generated password, and a bare streamed desktop for anything that
        can reach <host>:8132 - which the firewall limits to this machine plus the tailnet.
        Accepted on hp 2026-10-27 (every tailnet peer is the owner's own device); weigh it
        again before copying to a shared tail: Joplin plugins are code execution as the
        hermes uid inside the host's network namespace, and the container's own
        terminal/sudo lockdown does not apply to them.
      '';
    };

    driDevice = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/dev/dri";
      description = ''
        A DRI device tree to hand the container, enabling its zero-copy GPU path: the Selkies
        baseimage AUTO_GPU-detects a mounted render node and moves BOTH rendering (EGL) and the
        stream encoding (VA-API) onto it. Left null because whether a host's render node can
        encode is a hardware fact the flake cannot see at eval time, and a missing device would
        fail the unit at activation - hosts with an encode-capable card name it (hp's amdgpu
        W6400 since 2026-10-27; without it the stream was software x264 on the LIMITS cpu
        quota, which the user felt as a laggy browser within a day). Software capture without a
        node also does full readback per frame, so this is the whole experience, not a tuning.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = hermesModule.enable;
        message = ''
          MODULES.services.joplin exists to hand its notes to Hermes as files: the container
          writes as the hermes uid and syncDir lives inside the hermes state dir. Enable
          MODULES.services.hermes-agent on this host (or don't run Joplin here).
        '';
      }
    ];

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 root root - -"
      # Owned by hermes to match the container's PUID/PGID and Hermes' own uid; the setgid bit
      # only matters for stray root-created files, everything that counts is owner-writable by
      # both parties already.
      "d ${cfg.syncDir} 2775 ${hermes.user} ${hermes.group} - -"
    ];

    virtualisation.oci-containers.containers.joplin = {
      inherit (cfg) image;
      # Keeps the unit at joplin.service, like litellm.nix, omniroute.nix and trilium.nix.
      serviceName = "joplin";

      volumes = [
        # The desktop's whole profile (its sqlite, settings, cache) - the thing to keep, per
        # LSIO. PUID's chown of this tree on container start is expected and re-fixed by the
        # tmpfiles rule above; the container's init re-chowns again at the next start.
        "${dataDir}:/config"
        "${cfg.syncDir}:${cfg.containerSyncPath}"
      ];

      # AUTO_GPU in the image's init takes rendering AND the stream encoder onto the card,
      # which is the difference between a notes app and a slideshow (see driDevice).
      devices = lib.optionals (cfg.driDevice != null) [cfg.driDevice];

      environment =
        {
          # The image's nginx owns all three listeners and binds them on every interface; with
          # --network=host these are this host's ports, hence a PORTS entry each (the firewall
          # opens none, and the selkies server behind nginx binds loopback by itself -
          # SELKIES_PUBLIC defaults to false). Traefik proxies the HTTP one, which the image
          # documents as "exists only to sit behind a reverse proxy".
          CUSTOM_PORT = toString config.PORTS.joplin;
          CUSTOM_HTTPS_PORT = toString config.PORTS.joplinTls;
          CUSTOM_WS_PORT = toString config.PORTS.joplinStream;
          # The streamed GUI ships a right-click terminal with passwordless sudo and share links
          # that carry no auth of their own. A notes viewer needs neither, and they are the
          # difference between "can read the notes" and "root inside the box that holds them"
          # for anyone who can reach the page. File transfers stay on: that is the web client's
          # drag-and-drop import.
          DISABLE_TERMINALS = "true";
          DISABLE_SUDO = "true";
          DISABLE_OPEN_TOOLS = "true";
          SELKIES_ENABLE_SHARING = "false";
          TITLE = "Joplin";
        }
        // lib.optionalAttrs authOn {
          # PASSWORD - the variable whose mere presence switches nginx auth on - lives in
          # container.env, not here (it must not appear in the world-readable unit file).
          CUSTOM_USER = cfg.webUser;
        };

      environmentFiles = [envFile];

      # Host networking like omniroute.nix/trilium.nix (loopback bind needs no published port).
      # No --user here: the s6 init must run as root to create the app user, and then drops
      # itself to PUID/PGID (the hermes uid, see containerEnvScript) for everything that
      # touches the bind mounts.
      extraOptions = [
        "--network=host"
        # Electron's chromium dies on docker's 64M /dev/shm default (and the streamed session's
        # encoder lives here too); 512M rides inside the same cgroup as the LIMITS row.
        "--shm-size=512m"
      ];
    };

    # mkAfter puts this behind the module's own pre-start; ExecStartPre runs before the unit's
    # `docker run`, so the file exists (with its password) on the very first start.
    systemd.services.joplin.serviceConfig.ExecStartPre = mkAfter ["+${containerEnvScript}"];

    MODULES.networking.traefik.enable = true;
    # WebSockets ride the same hop (the stream is one proxied location; Traefik's read timeouts
    # default to off, and the selkies server's are 3600s).
    MODULES.networking.traefik.services.joplin = "127.0.0.1:${toString config.PORTS.joplin}";
  };
}
