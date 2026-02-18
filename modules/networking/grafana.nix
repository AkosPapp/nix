{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.networking.grafana;
in {
  options.MODULES.networking.grafana = {
    enable = mkEnableOption "Grafana monitoring dashboard";

    port = mkOption {
      type = types.int;
      default = 3000;
      description = "Port for Grafana web interface";
    };

    adminPassword = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Initial admin password for Grafana (plain text)";
    };

    adminPasswordHash = mkOption {
      type = types.nullOr types.str;
      default = "$2b$05$v2zNXA1NdFrRt7md85gdcOJzr98H5RNIBaHI1AE1jHg11uw6PFNV2";
      description = "Initial admin password hash for Grafana (bcrypt)";
    };
  };

  config = mkIf cfg.enable {
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_port = cfg.port;
          http_addr = "127.0.0.1";
          domain = config.networking.fqdn;
          root_url = "https://${config.networking.fqdn}/grafana";
          serve_from_sub_path = true;
        };
        dashboards.min_refresh_interval = "1s";
        timeSettings = {
          autoRefresh = "1s";
          autoRefreshIntervals = ["1s" "5s" "10s" "30s" "1m"];
        };
        analytics.reporting_enabled = false;
        security =
          {
            admin_user = "admin";
          }
          // (lib.optionalAttrs (cfg.adminPassword != null) {
            admin_password = cfg.adminPassword;
          })
          // (lib.optionalAttrs (cfg.adminPasswordHash != null) {
            admin_password = "$__file{${pkgs.writeText "grafana-admin-password-hash" cfg.adminPasswordHash}}";
          });
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString config.MODULES.networking.prometheus.port}/prometheus";
            isDefault = true;
          }
        ];
      };
    };

    # Add to traefik routes
    MODULES.networking.traefik.path_routes."/grafana" = "http://127.0.0.1:${toString cfg.port}/grafana";
  };
}
