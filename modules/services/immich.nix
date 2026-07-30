{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.MODULES.services.immich;

  # Same absolute "path"s as legion5's dcim/Pictures shares (MODULES.services.syncthing.shares
  # folders are peer-matched by this path, see modules/services/syncthing.nix), but kept out of
  # Immich's own `mediaLocation` and stored under dedicated directories on this host - phone photos
  # arrive here as plain synced files, to be added as Immich External Libraries, rather than being
  # mixed into storage Immich manages itself.
  dcimLibraries = [
    {
      name = "dcim";
      path = "/home/akos/Pictures/dcim";
      overridePath = "/var/lib/immich-dcim";
    }
    {
      # The whole of legion5's ~/Pictures (dcim excluded, see legion5's share for why) - this is
      # where photos end up once moved out of dcim to get them off the phone for good, but it also
      # picks up anything else dropped into ~/Pictures on legion5.
      name = "Pictures";
      path = "/home/akos/Pictures";
      overridePath = "/var/lib/immich-pictures";
    }
  ];

  apiUrl = "http://127.0.0.1:${toString config.PORTS.immich}/api";
  apiKeyPath = config.sops.secrets."immich/api-key".path;
in {
  options.MODULES.services.immich.enable = mkEnableOption "Immich photo and video backup";

  config = mkIf cfg.enable {
    services.immich = {
      enable = true;
      host = "127.0.0.1";
      port = config.PORTS.immich;
    };

    # Sync the phone's camera roll and the rest of legion5's ~/Pictures (shared from legion5 as
    # "dcim" and "Pictures") here too, so they can be browsed in Immich as External Libraries -
    # immich-ensure-libraries below creates/updates them automatically, since the NixOS module
    # itself has no option for it.
    MODULES.services.syncthing.shares =
      map (l: {
        inherit (l) path;
        override_path = l.overridePath;
        copyOwnershipFromParent = true;
      })
      dcimLibraries;

    # Syncthing's own umask (0077) means files it writes are readable only by the user it runs
    # as - run it as the immich user/group so the Immich service (which runs hardened with
    # ProtectHome=true and can't see /home at all) can actually read what lands in the library
    # paths above.
    MODULES.services.syncthing.user = config.services.immich.user;
    MODULES.services.syncthing.group = config.services.immich.group;

    # copyOwnershipFromParent only takes effect if a library path already exists owned by the
    # immich user/group - Syncthing itself won't create it with the right ownership.
    systemd.tmpfiles.rules =
      map (l: "d ${l.overridePath} 0750 ${config.services.immich.user} ${config.services.immich.group} - -") dcimLibraries;

    # Immich's mobile/desktop clients talk to the API at the server root, so it can't be
    # reverse-proxied under a Traefik subpath like the other services - give it its own
    # Tailscale-served HTTPS port instead, forwarding straight to the local backend.
    MODULES.networking.tailscale.serve.immich = {
      target = "http://127.0.0.1:${toString config.PORTS.immich}";
      httpsPort = config.PORTS.immich;
    };

    # Immich has no admin-account bootstrap and no NixOS option for External Libraries, so this
    # key has to be created once by hand (Account Settings -> API Keys, needs the "library" scope)
    # after the very first admin account is created through the web UI - everything downstream of
    # that (creating/updating the libraries below on every deploy) is handled by
    # immich-ensure-libraries instead of the manual Administration > External Libraries UI flow.
    sops.secrets."immich/api-key" = {
      owner = config.services.immich.user;
      group = config.services.immich.group;
      mode = "0400";
      restartUnits = ["immich-ensure-libraries.service"];
    };

    systemd.services.immich-ensure-libraries = {
      description = "Ensure Immich External Libraries exist for the synced photo folders";
      after = ["immich-server.service"];
      requires = ["immich-server.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.curl pkgs.jq];
      serviceConfig = {
        Type = "oneshot";
        User = config.services.immich.user;
        Group = config.services.immich.group;
      };
      script = ''
        set -euo pipefail

        api_key="$(cat ${apiKeyPath})"
        auth=(-H "x-api-key: $api_key")

        # immich-server.service being "active" only means the process has started, not that the
        # HTTP API is accepting requests yet - poll until it actually answers.
        for _ in $(seq 1 60); do
          curl -sf -o /dev/null "''${auth[@]}" "${apiUrl}/server/ping" && break
          sleep 2
        done

        owner_id="$(curl -sf "''${auth[@]}" "${apiUrl}/users/me" | jq -r .id)"

        ${lib.concatMapStringsSep "\n\n" (l: ''
            existing_id="$(curl -sf "''${auth[@]}" "${apiUrl}/libraries" \
              | jq -r '.[] | select(.name == "${l.name}") | .id')"
            if [ -z "$existing_id" ]; then
              payload="$(jq -n --arg ownerId "$owner_id" --arg path "${l.overridePath}" \
                '{ownerId: $ownerId, name: "${l.name}", importPaths: [$path]}')"
              curl -sf "''${auth[@]}" -H "Content-Type: application/json" \
                -d "$payload" "${apiUrl}/libraries" >/dev/null
              echo "created Immich library ${l.name}"
            else
              payload="$(jq -n --arg path "${l.overridePath}" '{importPaths: [$path]}')"
              curl -sf -X PUT "''${auth[@]}" -H "Content-Type: application/json" \
                -d "$payload" "${apiUrl}/libraries/$existing_id" >/dev/null
              echo "updated Immich library ${l.name}"
            fi
          '')
          dcimLibraries}
      '';
    };
  };
}
