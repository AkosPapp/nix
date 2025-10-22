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
      hostAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "List of hostnames to associate with this Tailscale node.";
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
    };
  };

  config = lib.mkIf config.MODULES.networking.tailscale.enable {
    assertions = [
      {
        assertion = (config.MODULES.networking.tailscale.hostAliases == []) || (config.MODULES.networking.tailscale.hostIP != null && config.MODULES.networking.tailscale.tailnetDnsName != null);
        message = "[" + configName + "] When Tailscale is enabled and hostAliases is not empty, both hostIP and tailnetDnsName must be set.";
      }
    ];

    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = ["--accept-dns=true" "--accept-routes=true"];
      package = pkgs-unstable.tailscale;
    };
    networking.firewall.checkReversePath = "loose";
    networking.hosts =
      lib.attrsets.mapAttrs' (
        name: config: {
          name = "${config.config.MODULES.networking.tailscale.hostIP}";
          value = (
            lib.mapCartesianProduct ({
              alias,
              base,
            }: "${alias}.${base}")
            {
              alias =
                config.config.MODULES.networking.tailscale.hostAliases;
              base = [
                "${name}.${config.config.MODULES.networking.tailscale.tailnetDnsName}"
                "${name}"
              ];
            }
          );
        }
      )
      (
        lib.attrsets.filterAttrs
        (name: config: config.config.MODULES.networking.tailscale.hostIP != null)
        nixosConfigurations
      );

    networking = {
      domain = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
      fqdn = "${configName}.${config.MODULES.networking.tailscale.tailnetDnsName}";
    };
  };
}
