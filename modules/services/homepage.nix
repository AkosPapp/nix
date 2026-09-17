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
      # Homepage is the site's front door, so its icon is the one to hand out at the origin root.
      # The path here is the backend's, not the proxied one: Traefik strips "/homepage" before
      # forwarding, so what answers on 8082 is /homepage.ico.
      MODULES.networking.traefik.favicon = "http://127.0.0.1:${toString config.PORTS.homepage}/homepage.ico";

      MODULES.services.homepage.services.homepage.icon = "/homepage/homepage.ico";
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
        href = "/grafana";
        icon = "/grafana/public/img/fav32.png";
        widget = {
          type = "grafana";
          version = 2;
          url = "http://127.0.0.1:${toString config.PORTS.grafana}/grafana/";
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
        href = "/prometheus";
        icon = "/prometheus/favicon.svg";
        widget = {
          type = "prometheus";
          url = "http://127.0.0.1:${toString config.PORTS.prometheus}/prometheus/";
        };
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.loki.enable) {
      # Loki has no web UI of its own (just an HTTP push/query API) - logs are actually browsed
      # through Grafana's Explore view instead, using the Loki datasource wired up in loki.nix.
      MODULES.services.homepage.services.loki = {
        href = "/grafana/explore";
        icon = "loki.png";
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
    (mkIf (cfg.enable && config.MODULES.services.immich.enable) {
      # Immich isn't behind Traefik (see immich.nix - its clients need the API at the server
      # root), so it gets an absolute href to its own Tailscale-served port instead of a subpath.
      MODULES.services.homepage.services.immich = {
        href = "https://${config.networking.fqdn}:${toString config.PORTS.immich}";
        icon = "immich.png";
      };
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
        icon = "litellm.png";
        # The UI lives on the shared Traefik origin (litellm.nix sets SERVER_ROOT_PATH to
        # match), so this is a subpath like grafana's rather than an absolute href to a port of
        # its own - even though the API does have such an origin, which is not what a link on a
        # dashboard wants to open. Falls back to that origin if the Traefik route is turned off.
        href =
          if config.MODULES.services.litellm.traefikPath != null && config.MODULES.networking.traefik.enable
          then config.MODULES.services.litellm.traefikPath
          # The tailscale-serve origin has no landing page of its own at the root, so link
          # straight to the UI, under whatever prefix the gateway mounts it at.
          else "https://${config.networking.fqdn}:${toString config.PORTS.litellm}${
            lib.optionalString (config.MODULES.services.litellm.rootPath != null) config.MODULES.services.litellm.rootPath
          }/ui";
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
      # Open WebUI has an origin of its own rather than a path on this one (see open-webui.nix),
      # so it isn't in path_routes and the generic block at the bottom never picks it up - hence
      # the absolute href, same as immich above. No widget: homepage has no open-webui
      # integration, and everything Open WebUI reports about itself past /health sits behind an
      # API key that would have to be minted by hand in the UI first.
      MODULES.services.homepage.services.open-webui = {
        href = "https://${config.networking.fqdn}:${toString config.PORTS.openWebui}";
        icon = "open-webui.png";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.mcp-switchboard.enable) {
      # The console lives on its own tailscale-serve origin, not a Traefik subpath (see
      # mcp-switchboard.nix). No bundled dashboard-icons entry exists for this one, so an MDI
      # glyph instead of a guessed png that would just come back broken.
      MODULES.services.homepage.services.mcp-switchboard = {
        icon = "mdi-graph-outline";
        href = "https://${config.networking.fqdn}:${toString config.PORTS.mcpSwitchboardPrivate}";
        description = "MCP gateway/registry";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.librechat.enable) {
      # Own tailscale-serve origin, not a Traefik subpath (see librechat.nix) - same
      # reverse-proxy-subpath reasoning as open-webui and n8n above.
      MODULES.services.homepage.services.librechat = {
        href = "https://${config.networking.fqdn}:${toString config.PORTS.librechat}";
        icon = "librechat.png";
        description = "MCP-tool chat UI";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.n8n.enable) {
      # No Traefik route (see n8n.nix), so an absolute href to its own tailscale-serve origin -
      # same pattern as open-webui and immich above, for the same reverse-proxy-subpath reason.
      MODULES.services.homepage.services.n8n = {
        href = "https://${config.networking.fqdn}:${toString config.PORTS.n8n}";
        icon = "n8n.png";
        description = "Agent workflow builder";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.syncthing.enable) {
      MODULES.services.homepage.services.syncthing = {
        href = "/syncthing";
        icon = "syncthing.png";
      };
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
