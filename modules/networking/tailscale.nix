{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  nixosConfigurations,
  configName,
  ...
}: let
  # Submodule which validates a single "serve" configuration
  serveSubmodule = {config, ...}: {
    options = {
      type = lib.mkOption {
        type = lib.types.enum ["serve" "funnel"];
        default = "serve";
        description = "Type identifier for this submodule; must be 'serve' or 'funnel'.";
      };

      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Target for the serve command (e.g., 'https://localhost:3000', '/path/to/file', or 'text:Hello').";
      };

      httpPort = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Expose an HTTP server at the specified port. only with 'serve' type.";
      };

      httpsPort = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Expose an HTTPS server at the specified port.";
      };

      service = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Serve for a service with distinct virtual IP instead on node itself.";
      };

      setPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Appends the specified path to the base URL for accessing the underlying service.";
      };

      tcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [];
        description = "Expose TCP forwarders at the specified ports.";
      };

      tlsTermTcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.int;
        default = [];
        description = "Expose TLS-terminated TCP forwarders at the specified ports.";
      };

      tun = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Forward all traffic to the local machine (default false). Only supported for services.";
      };

      yes = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Update without interactive prompts (default false).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional arbitrary flags passed to 'tailscale serve'.";
      };
    };
  };
in {
  options = {
    MODULES.networking.tailscale = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Tailscale VPN";
      };
      hostIP = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The Tailscale IP address of this node.";
      };
      tailnetDnsName = lib.mkOption {
        type = lib.types.str;
        default = "tail546fb.ts.net";
        description = "The Tailnet DNS name of this node.";
      };
      cert = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable automatic TLS certificate generation via Tailscale.";
        };
        domain = lib.mkOption {
          type = lib.types.str;
          default = config.networking.fqdn;
          description = "The domain name for the TLS certificate.";
        };
        certFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/tailscale/cert.pem";
          description = "Path to the TLS certificate file.";
        };
        keyFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/tailscale/key.pem";
          description = "Path to the TLS key file.";
        };
      };

      serve = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule serveSubmodule);
        default = {};
        description = ''
          Attribute set of serve configurations. The attribute name is used as the service name. Example:
            serve = {
              "my-service" = {
                type = "serve";
                httpsPort = 443;
                yes = true;
              };
              "my-other-service" = {
                type = "funnel";
                httpPort = 80;
                setPath = "/app";
              };
            };
          For each entry the following optional keys are supported:
            - type (enum: "serve" | "funnel", default: "serve")
            - target (null | string)
            - httpPort (null | int)
            - httpsPort (null | int)
            - service (null | string)
            - setPath (null | string)
            - tcpPorts (list of ints)
            - tlsTermTcpPorts (list of ints)
            - tun (bool)
            - yes (bool)
            - extraArgs (list of strings)
        '';
      };
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable (
    let
      serveAttrs = config.MODULES.networking.tailscale.serve;

      buildServeFlags = s: let
        httpFlag =
          if s.httpPort == null
          then ""
          else "--http ${toString s.httpPort}";
        httpsFlag =
          if s.httpsPort == null
          then ""
          else "--https ${toString s.httpsPort}";
        serviceFlag =
          if s.service == null
          then ""
          else "--service ${s.service}";
        setPathFlag =
          if s.setPath == null
          then ""
          else "--set-path ${s.setPath}";
        tcpFlags = lib.concatStringsSep " " (lib.map (p: "--tcp ${toString p}") (s.tcpPorts or []));
        tlsTermFlags = lib.concatStringsSep " " (lib.map (p: "--tls-terminated-tcp ${toString p}") (s.tlsTermTcpPorts or []));
        tunFlag =
          if s.tun
          then "--tun"
          else "";
        yesFlag =
          if s.yes
          then "--yes"
          else "";
        extra = lib.concatStringsSep " " (s.extraArgs or []);
      in
        lib.concatStringsSep " " (lib.filter (x: x != "") [httpFlag httpsFlag serviceFlag setPathFlag tcpFlags tlsTermFlags tunFlag yesFlag extra]);

      servicesAttrset =
        lib.mapAttrs' (
          name: s: let
            serviceType = s.type;
            targetArg =
              if s.target != null
              then s.target
              else "";
            svc = {
              description = "Tailscale ${serviceType} ${name}";
              after = ["tailscaled.service" "network.target"];
              wants = ["tailscaled.service"];
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                ExecStart = "${pkgs-unstable.tailscale}/bin/tailscale ${serviceType} ${buildServeFlags s} ${targetArg}";
                User = "root";
                Restart = "always";
              };
            };
          in
            lib.nameValuePair "tailscale-${serviceType}-${name}" svc
        )
        serveAttrs;
    in {
      services.tailscale = {
        enable = true;
        openFirewall = true;
        extraSetFlags = ["--accept-dns=true" "--accept-routes=true"];
        package = pkgs-unstable.tailscale;
      };

      networking = {
        firewall.checkReversePath = "loose";
        domain = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
        fqdn = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
      };

      systemd.services =
        {
          tailscale-cert-renewal = lib.mkIf config.MODULES.networking.tailscale.cert.enable {
            description = "Tailscale Certificate Renewal Service";
            after = ["network.target" "tailscaled.service"];
            wants = ["tailscaled.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "/bin/sh -c \'${pkgs.coreutils}/bin/mkdir -p /var/lib/tailscale && ${pkgs-unstable.tailscale}/bin/tailscale cert --cert-file ${config.MODULES.networking.tailscale.cert.certFile} --key-file ${config.MODULES.networking.tailscale.cert.keyFile} ${config.MODULES.networking.tailscale.cert.domain}\'";
              User = "root";
              Group = "root";
            };
          };
        }
        // servicesAttrset;
    }
  );
}
