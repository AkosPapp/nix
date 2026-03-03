{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.prometheus;
in {
  options.MODULES.services.prometheus = {
    enable = mkEnableOption "Prometheus monitoring";
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheus;

        globalConfig.scrape_interval = "1s";

        extraFlags = [
          "--web.external-url=https://${config.networking.fqdn}/prometheus"
          "--web.route-prefix=/prometheus"
        ];

        exporters = {
          node = {
            enable = true;
            listenAddress = "127.0.0.1";
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
            port = config.PORTS.prometheusNodeExporter;
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
      MODULES.networking.traefik.path_routes."/prometheus" = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus";

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
              targets = ["127.0.0.1:${toString config.PORTS.traefikDashboard}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.nginx.enable) {
      services.nginx.statusPage = true;

      services.prometheus.exporters.nginx = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusNginxExporter;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "nginx";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.nginx.port}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.postgresql.enable) {
      services.prometheus.exporters.postgres = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusPostgresExporter;
        runAsLocalSuperUser = true;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "postgres";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.postgres.port}"];
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
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusTailscaleExporter;
        environmentFile = config.sops.secrets."tailscale/exporter_environment_file".path;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "tailscale";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.tailscale.port}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.boot.supportedFilesystems.zfs or false) {
      services.prometheus.exporters.zfs = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusZfsExporter;
        pools = config.boot.zfs.extraPools;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "zfs";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.zfs.port}"];
            }
          ];
        }
      ];
    })
  ];
}
