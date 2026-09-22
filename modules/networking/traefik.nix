{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}:
with lib; let
  cfg = config.MODULES.networking.traefik;
  ca = config.MODULES.networking.step-ca;

  # "127.0.0.1:8093" -> "http://127.0.0.1:8093"; anything that already carries a scheme is left alone.
  toUrl = target:
    if hasInfix "://" target
    then target
    else "http://${target}";
in {
  options.MODULES.networking.traefik = {
    enable = mkEnableOption "Traefik reverse proxy";

    domain = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = literalExpression "config.networking.hostName";
      description = ''
        Zone this host serves. Every entry in `services` is published as `<name>.<domain>`, so on
        a host called hp the `firefly` entry answers at https://firefly.hp. The DNS server in
        dns.nix is authoritative for this zone and step-ca only issues names inside it.
      '';
    };

    services = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = literalExpression ''
        {
          firefly = "127.0.0.1:8093";
          grafana = "http://127.0.0.1:8030";
        }
      '';
      description = ''
        service name -> backend. The name becomes the subdomain, the value is `host:port` (plain
        HTTP) or a full `scheme://host:port` URL. Each entry gets a DNS record, a router on the
        HTTPS entry point and a certificate from the local step-ca.
      '';
    };

    defaultService = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "homepage";
      description = ''
        Service that the bare zone name (https://hp) redirects to, or null to leave it unrouted.
      '';
    };

    hostOf = mkOption {
      type = types.raw;
      readOnly = true;
      default = name: "${name}.${cfg.domain}";
      description = "Function: service name -> its hostname (`firefly` -> `firefly.hp`).";
    };

    urlOf = mkOption {
      type = types.raw;
      readOnly = true;
      default = name: "https://${cfg.hostOf name}";
      description = "Function: service name -> its public URL (`firefly` -> `https://firefly.hp`).";
    };
  };

  config = mkIf cfg.enable {
    MODULES.networking.traefik.services.traefik = "127.0.0.1:${toString config.PORTS.traefikDashboard}";

    services.traefik = {
      enable = true;

      staticConfigOptions = {
        entryPoints = {
          # Plain HTTP only exists to bounce to HTTPS (the catch-all router below). It is a
          # router rather than an entry point redirect so that other modules can claim specific
          # plain-HTTP paths ahead of it - step-ca.nix serves the root certificate that way, since
          # a phone can't fetch it over HTTPS before it trusts the CA. The ACME http-01 challenge
          # is answered ahead of both.
          web.address = ":${toString config.PORTS.traefikHttp}";
          websecure.address = ":${toString config.PORTS.traefikHttps}";
          traefik.address = "127.0.0.1:${toString config.PORTS.traefikDashboard}";
        };

        # The certificate for every router comes from this host's own step-ca (step-ca.nix).
        # step-ca hands out 90 day certs (see its claims) so the resolver's renewal window matches.
        certificatesResolvers.stepca.acme = {
          caServer = "https://127.0.0.1:${toString config.PORTS.stepCa}/acme/acme/directory";
          storage = "${config.services.traefik.dataDir}/acme.json";
          certificatesDuration = 2160;
          httpChallenge.entryPoint = "web";
        };

        api = {
          dashboard = true;
          insecure = true;
        };

        log.level = "INFO";
        accessLog = {};
      };

      dynamicConfigOptions.http = {
        middlewares =
          {
            https-redirect.redirectScheme = {
              scheme = "https";
              permanent = true;
            };
          }
          // optionalAttrs (cfg.defaultService != null) {
            default-service-redirect.redirectRegex = {
              regex = "^.*$";
              replacement = cfg.urlOf cfg.defaultService;
              permanent = false;
            };
          };

        routers =
          {
            http-redirect = {
              rule = "PathPrefix(`/`)";
              entryPoints = ["web"];
              middlewares = ["https-redirect"];
              service = "noop@internal";
              priority = 1;
            };
          }
          // optionalAttrs (cfg.defaultService != null) {
            default-service = {
              rule = "Host(`${cfg.domain}`)";
              entryPoints = ["websecure"];
              middlewares = ["default-service-redirect"];
              service = "noop@internal";
              tls.certResolver = "stepca";
            };
          }
          // mapAttrs (name: _: {
            rule = "Host(`${cfg.hostOf name}`)";
            service = name;
            entryPoints = ["websecure"];
            tls.certResolver = "stepca";
          })
          cfg.services;

        services =
          mapAttrs (_: target: {
            loadBalancer.servers = [{url = toUrl target;}];
          })
          cfg.services;
      };
    };

    systemd.services.traefik = {
      # lego (Traefik's ACME client) reads this to trust step-ca's certificate, which is signed by
      # our own root and so isn't in any default trust store it ships with.
      environment.LEGO_CA_CERTIFICATES = "${ca.rootCertFile}";
      after = ["step-ca.service" "tailscaled.service" "network-online.target"];
      wants = ["step-ca.service" "tailscaled.service" "network-online.target"];
      # http-01 validation connects to <name>.<domain>, which the local DNS answers with this
      # host's tailscale IP. Traefik only asks for certificates once, when it loads its config,
      # so hold it back until that address exists rather than losing the first attempt.
      serviceConfig.ExecStartPre = "+${pkgs.bash}/bin/bash -c 'until ${pkgs-unstable.tailscale}/bin/tailscale ip -4 >/dev/null 2>&1; do sleep 1; done'";
    };

    # Only the tailnet talks to Traefik - the DNS records all point at the tailscale IP.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
      config.PORTS.traefikHttp
      config.PORTS.traefikHttps
    ];
  };
}
