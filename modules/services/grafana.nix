{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.grafana;

  exportDashboards = pkgs.writeShellScriptBin "grafana-export-dashboards" ''
    set -euo pipefail

    GRAFANA_URL="http://127.0.0.1:${toString config.PORTS.grafana}"   # hit it locally, skip the proxy
    ADMIN_PASSWORD="$(cat ${config.sops.secrets."grafana/admin_password".path})"
    AUTH="admin:$ADMIN_PASSWORD"
    OUT_DIR="${cfg.dashboardsDir}"

    mkdir -p "$OUT_DIR"

    ${pkgs.curl}/bin/curl -s -u "$AUTH" "$GRAFANA_URL/api/search?type=dash-db" | \
    ${pkgs.jq}/bin/jq -r '.[] | "\(.uid)\t\(.folderTitle // "")"' | \
    while IFS=$'\t' read -r uid folder; do
      # dashboards with no real folder come back with an empty folderTitle - they belong at the
      # provisioner's own root, *not* in a "General" subfolder: "General" is Grafana's reserved
      # pseudo-folder name for exactly this case, and foldersFromFilesStructure refuses to create
      # a real folder with that name ("A folder with that name already exists"), which aborts
      # provisioning for every dashboard, not just this one.
      if [ -n "$folder" ]; then
        mkdir -p "$OUT_DIR/$folder"
        target="$OUT_DIR/$folder/$uid.json"
      else
        target="$OUT_DIR/$uid.json"
      fi
      ${pkgs.curl}/bin/curl -s -u "$AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" | \
        ${pkgs.jq}/bin/jq '.dashboard | del(.id)' \
        > "$target"
      echo "Exported $uid → ''${folder:+$folder/}"
    done
  '';
in {
  options.MODULES.services.grafana = {
    enable = mkEnableOption "Grafana monitoring dashboard";

    dashboardsDir = mkOption {
      type = types.str;
      default = "/var/lib/grafana-dashboards";
      description = ''
        Directory Grafana provisions dashboards from. Synced via Syncthing to every other
        machine that also enables Grafana, so dropping a dashboard JSON file here (or editing
        one) propagates everywhere automatically.
      '';
    };

    defaultDashboardPath = mkOption {
      type = types.nullOr types.str;
      default = "/var/lib/grafana-dashboards/system-overview-v1.json";
      example = "/var/lib/grafana-dashboards/system-overview-v1.json";
      description = ''
        Absolute path to a dashboard JSON file (e.g. one already provisioned under
        `dashboardsDir`, from `grafana-export-dashboards`) to use as Grafana's home/default
        dashboard, instead of the built-in welcome page. Leave null to use Grafana's default.
      '';
    };
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
          domain = config.MODULES.networking.traefik.hostOf "grafana";
          root_url = config.MODULES.networking.traefik.urlOf "grafana";
        };
        analytics.reporting_enabled = false;
        security = {
          admin_user = "admin";
          secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
          admin_password = "$__file{${config.sops.secrets."grafana/admin_password".path}}";
        };
        dashboards = lib.optionalAttrs (cfg.defaultDashboardPath != null) {
          default_home_dashboard_path = cfg.defaultDashboardPath;
        };
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString config.PORTS.prometheus}";
            isDefault = true;
          }
        ];

        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "synced";
              folder = "Synced";
              type = "file";
              disableDeletion = false;
              allowUiUpdates = false;
              updateIntervalSeconds = 30;
              options = {
                path = cfg.dashboardsDir;
                foldersFromFilesStructure = true;
              };
            }
          ];
        };
      };
    };

    # world-readable so the grafana user can read files regardless of which uid Syncthing writes as
    systemd.tmpfiles.rules = ["d ${cfg.dashboardsDir} 0755 ${config.services.syncthing.user} ${config.services.syncthing.group} - -"];

    # Pulls every dashboard currently in Grafana's own DB out into dashboardsDir, so it's picked
    # up by the "synced" file provisioner above and propagated to every other machine via
    # Syncthing. Needs to read the admin_password secret, so run as root (or grafana).
    environment.systemPackages = [exportDashboards];

    # Sync this machine's dashboards with every other machine that also enables Grafana
    MODULES.services.syncthing.enable = true;
    MODULES.services.syncthing.shares = [cfg.dashboardsDir];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.grafana = "127.0.0.1:${toString config.PORTS.grafana}";
  };
}
