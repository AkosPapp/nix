{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types mapAttrsToList;

  cfg = config.MODULES.services.homepage;
  traefik = config.MODULES.networking.traefik;
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
            url = "${traefik.urlOf "searx"}/search?q=";
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
        HOMEPAGE_ALLOWED_HOSTS = lib.mkForce "${traefik.hostOf "homepage"},${config.networking.fqdn},${config.networking.hostName}.airlab,${config.networking.hostName}";
        HOSTNAME = "127.0.0.1";
      };

      MODULES.networking.traefik.enable = true;
      MODULES.networking.traefik.defaultService = "homepage";
      MODULES.networking.traefik.services.homepage = "127.0.0.1:${toString config.PORTS.homepage}";

      MODULES.services.homepage.services.homepage.icon = "${traefik.urlOf "homepage"}/homepage.ico";
    })
    (mkIf (cfg.enable && config.MODULES.services.grafana.enable) {
      # homepage-dashboard runs with systemd's DynamicUser (a random per-boot uid), so it can't
      # be granted read access to grafana.nix's own admin_password secret (owner = "grafana",
      # mode 0400) the same way grafana itself is. This is a second sops.secrets declaration
      # pointing at the *same* underlying value (via `key`) but world-readable, since the
      # dynamic uid can't be predicted ahead of time to target it more narrowly.
      sops.secrets."homepage/grafana_admin_password" = {
        key = "grafana/admin_password";
        mode = "0444";
      };

      systemd.services.homepage-dashboard.environment.HOMEPAGE_FILE_GRAFANA_PASSWORD =
        config.sops.secrets."homepage/grafana_admin_password".path;

      MODULES.services.homepage.services.grafana = {
        icon = "${traefik.urlOf "grafana"}/public/img/fav32.png";
        widget = {
          type = "grafana";
          version = 2;
          url = "http://127.0.0.1:${toString config.PORTS.grafana}/";
          username = "admin";
          # {{HOMEPAGE_FILE_X}} is homepage's own templating syntax: it substitutes the contents
          # of the file at $HOMEPAGE_FILE_X, so the actual password never has to be embedded in
          # this config (which ends up world-readable in the Nix store).
          password = "{{HOMEPAGE_FILE_GRAFANA_PASSWORD}}";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.prometheus.enable) {
      MODULES.services.homepage.services.prometheus = {
        icon = "${traefik.urlOf "prometheus"}/favicon.svg";
        widget = {
          type = "prometheus";
          url = "http://127.0.0.1:${toString config.PORTS.prometheus}/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.loki.enable) {
      # Loki has no web UI of its own (just an HTTP push/query API) - logs are actually browsed
      # through Grafana's Explore view instead, using the Loki datasource wired up in loki.nix.
      MODULES.services.homepage.services.loki = {
        href = "${traefik.urlOf "grafana"}/explore";
        icon = "loki.png";
      };
    })
    (mkIf (cfg.enable && config.MODULES.networking.traefik.enable) {
      MODULES.services.homepage.services.traefik = {
        icon = "${traefik.urlOf "traefik"}/dashboard/favicon.ico";
        widget = {
          type = "traefik";
          url = "http://127.0.0.1:${toString config.PORTS.traefikDashboard}/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.sftpgo.enable) {
      MODULES.services.homepage.services.sftpgo.icon = "${traefik.urlOf "sftpgo"}/static/favicon.png";
      MODULES.services.homepage.services.webdav.icon = "${traefik.urlOf "sftpgo"}/static/favicon.png";
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
      MODULES.services.homepage.services.roundcube.icon = "${traefik.urlOf "roundcube"}/skins/elastic/images/favicon.ico";
    })
    (mkIf (cfg.enable && config.MODULES.services.nextcloud.enable) {
      MODULES.services.homepage.services.nextcloud.icon = "${traefik.urlOf "nextcloud"}/core/img/logo/logo.svg";
    })
    (mkIf (cfg.enable && config.MODULES.services.immich.enable) {
      MODULES.services.homepage.services.immich.icon = "immich.png";
    })
    (mkIf (cfg.enable && config.MODULES.services.firefly-iii.enable) {
      MODULES.services.homepage.services.firefly.icon = "firefly-iii.png";
    })
    (mkIf (cfg.enable && config.MODULES.services.firefly-iii.homepageWidget.enable) {
      # Same trick as the grafana block above: a second, world-readable sops declaration pointing
      # at the one underlying token, because homepage-dashboard's DynamicUser can't be named as an
      # owner ahead of time. The token itself has to be minted from inside Firefly III, so this
      # whole block is gated behind an option that is off until someone has done that.
      sops.secrets."homepage/firefly_api_token" = {
        key = "firefly-iii/homepage-api-token";
        mode = "0444";
      };

      systemd.services.homepage-dashboard.environment.HOMEPAGE_FILE_FIREFLY_API_TOKEN =
        config.sops.secrets."homepage/firefly_api_token".path;

      MODULES.services.homepage.services.firefly.widget = {
        type = "firefly";
        url = "http://127.0.0.1:${toString config.PORTS.fireflyIii}";
        key = "{{HOMEPAGE_FILE_FIREFLY_API_TOKEN}}";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.litellm.enable && config.MODULES.services.litellm.masterKeySecret != null) {
      # /v1/models needs the gateway's master key. Same trick as grafana above: a second,
      # world-readable declaration of the same sops value, since homepage's DynamicUser uid
      # can't be targeted. That makes the gateway's admin key readable by any local user on this
      # host - acceptable on a single-user server, and the reason to swap it for a read-only
      # virtual key minted in the LiteLLM UI if that ever stops being true.
      sops.secrets."homepage/litellm_master_key" = {
        key = config.MODULES.services.litellm.masterKeySecret;
        mode = "0444";
      };

      systemd.services.homepage-dashboard.environment.HOMEPAGE_FILE_LITELLM_MASTER_KEY =
        config.sops.secrets."homepage/litellm_master_key".path;

      MODULES.services.homepage.services.litellm.widget.headers = {
        Authorization = "Bearer {{HOMEPAGE_FILE_LITELLM_MASTER_KEY}}";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.litellm.enable) {
      # Homepage has no LiteLLM widget, but /v1/models is a plain JSON endpoint (authenticated
      # with the master key set up in the block above), so customapi can report how many models
      # the gateway is currently routing. That count is the whole catalogue across every host in
      # the flake, not what happens to be loaded: the vLLM instances behind it are
      # socket-activated, so "available" and "resident in memory" are deliberately different
      # things here and only the former is observable from outside.
      MODULES.services.homepage.services.litellm = {
        icon = "${traefik.urlOf "litellm"}/ui/favicon.ico";
        # The origin has no landing page of its own at the root, so link straight to the UI.
        href = "${traefik.urlOf "litellm"}/ui";
        description = "LLM gateway";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:${toString config.PORTS.litellm}/v1/models";
          mappings = [
            {
              field = "data";
              label = "Models";
              format = "size";
            }
          ];
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.open-webui.enable) {
      # No widget: homepage has no open-webui integration, and everything Open WebUI reports
      # about itself past /health sits behind an API key that would have to be minted by hand in
      # the UI first.
      MODULES.services.homepage.services.open-webui.icon = "open-webui.png";
    })
    (mkIf (cfg.enable && config.MODULES.services.mcp-switchboard.enable) {
      MODULES.services.homepage.services.mcp-switchboard = {
        icon = "${traefik.urlOf "mcp-switchboard"}/static/favicon.svg";
        description = "MCP gateway/registry";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.omniroute.enable) {
      MODULES.services.homepage.services.omniroute = {
        icon = "${traefik.urlOf "omniroute"}/favicon.svg";
        description = "AI gateway";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.librechat.enable) {
      MODULES.services.homepage.services.librechat = {
        icon = "librechat.png";
        description = "MCP-tool chat UI";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.n8n.enable) {
      MODULES.services.homepage.services.n8n = {
        icon = "n8n.png";
        description = "Agent workflow builder";
      };
    })
    (mkIf (cfg.enable && traefik.services ? ca) {
      MODULES.services.homepage.services.ca = {
        icon = "${traefik.urlOf "ca"}/favicon.svg";
        description = "Root CA";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.syncthing.enable) {
      MODULES.services.homepage.services.syncthing.icon = "syncthing.png";
    })
    {
      # Every Traefik service gets a tile that links to it; the blocks above override the icon
      # (and href, where the landing page isn't the root) for the ones that need it.
      MODULES.services.homepage.services =
        lib.mapAttrs (name: _: {
          href = lib.mkDefault (traefik.urlOf name);
          icon = lib.mkDefault "${traefik.urlOf name}/favicon.ico";
        })
        traefik.services;
    }
  ];
}
