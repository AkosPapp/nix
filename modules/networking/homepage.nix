{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types mapAttrsToList;

  cfg = config.MODULES.networking.homepage;
in {
  options.MODULES.networking.homepage = {
    enable = mkEnableOption "Homepage dashboard";

    services = mkOption {
      # freeform attrset of service definitions (user-supplied entries override defaults)
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional services to show on the homepage dashboard";
    };

    port = mkOption {
      type = types.int;
      default = 8082;
      description = "Port for Homepage dashboard";
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      # default services (can be overridden/extended by `config.MODULES.networking.homepage.services`)
      MODULES.networking.homepage.services = {
        grafana = {
          href = "/grafana";
          icon = "/grafana/public/img/fav32.png";
          widget = {
            type = "grafana";
            version = 2;
            url = "http://127.0.0.1:${toString config.MODULES.networking.grafana.port}/grafana/";
            username = "admin";
            password = "admin";
          };
        };

        prometheus = {
          href = "/prometheus";
          icon = "/prometheus/favicon.svg";
          widget = {
            type = "prometheus";
            url = "http://127.0.0.1:${toString config.MODULES.networking.prometheus.port}/prometheus/";
          };
        };

        traefik = {
          href = "/traefik";
          icon = "/traefik/favicon.ico";
          widget = {
            type = "traefik";
            url = "http://127.0.0.1:${toString config.MODULES.networking.traefik.dashboardPort}/";
          };
        };

        homepage.icon = "/homepage/homepage.ico";
      };

      services.homepage-dashboard = {
        enable = true;
        listenPort = cfg.port;

        settings = {
          title = config.networking.hostName or "Homepage";
          headerStyle = "clean";
          hideVersion = true;
          theme = "dark";
          layout = {
            "Services" = {
              useEqualHeights = true;
              header = false;
              columns = 3;
              style = "row";
            };
          };
          quicklaunch = {
            searchDescriptions = true;
            hideInternetSearch = false;
            showSearchSuggestions = true;
            hideVisitURL = false;
            provider = "custom";
            url = "/searx/search?q=";
            target = "_blank";
            suggestionUrl = "https://search.brave.com/api/suggest?country=US&count=10&q=";
          };
        };

        services = [
          {
            "Services" = (
              mapAttrsToList
              (name: config: {
                # Add default href/icon if not set by user
                ${name} = config;
              })
              config.MODULES.networking.homepage.services
            );
          }
        ];

        widgets = [
          {
            resources = {
              cpu = true;
              memory = true;
              disk = "/";
            };
          }
          {
            datetime = {
              text_size = "xl";
              format = {
                timeStyle = "short";
              };
            };
          }
        ];
      };

      systemd.services.homepage-dashboard.environment = {
        BASE_PATH = "/homepage";
        HOMEPAGE_ALLOWED_HOSTS = lib.mkForce "akos01.tail546fb.ts.net,akos01.airlab";
      };

      # Add to traefik routes
      MODULES.networking.traefik.path_routes."/homepage" = "http://127.0.0.1:${toString cfg.port}";
      MODULES.networking.traefik.defaultPage = "/homepage";
    })
    {
      MODULES.networking.homepage.services = lib.mkMerge (
        map (
          value: {
            "${lib.removePrefix "\/" value}" = {
              href = lib.mkDefault value;
              icon = lib.mkDefault "${value}/favicon.ico";
              # href = value;
              # icon = "${value}/favicon.ico";
            };
          }
        )
        (
          builtins.attrNames
          config.MODULES.networking.traefik.path_routes
        )
      );
    }
  ];
}
