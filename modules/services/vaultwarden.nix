{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: {
  options = {
    MODULES.services.vaultwarden.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable vaultwarden service";
    };
  };

  config =
    lib.mkIf config.MODULES.services.vaultwarden.enable
    {
      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.services.vaultwarden = "127.0.0.1:${toString config.PORTS.vaultwarden}";
      # The admin token must NEVER live in services.vaultwarden.config: nixpkgs renders
      # that attrset into an env file IN /NIX/STORE (world-readable, in every host's
      # closure - the committed argon2 hash this module used to carry was reachable by
      # anyone holding it, 2026-10-25 review #5). It now lives in sops as a dotenv
      # single-line file, decrypted at activation to a 0400 vaultwarden-owned path;
      # nixpkgs appends environmentFile entries AFTER the store env file.
      # NOTE: the old hash remains in git history - rotate it (`vaultwarden hash` +
      # `sops -e` a new vaultwarden/admin_token_env) before trusting the panel again.
      MODULES.security.sops.enable = true;
      # Deliberately NOT under /run/secrets: the vaultwarden jail keeps the blanket
      # /run/secrets mask (ownSecretsMask rows aside, jail.nix convention), so the
      # EnvironmentFile would be unreadable there - same relocation as firefly-iii.nix's
      # app-key above; sops-nix creates the parent dirs.
      sops.secrets."vaultwarden/admin_token_env" = {
        path = "/run/jail-secrets/vaultwarden/admin_token_env";
        owner = config.users.users.vaultwarden.name;
        group = config.users.groups.vaultwarden.name;
        mode = "0400";
        restartUnits = ["vaultwarden.service"];
      };
      services.vaultwarden = {
        enable = true;
        webVaultPackage = pkgs-unstable.vaultwarden.webvault;
        package = pkgs-unstable.vaultwarden;
        environmentFile = [config.sops.secrets."vaultwarden/admin_token_env".path];

        config = {
          DOMAIN = config.MODULES.networking.traefik.urlOf "vaultwarden";
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = config.PORTS.vaultwarden;
          ROCKET_WORKERS = 4;
          SIGNUPS_ALLOWED = false;
          INVITATIONS_ALLOWED = false;
          WEBSOCKET_ENABLED = true;
          ROCKET_LOG = "INFO";
        };
      };
    };
}
