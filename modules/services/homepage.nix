{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types mapAttrsToList;

  cfg = config.MODULES.services.homepage;
in {
  options.MODULES.services.homepage = {
    enable = mkEnableOption "Homepage dashboard";

    services = mkOption {
      # freeform attrset of service definitions (user-supplied entries override defaults)
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional services to show on the homepage dashboard";
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      # default services (can be overridden/extended by `config.MODULES.networking.homepage.services`)
      MODULES.services.homepage.services = {
        grafana = {
          href = "/grafana";
          icon = "/grafana/public/img/fav32.png";
          widget = {
            type = "grafana";
            version = 2;
            url = "http://127.0.0.1:${toString config.PORTS.grafana}/grafana/";
            username = "admin";
            password = "admin";
          };
        };

        prometheus = {
          href = "/prometheus";
          icon = "/prometheus/favicon.svg";
          widget = {
            type = "prometheus";
            url = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus/";
          };
        };

        traefik = {
          href = "/traefik";
          icon = "/traefik/favicon.ico";
          widget = {
            type = "traefik";
            url = "http://127.0.0.1:${toString config.PORTS.traefikDashboard}/";
          };
        };

        sftpgo.icon = "/sftpgo/static/favicon.png";
        webdav.icon = "/sftpgo/static/favicon.png";
        i2pd.icon = "https://github.com/PurpleI2P/i2pd-logo/raw/refs/heads/master/i2pd_logo_2_curved.svg";

        transmission = {
          icon = "https://transmissionbt.com/assets/images/Transmission_icon.png";
          widget = {
            type = "transmission";
            url = "http://127.0.0.1:${toString config.PORTS.transmissionRpc}";
            rpcUrl = "/transmission/";
          };
        };

        homepage.icon = "/homepage/homepage.ico";
        ipfs.icon = "https://raw.githubusercontent.com/ipfs/kubo/refs/heads/master/docs/logo/kubo-logo.svg";
        ipfs-gateway.icon = "https://raw.githubusercontent.com/ipfs/ipfs-webui/refs/heads/main/src/navigation/ipfs-logo.svg";
      };

      services.homepage-dashboard = {
        enable = true;
        listenPort = config.PORTS.homepage;

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
              config.MODULES.services.homepage.services
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
        HOMEPAGE_ALLOWED_HOSTS = lib.mkForce "${config.networking.fqdn},${config.networking.hostName}.airlab,${config.networking.hostName}";
        HOSTNAME = "127.0.0.1";
      };

      # Add to traefik routes
      MODULES.networking.traefik.path_routes."/homepage" = "http://127.0.0.1:${toString config.PORTS.homepage}";
      MODULES.networking.traefik.defaultPage = "/homepage";
    })
    {
      MODULES.services.homepage.services = lib.mkMerge (
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
