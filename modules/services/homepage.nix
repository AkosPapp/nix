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

    omnirouteKeyFile = mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression "config.MODULES.services.omniroute.keys.homepage.envFilePath";
      description = ''
        Path to a dotenv file holding the OmniRoute key the gateway tile's /v1/models
        probe authenticates with, as `HOMEPAGE_VAR_OMNIROUTE_API_KEY=sk-...`. On the
        GATEWAY host set this to a nix-minted per-service key (audit #7, 2026-11-14):
        the file rides services.homepage-dashboard.environmentFiles, which systemd
        parses root-side at every start (the homepage process itself never reads the
        keys dir, so it may stay 0700 root), and the widget's
        {{HOMEPAGE_VAR_OMNIROUTE_API_KEY}} placeholder is substituted from the unit
        environment. null (default) = the sops-mounted shared omniroute_api_key via
        the old HOMEPAGE_FILE_ mount, unchanged for non-gateway hosts.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      # A static service user instead of the nixpkgs module's DynamicUser. The random per-boot
      # uid is why the widget secrets below used to be 0444 world-readable (an unguessable
      # owner cannot be named as a sops owner) - with a fixed uid they are 0400, this user
      # only (2026-10-24 audit #5). The unit keeps PrivateUsers, which maps this uid to root
      # inside the namespace, so the *owner* bits still apply to a 0400 secret on the host.
      users.users.homepage-dashboard = {
        isSystemUser = true;
        group = "homepage-dashboard";
      };
      users.groups.homepage-dashboard = {};

      systemd.services.homepage-dashboard.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "homepage-dashboard";
        Group = "homepage-dashboard";
      };
      # audit #7: with omnirouteKeyFile set, the key arrives as a systemd environmentFile -
      # a MISSING one fails the start, and on a wiped dataset the mint unit creates it only
      # after the gateway is up. Ordering (not Requires: the tile works without the key, and
      # After= against a unit that does not exist is a no-op on non-gateway hosts).
      systemd.services.homepage-dashboard.after =
        lib.optionals (config.MODULES.services.omniroute.enable && config.MODULES.services.homepage.omnirouteKeyFile != null)
        ["omniroute-seed-providers.service"];

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
                # Add default href/icon if not set by user. `enabled` is this module's
                # control key, not homepage-dashboard's - strip it from the entry.
                ${name} =
                  if lib.isAttrs config
                  then builtins.removeAttrs config ["enabled"]
                  else config;
              })
              # A module can hide a service by merging `enabled = false` into its entry
              # (homepage-dashboard itself has no per-service hide flag - every entry in
              # services.yaml renders, checked against the v1.12.3 source). Used for
              # gateway alias subdomains (omniroute.nix's subdomainAliases): litellm.hp
              # answers from OmniRoute now and must not earn a duplicate tile.
              (lib.filterAttrs
                (
                  _: config:
                    (
                      if lib.isAttrs config
                      then config.enabled or true
                      else true
                    )
                    != false
                )
                config.MODULES.services.homepage.services)
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
      # A second sops.secrets declaration pointing at the *same* underlying value (via `key`)
      # as grafana.nix's own, because that one is owned by the grafana uid. Readable by the
      # homepage-dashboard uid alone - static since the DynamicUser switch above.
      sops.secrets."homepage/grafana_admin_password" = {
        key = "grafana/admin_password";
        owner = "homepage-dashboard";
        mode = "0400";
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
      # Same pattern as the grafana block above: a second declaration pointing at the one
      # underlying token, owned by the homepage-dashboard uid. The token itself has to be
      # minted from inside Firefly III, so this whole block is gated behind an option that is
      # off until someone has done that.
      sops.secrets."homepage/firefly_api_token" = {
        key = "firefly-iii/homepage-api-token";
        owner = "homepage-dashboard";
        mode = "0400";
      };

      systemd.services.homepage-dashboard.environment.HOMEPAGE_FILE_FIREFLY_API_TOKEN =
        config.sops.secrets."homepage/firefly_api_token".path;

      MODULES.services.homepage.services.firefly.widget = {
        type = "firefly";
        url = "http://127.0.0.1:${toString config.PORTS.fireflyIii}";
        key = "{{HOMEPAGE_FILE_FIREFLY_API_TOKEN}}";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.omniroute.enable) (let
      # audit #7 (2026-11-14): two key paths for the /v1/models probe. Minted (gateway
      # host): the keys.<n>.envFilePath dotenv (line `HOMEPAGE_VAR_OMNIROUTE_API_KEY=...`,
      # set the key's envVar to match) rides environmentFiles - systemd parses it root-
      # side at every start, so the homepage process never needs to read the (0700 root)
      # keys dir and a re-mint lands on a plain restart; the widget placeholder then uses
      # homepage's process-env substitution ({{HOMEPAGE_VAR_*}} - both prefixes verified
      # in the live 1.12.3 bundle). sops (everywhere else, default): the old
      # HOMEPAGE_FILE_ mount, homepage-dashboard-owned 0400.
      minted = cfg.omnirouteKeyFile != null;
    in {
      # Homepage has no gateway widget, but /v1/models is a plain JSON endpoint (any
      # valid OmniRoute inference key authenticates), so customapi can report how many
      # models the gateway currently routes. That count is the gateway's whole
      # connected inventory, not anything host-local. Same pattern as grafana above:
      # a second declaration of the shared sops value, readable by the
      # homepage-dashboard uid alone (2026-10-24 audit #5 doctrine). (Was litellm's
      # master-key pair of blocks until phase 3, 2026-11-09.)
      sops.secrets."homepage/omniroute_api_key" = mkIf (!minted) {
        key = "omniroute_api_key";
        owner = "homepage-dashboard";
        mode = "0400";
      };

      services.homepage-dashboard.environmentFiles =
        lib.optionals minted [cfg.omnirouteKeyFile];

      systemd.services.homepage-dashboard.environment.HOMEPAGE_FILE_OMNIROUTE_API_KEY =
        mkIf (!minted) config.sops.secrets."homepage/omniroute_api_key".path;

      MODULES.services.homepage.services.omniroute = {
        icon = "${traefik.urlOf "omniroute"}/favicon.svg";
        # The dashboard itself - unlike litellm's /ui, the gateway's UI is its root.
        href = traefik.urlOf "omniroute";
        description = "AI gateway";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:${toString config.PORTS.omniroute}/v1/models";
          headers = {
            # The placeholder names whichever env channel feeds the key (see above):
            # minted -> substituted from the unit environment the dotenv populated;
            # sops -> substituted from the 0400 mount homepage reads itself.
            Authorization = "Bearer {{${
              if minted
              then "HOMEPAGE_VAR"
              else "HOMEPAGE_FILE"
            }_OMNIROUTE_API_KEY}}";
          };
          mappings = [
            {
              field = "data";
              label = "Models";
              format = "size";
            }
          ];
        };
      };
    }))
    (mkIf (cfg.enable && config.MODULES.services.open-webui.enable) {
      # No widget: homepage has no open-webui integration, and everything Open WebUI reports
      # about itself past /health sits behind an API key that would have to be minted by hand in
      # the UI first.
      MODULES.services.homepage.services.open-webui.icon = "open-webui.png";
    })
    (mkIf (cfg.enable && config.MODULES.services.coroot.enable) {
      MODULES.services.homepage.services.coroot = {
        description = "Full-stack observability";
        # Coroot's own vhost serves it unauthenticated at /static; the generic
        # per-service <name>/favicon.ico guess below lands on coroot's HTML 404 page, so
        # pin the real file (surfaces when the tile hits COROOT's UI for the first time).
        icon = "${traefik.urlOf "coroot"}/static/favicon.ico";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.matrix.enable) {
      # Synapse's root page is only a "it works" stub, so the matrix tile is there to show the
      # homeserver is up; Element is the one to click.
      MODULES.services.homepage.services.element = {
        icon = "element.png";
        description = "Matrix chat (${config.MODULES.services.matrix.serverName})";
      };
      MODULES.services.homepage.services.matrix = {
        icon = "synapse.png";
        description = "Matrix homeserver";
        siteMonitor = "${config.MODULES.services.matrix.clientUrl}/health";
      };
    })
    # mdbook lives under a path of the Funnel URL (traefik.nix's `public`), not as a
    # <service>.<host> entry, so it doesn't get a tile from the catch-all block at the bottom.
    (mkIf (cfg.enable && config.MODULES.services.mdbook.enable) {
      MODULES.services.homepage.services.mdbook = {
        href = traefik.funnel.urlOf "/mdbook/";
        # The docs' own favicon (mdbook.nix symlinks this stable name next to the theme's
        # content-hashed ones). Behind the login gate, but tile icons load in the browser,
        # which carries the /mdbook session cookie.
        icon = traefik.funnel.urlOf "/mdbook/favicon.svg";
        description = "Docs (public, robo4you login)";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.outline.enable) {
      # Outline is a <service>.<host> entry (traefik.services), so the catch-all block at the
      # bottom already gives it a tile with the tailnet URL as href - override both once it's
      # also on its own Funnel port (outline.nix: no path-prefix support, so it isn't a path on
      # traefik.funnel like mdbook below).
      MODULES.services.homepage.services.outline = {
        href = "${config.MODULES.services.outline.url}/";
        icon = "outline.png";
        description =
          if config.MODULES.services.outline.public.enable
          then "Wiki/notes (public, robo4you login)"
          else "Wiki/notes (tailnet-only)";
      };
    })
    (mkIf (cfg.enable && config.MODULES.services.hermes-agent.enable) {
      # The dashboard serves its own favicon unauthenticated (only the app itself needs the
      # password), so link it straight.
      MODULES.services.homepage.services.hermes = {
        icon = "${traefik.urlOf "hermes"}/favicon.ico";
        description = "Hermes agent dashboard";
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
      # (A module that wants one of these tiles GONE - e.g. omniroute.nix hiding its
      # subdomainAliases duplicates - merges `enabled = false` into the entry; the
      # render path below drops those. traefik.services values are plain backend
      # strings here, so the flag cannot ride this map itself.)
      MODULES.services.homepage.services =
        lib.mapAttrs (name: _: {
          href = lib.mkDefault (traefik.urlOf name);
          icon = lib.mkDefault "${traefik.urlOf name}/favicon.ico";
        })
        traefik.services;
    }
  ];
}
