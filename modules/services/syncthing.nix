{
  config,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.syncthing;

  # Devices not managed by this flake (e.g. phones), known by a short name so shares can
  # reference them as e.g. `extra_devices = [ "phone" ];` instead of repeating the raw ID
  # everywhere. Every host registers all of these as known devices regardless of whether it
  # actually shares a folder with them - which folders they can access is still controlled by
  # each share's own `extra_devices` list.
  knownExtraDevices = {
    phone = {
      id = "FFN5JPO-A6HOB7Z-YHKKFVG-YOVO5QD-HLXXIBQ-743QUQI-53REPOE-LGLFWQQ";
      name = "Phone";
      addresses = ["tcp://phone.${config.MODULES.networking.tailscale.tailnetDnsName}:${toString config.PORTS.syncthingSync}"];
    };
  };

  extraDeviceSubmodule = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Syncthing device ID of a device that isn't managed by this flake (e.g. a phone).";
      };

      addresses = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Addresses to reach this device at (e.g. "tcp://100.x.x.x:22000"). Since discovery is
          disabled, leaving this empty means Syncthing has no way to find the device.
        '';
      };

      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Display name for this device in the Syncthing GUI. Leave null to fall back to an
          auto-generated placeholder based on the device ID.
        '';
      };
    };
  };

  extraDeviceType =
    types.coercedTo types.str (
      s:
        if builtins.hasAttr s knownExtraDevices
        then knownExtraDevices.${s}
        else {
          id = s;
          addresses = [];
        }
    )
    extraDeviceSubmodule;

  shareSubmodule = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        description = "Absolute path of the directory to sync.";
      };

      extra_devices = mkOption {
        type = types.listOf extraDeviceType;
        default = [];
        description = "Devices not managed by this flake that this folder should also be shared with.";
      };

      override_path = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Store this folder at a different absolute path on this one machine, instead of at
          `path`. `path` still identifies the folder (peer matching, folder ID/label) - only the
          on-disk location changes here, for machines that need this share mounted somewhere
          other than the path every other host agrees on.
        '';
      };

      copyOwnershipFromParent = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Passed straight through to Syncthing's own `copyOwnershipFromParent` folder setting:
          new files/directories it writes inherit ownership from this folder's own directory
          instead of staying owned by whichever user runs Syncthing (see the top-level `user`
          option). Requires the directory to already be owned by the intended user.
        '';
      };

      ignorePatterns = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          Passed straight through to Syncthing's own `ignorePatterns` folder setting: a list of
          ignore patterns (see <https://docs.syncthing.net/users/ignoring.html>). Leave null to
          manage ignores via the WebUI instead.
        '';
      };
    };
  };

  shareType =
    types.coercedTo types.str (path: {
      inherit path;
      extra_devices = [];
    })
    shareSubmodule;

  # every host defined in the flake, so folders/devices can be wired up automatically
  allHostNames = builtins.attrNames nixosConfigurations;
  hostConfig = host: nixosConfigurations.${host}.config;
  hostSyncthing = host: (hostConfig host).MODULES.services.syncthing;

  hostAddress = host: let
    ip = (hostConfig host).MODULES.networking.tailscale.hostIP or null;
  in
    if ip == null
    then "dynamic"
    else "tcp://${ip}:${toString config.PORTS.syncthingSync}";

  # other hosts in the flake that have syncthing enabled and a known device ID
  peerHosts =
    builtins.filter (
      host:
        host
        != configName
        && (hostSyncthing host).enable
        && (hostSyncthing host).deviceID != ""
    )
    allHostNames;

  peerDevices = builtins.listToAttrs (map (host: {
      name = host;
      value = {
        id = (hostSyncthing host).deviceID;
        addresses = [(hostAddress host)];
      };
    })
    peerHosts);

  extraDeviceName = id: "extra-${builtins.substring 0 7 id}";

  # every host registers all knownExtraDevices regardless of whether any of its own shares
  # reference them, so e.g. the phone is a reachable/connectable device everywhere - actual
  # folder access is still only granted via a share's own extra_devices list.
  allExtraDevices = lib.unique (lib.flatten (map (share: share.extra_devices) cfg.shares) ++ builtins.attrValues knownExtraDevices);

  extraDevices = builtins.listToAttrs (map (d: {
      name = extraDeviceName d.id;
      value =
        {
          id = d.id;
          addresses = d.addresses;
        }
        // lib.optionalAttrs (d.name != null) {inherit (d) name;};
    })
    allExtraDevices);

  folders = builtins.listToAttrs (map (share: {
      name = share.path;
      value = {
        path =
          if share.override_path != null
          then share.override_path
          else share.path;
        devices =
          (builtins.filter (host: builtins.elem share.path (map (s: s.path) (hostSyncthing host).shares)) peerHosts)
          ++ (map (d: extraDeviceName d.id) share.extra_devices);
        inherit (share) copyOwnershipFromParent ignorePatterns;
      };
    })
    cfg.shares);

  sharePaths = map (s: s.path) cfg.shares;

  overridePaths = builtins.filter (p: p != null) (map (s: s.override_path) cfg.shares);
