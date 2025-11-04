{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}: let
  port = "8222"; # any non-conflicting port
in {
  options = {
    MODULES.security.vaultwarden.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable vaultwarden service";
    };
  };

  config =
    lib.mkIf config.MODULES.security.vaultwarden.enable
    {
      MODULES.networking.reverse-proxy.enable = true;
      MODULES.networking.reverse-proxy.options.patterns = {
        "^https://${config.networking.fqdn}/vaultwarden" = "http://127.0.0.1:${port}/vaultwarden";
      };

      services.vaultwarden = {
        enable = true;
        webVaultPackage = pkgs-unstable.vaultwarden.webvault;
        package = pkgs-unstable.vaultwarden;

        config = {
          DOMAIN = "https://${config.networking.fqdn}/vaultwarden";
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = port;
          ROCKET_WORKERS = 4;
          SIGNUPS_ALLOWED = false;
          INVITATIONS_ALLOWED = false;
          WEBSOCKET_ENABLED = true;
          ADMIN_TOKEN = "$argon2id$v=19$m=65540,t=3,p=4$CtkQ5lIwUKip05MQsuhqZ5bI5TS7iTOcr1F6wcA8nBU$rQAVucVW51JrQ6b83C7z4K0dlVk0nTo9i+iLu3iZlUA";
          ROCKET_LOG = "INFO";
        };
      };
    };
}
