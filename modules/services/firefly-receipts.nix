{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.firefly-iii.receipts;

  user = "firefly-receipts";

  # Syncthing owns the inbox so it can create and delete in it under its own hardening (see the
  # note on `user` in syncthing.nix - PrivateUsers means it can't reach files owned by anyone
  # else). The processor joins that group instead, which is the side of this we control.
  inboxOwner =
    if cfg.syncthing
    then config.services.syncthing.user
    else user;
  inboxGroup =
    if cfg.syncthing
    then config.services.syncthing.group
    else user;
in {
  options.MODULES.services.firefly-iii.receipts = {
    enable = mkEnableOption ''
      the receipt queue: photograph a receipt into `spoolDir/inbox` and a local vision model
      reads it, then files it in Firefly III as a withdrawal with the photo attached.

      Everything it creates carries the `receipt-import` tag, so a bad run is one Firefly III
      search away from being found and undone. Where the line items it read disagree with the
      total it read by more than 2%, it adds `receipt-import-check` and says so in the notes:
      models do sometimes pick the tax line sitting under the total instead of the total itself,
      and the items are the one independent reading available to catch it. Those are imported
      like any other - the tag is there to make them easy to eyeball, not to hold them back
    '';

    model = mkOption {
      type = types.str;
      default = "qwen3-vl:4b";
      example = "qwen2.5vl:3b";
      description = ''
        Vision model ollama reads the receipts with, pulled automatically via
        `MODULES.services.ollama.loadModels`.

        Qwen3-VL is a thinking model and pays for it: on hp's 8 CPU threads it takes minutes per
        photo, where the older qwen2.5vl:3b answers in well under one. It is still the default,
        because on a Hungarian cafe receipt qwen2.5vl:3b reported the 578 HUF VAT line as the
        2720 HUF total - a plausible-looking transaction, off by a factor of five, filed without
        complaint. Hardening the prompt against exactly that did not fix it; qwen3-vl:4b gets it
        right, along with the merchant name and the payment method. In accounting a slow answer
        costs nothing, since this is a queue nobody waits on, and a confidently wrong one costs a
        great deal.

        Note that `think: false` is not a way to buy back the speed: it makes qwen3-vl answer
        into the reasoning channel and return empty content. A host with a GPU makes the whole
        trade-off moot.
      '';
    };

    createTransactions = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to actually write the extracted receipts into Firefly III. Needs an API token in
        sops as `firefly-iii/receipts-api-token`, and that can only be minted from a Firefly III
        that already exists (Options -> Profile -> OAuth -> Personal Access Tokens), so it stays
        off until there is one. Reading is unaffected either way: with this off the vision model
        still processes every photo and parks it in `spoolDir/pending` alongside the fields it
        read, and turning it on files the whole backlog. Nothing queued is lost in the meantime.
      '';
    };

    assetAccount = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Checking account";
      description = ''
        Name of the Firefly III asset account receipts are booked against. Null uses whichever
        asset account the API returns first, which is only the right answer on an instance that
        has exactly one - set this explicitly once there is more than one.
      '';
    };

    currency = mkOption {
      type = types.str;
      default = "EUR";
      description = "ISO 4217 currency assumed when a receipt shows no symbol or code of its own.";
    };

    spoolDir = mkOption {
      type = types.str;
      default = "/var/lib/firefly-receipts";
      description = ''
        Queue root. Holds `inbox` (drop photos here), `pending` (read, awaiting import), `done`
        and `failed`. Only `inbox` is shared over Syncthing, so a receipt disappears from the
        phone once it has been picked up, and the archive stays on the server.
      '';
    };

    interval = mkOption {
      type = types.str;
      default = "5min";
      description = ''
        How often the queue is drained, as a systemd time span. This is a timer rather than a
        `systemd.path` watching the directory: a path unit re-fires the moment its service exits
        while the glob still matches, so a photo still mid-transfer - or any file the processor
        deliberately leaves alone - would spin it in a tight loop. Inference here takes minutes
        anyway, so polling costs nothing.
      '';
    };

    syncthing = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Share `spoolDir/inbox` over Syncthing, with the phone registered in syncthing.nix's
        `knownExtraDevices`, so photographing a receipt into the synced folder is all it takes.
        Turn this off to fill the inbox some other way (sftpgo, scp, a scanner drop).
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "Firefly III receipt queue processor";
    };
    users.groups.${user} = {};

    MODULES.services.ollama.enable = true;
    # Pull the vision model up front rather than on the first receipt, so the first photo isn't
    # sitting in the queue behind a multi-gigabyte download.
    MODULES.services.ollama.loadModels = [cfg.model];

    MODULES.services.syncthing.shares = mkIf cfg.syncthing [
      {
        path = "${cfg.spoolDir}/inbox";
        extra_devices = ["phone"];
      }
    ];

    sops.secrets."firefly-iii/receipts-api-token" = mkIf cfg.createTransactions {
      owner = user;
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      # 0755 so Syncthing can traverse into inbox; the subdirectories carry the real permissions.
      "d ${cfg.spoolDir} 0755 ${user} ${user} - -"
      # setgid: whatever Syncthing writes here stays group-readable to the processor.
      "d ${cfg.spoolDir}/inbox 2770 ${inboxOwner} ${inboxGroup} - -"
      "d ${cfg.spoolDir}/pending 0750 ${user} ${user} - -"
      "d ${cfg.spoolDir}/done 0750 ${user} ${user} - -"
      "d ${cfg.spoolDir}/failed 0750 ${user} ${user} - -"
    ];

    systemd.services.firefly-receipts = {
      description = "Read queued receipt photos and file them in Firefly III";
      after = ["ollama.service" "phpfpm-firefly-iii.service" "network-online.target"];
      wants = ["ollama.service"];

      environment =
        {
          RECEIPTS_OLLAMA_URL = "http://127.0.0.1:${toString config.PORTS.ollama}";
          RECEIPTS_MODEL = cfg.model;
          RECEIPTS_SPOOL_DIR = cfg.spoolDir;
          RECEIPTS_FIREFLY_URL = "http://127.0.0.1:${toString config.PORTS.fireflyIii}";
          RECEIPTS_CURRENCY = cfg.currency;
          RECEIPTS_MAGICK = lib.getExe pkgs.imagemagick;
        }
        // lib.optionalAttrs cfg.createTransactions {
          RECEIPTS_TOKEN_FILE = config.sops.secrets."firefly-iii/receipts-api-token".path;
        }
        // lib.optionalAttrs (cfg.assetAccount != null) {
          RECEIPTS_ASSET_ACCOUNT = cfg.assetAccount;
        };

      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        # Reading the inbox and moving photos out of it both need write access to a directory
        # Syncthing owns.
        SupplementaryGroups = lib.optional cfg.syncthing config.services.syncthing.group;
        ExecStart = "${pkgs.python3}/bin/python3 ${./firefly-receipts.py}";
        # A CPU-only vision model takes minutes per photo, and a weekend's worth of receipts
        # arrives as one batch.
        TimeoutStartSec = "2h";

        # Deliberately no PrivateUsers: it would map the Syncthing supplementary group above to
        # nobody, and with it goes the only access this has to the inbox.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ReadWritePaths = [cfg.spoolDir];
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged"];
        UMask = "0077";
      };
    };

    systemd.timers.firefly-receipts = {
      description = "Drain the Firefly III receipt queue";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitInactiveSec = cfg.interval;
        Persistent = true;
      };
    };

    assertions = [
      {
        assertion = cfg.enable -> config.MODULES.services.firefly-iii.enable;
        message = "MODULES.services.firefly-iii.receipts needs MODULES.services.firefly-iii.enable on the same host (it books transactions against the local instance).";
      }
    ];
  };
}
