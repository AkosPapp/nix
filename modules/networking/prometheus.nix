{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.networking.prometheus;
in {
  options.MODULES.networking.prometheus = {
    enable = mkEnableOption "Prometheus monitoring";

    port = mkOption {
      type = types.int;
      default = 9090;
      description = "Port for Prometheus web interface";
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      services.prometheus = {
        enable = true;
        port = cfg.port;

        globalConfig.scrape_interval = "1s";

        extraFlags = [
          "--web.external-url=https://${config.networking.fqdn}/prometheus"
          "--web.route-prefix=/prometheus"
        ];

        exporters = {
          node = {
            enable = true;
            enabledCollectors = [
              "systemd"
              "cpu"
              "diskstats"
              "filesystem"
              "loadavg"
              "meminfo"
              "netdev"
              "netstat"
              "stat"
              "time"
              "uname"
              "vmstat"
            ];
            port = 9100;
          };
        };

        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              {
                targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
              }
            ];
          }
        ];
      };
    })

    (mkIf (cfg.enable && config.MODULES.networking.traefik.enable) {
      MODULES.networking.traefik.path_routes."/prometheus" = "http://127.0.0.1:${toString cfg.port}/prometheus";

      services.traefik.staticConfigOptions.metrics.prometheus = {
        addEntryPointsLabels = true;
        addRoutersLabels = true;
        addServicesLabels = true;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "traefik";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.MODULES.networking.traefik.dashboardPort}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.nginx.enable) {
      services.nginx.statusPage = true;

      services.prometheus.exporters.nginx = {
        enable = true;
        port = 9113;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "nginx";
          static_configs = [
            {
              targets = ["127.0.0.1:9113"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.postgresql.enable) {
      services.prometheus.exporters.postgres = {
        enable = true;
        port = 9187;
        runAsLocalSuperUser = true;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "postgres";
          static_configs = [
            {
              targets = ["127.0.0.1:9187"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.tailscale.enable) {
      sops.secrets."tailscale/exporter_environment_file" = {
        mode = "0400";
      };
      services.prometheus.exporters.tailscale = {
        enable = true;
        port = 9200;
        environmentFile = config.sops.secrets."tailscale/exporter_environment_file".path;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "tailscale";
          static_configs = [
            {
              targets = ["127.0.0.1:9200"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.boot.supportedFilesystems.zfs or false) {
      services.prometheus.exporters.zfs = {
        enable = true;
        port = 9134;
        pools = config.boot.zfs.extraPools;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "zfs";
          static_configs = [
            {
              targets = ["127.0.0.1:9134"];
            }
          ];
        }
      ];
    })
  ];
}
