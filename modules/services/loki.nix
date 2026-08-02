{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf;

  cfg = config.MODULES.services.loki;
  dataDir = config.services.loki.dataDir;
in {
  options.MODULES.services.loki = {
    enable = mkEnableOption ''
      Loki log aggregation. Comes with a local Grafana Alloy agent that tails this host's own
      systemd journal and pushes it to Loki - promtail (the traditional agent for this) has been
      removed upstream as end-of-life, Alloy is its official replacement.
    '';
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;

          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = config.PORTS.loki;
          };

          common = {
            path_prefix = dataDir;
            replication_factor = 1;
            storage.filesystem = {
              chunks_directory = "${dataDir}/chunks";
              rules_directory = "${dataDir}/rules";
            };
            ring.kvstore.store = "inmemory";
          };

          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];

          limits_config.retention_period = "30d";

          compactor = {
            working_directory = "${dataDir}/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
        };
      };

      # Local agent: reads this host's own journald and pushes it to the Loki instance above.
      # Alloy's NixOS module already grants its service the "systemd-journal" supplementary
      # group, so no extra permission wiring is needed here to read the journal.
      services.alloy.enable = true;
      environment.etc."alloy/config.alloy".text = ''
        loki.relabel "journal" {
          forward_to = []

          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }
        }

        loki.source.journal "read" {
          forward_to    = [loki.write.local.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels        = {
            job  = "systemd-journal",
            host = "${config.networking.hostName}",
          }
        }

        loki.write "local" {
          endpoint {
            url = "http://127.0.0.1:${toString config.PORTS.loki}/loki/api/v1/push"
          }
        }
      '';
    })

    (mkIf (cfg.enable && config.MODULES.services.grafana.enable) {
      services.grafana.provision.datasources.settings.datasources = [
        {
          name = "Loki";
          type = "loki";
          uid = "loki";
          access = "proxy";
          url = "http://127.0.0.1:${toString config.PORTS.loki}";
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.networking.traefik.enable) {
      MODULES.networking.traefik.path_routes."/loki" = "http://127.0.0.1:${toString config.PORTS.loki}";
    })
  ];
}
