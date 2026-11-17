# Shared NetBird client policy. DNS belongs to split-dns/dnsmasq, never to
# NetBird's resolver manager (legion5's existing policy, extended to hp
# 2026-11-10). Enrollment and network selections persist in /var/lib/netbird;
# identities/setup keys are never put into the Nix store.
{
  config,
  lib,
  ...
}: let
  cfg = config.MODULES.networking.netbird;
in {
  options.MODULES.networking.netbird = {
    enable = lib.mkEnableOption "NetBird client with fleet split-DNS ownership and subnet-route support";
    managementUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://netbird.robo4you.at";
      description = "Management endpoint used by the NetBird CLI for interactive enrollment; no credentials included.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.netbird = {
      enable = true;
      useRoutingFeatures = "client";
      clients.default = {
        autoStart = true;
        port = config.PORTS.netbirdWireguard;
        environment = {
          NB_DISABLE_DNS = "true";
          NB_MANAGEMENT_URL = cfg.managementUrl;
        };
        config.DisableDNS = true;
      };
    };
  };
}