in {
  options.MODULES.services.syncthing = {
    enable = mkOption {
      type = types.bool;
      default = cfg.shares != [];
      defaultText = lib.literalExpression "config.MODULES.services.syncthing.shares != []";
      description = ''
        Whether to enable Syncthing folder sync. Defaults to on as soon as any `shares` are
        defined, so you only need to set `shares` - set this to `false` explicitly to define
        shares without actually running the service.
      '';
    };

    deviceID = mkOption {
      type = types.str;
      default = "";
      description = ''
        This machine's Syncthing device ID, used by other machines in the flake to add it as a
        peer. Unknown before the first deploy: leave empty, deploy (enabled automatically once
        `shares` is non-empty), then read the ID from the GUI (Actions -> Show ID on
        https://syncthing.<host>) and set it here. Redeploy (this machine and any peers) once
        it's filled in.
      '';
    };

    shares = mkOption {
      type = types.listOf shareType;
      default = [];
      description = ''
        Directories to share via Syncthing. Either a plain absolute path, or an attrset of the
        form { path = "/abs/path"; extra_devices = [ ... ]; }.

        Any other machine in the flake that lists the same absolute path is automatically added
        as a peer for that folder - no manual device wiring required.
      '';
      example = [
        "/srv/shared/photos"
        {
          path = "/srv/shared/notes";
          extra_devices = ["AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"];
        }
      ];
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Unix user to run the Syncthing service as, when it needs to read/write shares owned by
        someone other than the default `syncthing` system user (e.g. a share under a real user's
        home directory). Leave null to use Syncthing's own default ("syncthing").

        Note this is a single setting for the whole Syncthing instance, not per-share: Syncthing
        is one process with one uid, and NixOS's syncthing module hardens it with
        `PrivateUsers = true`, which maps *only* uid 0 and this configured user to themselves -
        every other uid (including root's own "root" identity, if this isn't set to "root")
        becomes inaccessible regardless of file permissions. Running as "root" does **not** grant
        access to arbitrary other users' files under this hardening; set this to the actual owner
        of the shares instead.
      '';
    };

    group = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Unix group to pair with `user`. Leave null to use Syncthing's own default.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.all (p: lib.hasPrefix "/" p) sharePaths;
        message = "MODULES.services.syncthing.shares: all paths must be absolute (start with '/').";
      }
      {
        assertion = builtins.all (p: lib.hasPrefix "/" p) overridePaths;
        message = "MODULES.services.syncthing.shares: all override_path values must be absolute (start with '/').";
      }
      {
        assertion = (lib.unique sharePaths) == sharePaths;
        message = "MODULES.services.syncthing.shares contains duplicate paths.";
      }
      {
        assertion = config.MODULES.networking.tailscale.hostIP != null;
        message = "MODULES.services.syncthing requires MODULES.networking.tailscale.hostIP to be set on this host.";
      }
    ];

    # The device's identity (cert.pem/key.pem, from which Syncthing derives its device ID) is
    # generated ahead of time with `syncthing generate` and stored in sops rather than left for
    # Syncthing to create on first run - this is what lets every host's deviceID be known and
    # wired up (see peerDevices above) before any of them have actually started. The device ID
    # itself is *not* sensitive (it's a public hash of the cert, meant to be shared with peers),
    # but it's only available at eval time as the plain MODULES.services.syncthing.deviceID
    # option below - sops secrets only decrypt at activation on the target host, so a cross-host
    # value like deviceID can't be sourced from sops without breaking that eval-time wiring.
    sops.secrets."syncthing/${configName}/cert" = {
      owner = config.services.syncthing.user;
      group = config.services.syncthing.group;
      mode = "0400";
      restartUnits = ["syncthing.service"];
    };
    sops.secrets."syncthing/${configName}/key" = {
      owner = config.services.syncthing.user;
      group = config.services.syncthing.group;
      mode = "0400";
      restartUnits = ["syncthing.service"];
    };

    services.syncthing = lib.mkMerge [
      {
        enable = true;
        cert = config.sops.secrets."syncthing/${configName}/cert".path;
        key = config.sops.secrets."syncthing/${configName}/key".path;
        guiAddress = "127.0.0.1:${toString config.PORTS.syncthingWebui}";
        openDefaultPorts = false;

        settings = {
          options = {
            # devices are addressed directly over tailscale, public discovery/relays are neither
            # reachable (we only listen on the tailnet) nor needed
            localAnnounceEnabled = false;
            globalAnnounceEnabled = false;
            relaysEnabled = false;
            # -1 = declined; skips the "Allow Anonymous Usage Reporting?" prompt entirely
            urAccepted = -1;
            listenAddresses = [
              "tcp://${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.syncthingSync}"
              "quic://${config.MODULES.networking.tailscale.hostIP}:${toString config.PORTS.syncthingSync}"
            ];
          };

          # reached through Traefik, which forwards the public hostname as the Host header
          gui.insecureSkipHostcheck = true;

          devices = peerDevices // extraDevices;
          folders = folders;
        };
      }
      (mkIf (cfg.user != null) {user = cfg.user;})
      (mkIf (cfg.group != null) {group = cfg.group;})
    ];

    networking.firewall.allowedTCPPorts = [config.PORTS.syncthingSync];
    networking.firewall.allowedUDPPorts = [config.PORTS.syncthingSync];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.syncthing = "127.0.0.1:${toString config.PORTS.syncthingWebui}";
  };
}
