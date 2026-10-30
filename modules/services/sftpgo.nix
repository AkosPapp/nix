{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.MODULES.services.sftpgo;
  inherit (lib) mkEnableOption mkIf mkOption types;

  # The uid that performs every filesystem io under every user's home and virtual folders.
  daemonUser =
    if cfg.runAsUser != null
    then cfg.runAsUser
    else "sftpgo";
in {
  options.MODULES.services.sftpgo = {
    enable = mkEnableOption ''
      SFTPGo server for WebDAV access: loopback webdavd + admin httpd, exposed on the tailnet as
      https://webdav.<host> and https://sftpgo.<host> through Traefik (SFTP and FTP are off).
      The WebDAV root "/" IS the authenticated user's home_dir, so one hostname serves different
      trees per credential. Accounts are deliberately NOT declarative: they live in the sqlite DB
      and carry live passwords the operator set through the WebAdmin UI, and every loaddata/
      upsert shape we measured rewrites the whole user record - a repo-side change must never be
      able to reset someone's working credential. Adding a user or a virtual folder is a
      one-time WebAdmin step, like the Joplin sync-target choice in joplin.nix.
    '';

    runAsUser = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Run the daemon as this system user instead of the nixpkgs-created `sftpgo` user. The
        daemon's uid is what touches every file under every home_dir and virtual folder, so
        naming the uid that already owns the shared trees makes WebDAV writes carry the same
        ownership as the apps that read them. hp sets hermes: the streamed Joplin container runs
        at the hermes uid (joplin.nix's PUID wiring) and writes its sync files 0600, and
        /var/lib/hermes is 2770 - a stock sftpgo-uid daemon could not even READ that tree, let
        alone serve it (measured 2026-10-29). The named user must already exist (another module
        creates it); nixpkgs only auto-creates `sftpgo` while that is also the service user.
        dataDir migrates to the new owner via a find-guarded root ExecStartPre below, which
        systemd orders before ExecStart - a tmpfiles `z` rule does NOT work for this migration:
        activation starts the unit and systemd-tmpfiles-resetup.service concurrently, and hp's
        first hermes-uid start measured the db still 0600 old-uid: "unable to open database
        file: permission denied", failed switch, rolled back (2026-10-29).
      '';
    };

    sharedPaths = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["/var/lib/hermes/joplin"];
      description = ''
        Absolute paths outside dataDir the daemon must be able to read and write - the local
        mapped_path of virtual folders pointing into another service's state dir (WebDAV
        virtual folders must exist already; SFTPGo does not create a mapped path). The unit is
        ProtectSystem-hardened by nixpkgs with ReadWritePaths = dataDir only, so each path is
        added to services.sftpgo.extraReadWriteDirs. Unix ownership still decides access:
        combine with a runAsUser that owns (or shares the group of) the target tree.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.sftpgo = {
      user = daemonUser;
      group = daemonUser;

      enable = true;

      settings = {
        # Data directory
        data_provider = {
          driver = "sqlite";
          name = "${config.services.sftpgo.dataDir}/sftpgo.db";
        };

        # WebDAV configuration
        webdavd = {
          bindings = [
            {
              port = config.PORTS.sftpgoWebdav;
              address = "127.0.0.1";
              enable_https = false;
            }
          ];
        };

        # Admin UI (optional but useful)
        httpd = {
          bindings = [
            {
              port = config.PORTS.sftpgoHttp;
              address = "127.0.0.1";
            }
          ];
        };

        # Optional: Disable other protocols if you only want WebDAV
        sftpd.bindings = [];
        ftpd.bindings = [];
      };

      extraReadWriteDirs = cfg.sharedPaths;
    };

    # "+" runs this as root despite the unit's User= switch. find-guarded so steady-state
    # starts touch nothing; only the runAsUser CHANGE has to walk the tree.
    systemd.services.sftpgo.serviceConfig.ExecStartPre = lib.optionals (cfg.runAsUser != null) [
      (
        "+"
        + (pkgs.writeShellScript "sftpgo-own-dataDir" ''
          set -eu
          find ${config.services.sftpgo.dataDir} \
            \( ! -user ${daemonUser} -o ! -group ${daemonUser} \) \
            -exec ${pkgs.coreutils}/bin/chown -h ${daemonUser}:${daemonUser} {} +
        '')
      )
    ];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services = {
      sftpgo = "127.0.0.1:${toString config.PORTS.sftpgoHttp}";
      webdav = "127.0.0.1:${toString config.PORTS.sftpgoWebdav}";
    };
  };
}
