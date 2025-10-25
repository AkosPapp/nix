{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  nixosConfigurations,
  configName,
  ...
}: {
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
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable {
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

    systemd.services.tailscale-cert-renewal = lib.mkIf config.MODULES.networking.tailscale.cert.enable {
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
  };
}
