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

      MODULES.services.homepage.services.homepage.icon = "/homepage/homepage.ico";
    })
    (mkIf (cfg.enable && config.MODULES.services.grafana.enable) {
      MODULES.services.homepage.services.grafana = {
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
    })
    (mkIf (cfg.enable && config.MODULES.services.prometheus.enable) {
      MODULES.services.homepage.services.prometheus = {
        href = "/prometheus";
        icon = "/prometheus/favicon.svg";
        widget = {
          type = "prometheus";
          url = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.networking.traefik.enable) {
      MODULES.services.homepage.services.traefik = {
        href = "/traefik";
        icon = "/traefik/favicon.ico";
        widget = {
          type = "traefik";
          url = "http://127.0.0.1:${toString config.PORTS.traefikDashboard}/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.sftpgo.enable) {
      MODULES.services.homepage.services.sftpgo.icon = "/sftpgo/static/favicon.png";
      MODULES.services.homepage.services.webdav.icon = "/sftpgo/static/favicon.png";
    })
    (mkIf (cfg.enable && config.MODULES.services.i2pd.enable) {
      MODULES.services.homepage.services.i2pd.icon = "https://github.com/PurpleI2P/i2pd-logo/raw/refs/heads/master/i2pd_logo_2_curved.svg";
    })
    (mkIf (cfg.enable && config.MODULES.services.transmission.enable) {
      MODULES.services.homepage.services.transmission = {
        icon = "https://transmissionbt.com/assets/images/Transmission_icon.png";
        widget = {
          type = "transmission";
          url = "http://127.0.0.1:${toString config.PORTS.transmissionRpc}";
          rpcUrl = "/transmission/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.ipfs.enable) {
      MODULES.services.homepage.services.ipfs.icon = "https://raw.githubusercontent.com/ipfs/kubo/refs/heads/master/docs/logo/kubo-logo.svg";
      MODULES.services.homepage.services."ipfs-gateway".icon = "https://raw.githubusercontent.com/ipfs/ipfs-webui/refs/heads/main/src/navigation/ipfs-logo.svg";
    })
    (mkIf (cfg.enable && config.MODULES.services.roundcube.enable) {
      MODULES.services.homepage.services.roundcube.icon = "/roundcube/skins/elastic/images/favicon.ico";
    })
    (mkIf (cfg.enable && config.MODULES.services.nextcloud.enable) {
      MODULES.services.homepage.services.nextcloud.icon = "/nextcloud/core/img/logo/logo.svg";
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
