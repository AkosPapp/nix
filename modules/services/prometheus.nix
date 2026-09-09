{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption types;

  cfg = config.MODULES.services.prometheus;
in {
  options.MODULES.services.prometheus = {
    enable = mkOption {
      type = types.bool;
      default = config.MODULES.services.immich.enable;
      defaultText = lib.literalExpression "config.MODULES.services.immich.enable";
      description = ''
        Whether to enable Prometheus monitoring. Defaults to on automatically wherever Immich is
        enabled, since Immich's own metrics (see the immich-api/immich-microservices scrape jobs
        below) need a local Prometheus to scrape them - set this to `false` explicitly to run
        Immich without Prometheus, or `true` to opt in on a host without Immich.
      '';
    };

    rulesDir = mkOption {
      type = types.str;
      default = "/var/lib/prometheus-rules";
      description = ''
        Directory Prometheus loads alerting/recording rules from (*.yml, *.yaml). Synced via
        Syncthing to every other machine that also enables Prometheus, so dropping a rules file
        here propagates everywhere; Prometheus reloads automatically when the directory changes.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheus;

        globalConfig.scrape_interval = "5s";

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

    (mkIf cfg.enable {
      services.prometheus = {
        enableReload = true;

        # ruleFiles glob into a directory that Syncthing populates at runtime, so the files
        # don't exist during the Nix build and promtool can't check them there. Prometheus
        # still validates on reload and keeps the last-good config if a rule file is broken.
        checkConfig = false;
        ruleFiles = ["${cfg.rulesDir}/*.yml" "${cfg.rulesDir}/*.yaml"];
      };

      systemd.tmpfiles.rules = ["d ${cfg.rulesDir} 0755 ${config.services.syncthing.user} ${config.services.syncthing.group} - -"];

      # Reload Prometheus whenever Syncthing adds/updates/removes a rule file
      systemd.paths.prometheus-rules-reload = {
        wantedBy = ["multi-user.target"];
        pathConfig.PathChanged = cfg.rulesDir;
      };

      systemd.services.prometheus-rules-reload.serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl reload prometheus.service";
      };

      # Sync this machine's rules with every other machine that also enables Prometheus
      MODULES.services.syncthing.enable = true;
      MODULES.services.syncthing.shares = [cfg.rulesDir];
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

    (mkIf (cfg.enable && config.services.syncthing.enable) {
      # Syncthing exposes its own Prometheus metrics natively at /metrics on the GUI/API port -
      # no separate exporter binary needed, same as the traefik job above.
      services.prometheus.scrapeConfigs = [
        {
          job_name = "syncthing";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.PORTS.syncthingWebui}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.services.nginx.enable) {
      services.nginx.statusPage = true;
      services.nginx.virtualHosts.localhost.listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.nginxStatus;
        }
      ];

      services.prometheus.exporters.nginx = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusNginxExporter;
        scrapeUri = "http://127.0.0.1:${toString config.PORTS.nginxStatus}/nginx_status";
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

    (mkIf (cfg.enable && config.services.nextcloud.enable) {
      sops.secrets."nextcloud/exporter-token" = {
        owner = "nextcloud-exporter";
        mode = "0400";
      };

      services.prometheus.exporters.nextcloud = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusNextcloudExporter;
        url = "http://127.0.0.1:${toString config.PORTS.nextcloud}";
        tokenFile = config.sops.secrets."nextcloud/exporter-token".path;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "nextcloud";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.nextcloud.port}"];
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

      # This exporter talks to the Tailscale Cloud API, not the local tailscaled - it only needs
      # working internet/DNS, but the module's default unit is merely `after = network.target`,
      # which is reached well before that on boot. It then fails a burst of quick retries (Restart
      # = "always" with systemd's default RestartSec) and permanently start-limit-hits before
      # network actually comes up. Wait for real connectivity and don't let early failures disable
      # further retries.
      systemd.services.prometheus-tailscale-exporter = {
        after = ["network-online.target"];
        wants = ["network-online.target"];
        startLimitIntervalSec = 0;
        serviceConfig.RestartSec = 5;
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

    (mkIf (cfg.enable && config.MODULES.services.immich.enable) {
      # Immich exposes its own OTel/Prometheus metrics natively (no separate exporter binary),
      # same as the traefik/syncthing jobs above - just needs telemetry collection switched on.
      services.immich.environment = {
        IMMICH_TELEMETRY_INCLUDE = "all";
        IMMICH_API_METRICS_PORT = toString config.PORTS.prometheusImmichApiExporter;
        IMMICH_MICROSERVICES_METRICS_PORT = toString config.PORTS.prometheusImmichMicroservicesExporter;
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "immich-api";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.PORTS.prometheusImmichApiExporter}"];
            }
          ];
        }
        {
          job_name = "immich-microservices";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.PORTS.prometheusImmichMicroservicesExporter}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.services.firefly-iii.enable) {
      # Firefly III is a PHP app with no metrics endpoint of its own. Its database and its nginx
      # front end are already covered by the postgres/nginx blocks above (both switch themselves
      # on as soon as firefly-iii.nix enables those services); what's left is the php-fpm pool
      # actually executing the app, which is where request saturation and worker exhaustion show
      # up first. php-fpm publishes that over its own status endpoint on the pool's unix socket.
      services.prometheus.exporters.php-fpm = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = config.PORTS.prometheusPhpFpmExporter;
        extraFlags = [
          "--phpfpm.scrape-uri 'unix://${config.services.phpfpm.pools.firefly-iii.socket};${config.services.firefly-iii.poolConfig."pm.status_path"}'"
        ];
      };

      systemd.services.prometheus-php-fpm-exporter.serviceConfig = {
        # The exporters framework hardens every exporter down to AF_INET/AF_INET6 on the
        # assumption it scrapes over TCP; this one talks FastCGI over a unix socket instead.
        RestrictAddressFamilies = ["AF_UNIX"];
        # That socket is mode 0660, owned by the firefly-iii user and the pool's group - and the
        # exporter runs under a DynamicUser, so joining the group is the only way in.
        SupplementaryGroups = [config.services.firefly-iii.group];
      };

      services.prometheus.scrapeConfigs = [
        {
          job_name = "php-fpm";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.exporters.php-fpm.port}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.services.litellm.enable && config.MODULES.services.litellm.metrics) {
      # LiteLLM serves its own /metrics once the "prometheus" callback is registered (see
      # litellm.nix) - no exporter binary, same as the traefik/syncthing/immich jobs above.
      # Worth having beyond the usual request rates and latencies: the gateway is the only
      # component that can see a backend host being cooled out of rotation after a failure,
      # and litellm_deployment_state carries that. It is also the only place token counts
      # exist at all, since nothing scrapes the vLLM instances directly - they are
      # socket-activated, and scraping them on a timer would defeat the idle unload exactly
      # the way LiteLLM's own background health checks did.
      #
      # The path stays /metrics even with SERVER_ROOT_PATH set: FastAPI's root_path changes
      # the URLs the app generates, not the ones it answers on, and this scrape goes straight
      # to the backend port rather than through Traefik.
      services.prometheus.scrapeConfigs = [
        {
          job_name = "litellm";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.PORTS.litellm}"];
            }
          ];
        }
      ];
    })

    (mkIf (cfg.enable && config.MODULES.services.open-webui.enable) {
      # Open WebUI serves no /metrics endpoint and there's no exporter for it; its only
      # instrumentation is OpenTelemetry, which pushes rather than being scraped (request counts
      # and latency histograms per route, plus gauges for total/active/active-today users).
      # Prometheus 3 can receive OTLP directly, so it takes the push itself instead of an
      # otel-collector sitting in between - the receiver is off unless this flag is passed.
      services.prometheus.extraFlags = ["--web.enable-otlp-receiver"];

      # nixpkgs' open-webui is missing opentelemetry-instrumentation-system-metrics, which
      # open_webui/utils/telemetry/instrumentors.py imports unconditionally - so ENABLE_OTEL
      # below turns a working service into a ModuleNotFoundError crash-loop on the stock
      # package. Patched in here rather than in open-webui.nix because this is the block that
      # switches OTel on, and the override costs a local rebuild (of the Python app only - the
      # npm frontend is a separate derivation and still comes from the binary cache).
      services.open-webui.package = pkgs.open-webui.overridePythonAttrs (old: {
        dependencies = old.dependencies ++ [pkgs.python3Packages.opentelemetry-instrumentation-system-metrics];
      });

      services.open-webui.environment = {
        ENABLE_OTEL = "True";
        # Metrics only. Traces are gated separately and would need somewhere to put spans;
        # Prometheus isn't that, and nothing here runs Tempo/Jaeger.
        ENABLE_OTEL_METRICS = "True";
        # Open WebUI defaults to the OTLP/gRPC exporter, which Prometheus's receiver doesn't
        # speak - it accepts OTLP over HTTP only.
        OTEL_METRICS_OTLP_SPAN_EXPORTER = "http";
        # Passed to the exporter verbatim (no /v1/metrics is appended for us), and the whole
        # path sits behind the --web.route-prefix=/prometheus set above. Samples arrive tagged
        # job="open-webui" from OTEL_SERVICE_NAME's default.
        OTEL_METRICS_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus/api/v1/otlp/v1/metrics";
        # Match globalConfig.scrape_interval above rather than the 10s OTel default, so pushed
        # series have the same resolution as every scraped one.
        OTEL_METRICS_EXPORT_INTERVAL_MILLIS = "5000";
      };
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
