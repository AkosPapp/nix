{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.MODULES.services.grafana;
in {
  options.MODULES.services.grafana = {
    enable = mkEnableOption "Grafana monitoring dashboard";
  };

  config = mkIf cfg.enable {
    sops.secrets."grafana/secret_key" = {
      mode = "0400";
      owner = "grafana";
    };

    sops.secrets."grafana/admin_password" = {
      mode = "0400";
      owner = "grafana";
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_port = config.PORTS.grafana;
          http_addr = "127.0.0.1";
          domain = config.networking.fqdn;
          root_url = "https://${config.networking.fqdn}/grafana";
          serve_from_sub_path = true;
        };
        analytics.reporting_enabled = false;
        security = {
          admin_user = "admin";
          secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
          admin_password = "$__file{${config.sops.secrets."grafana/admin_password".path}}";
        };
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus";
            isDefault = true;
          }
        ];
      };
    };

    # Add to traefik routes
    MODULES.networking.traefik.path_routes."/grafana" = "http://127.0.0.1:${toString config.PORTS.grafana}/grafana";
  };
}
