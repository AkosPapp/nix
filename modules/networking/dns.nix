{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.MODULES.networking.dns;
  traefik = config.MODULES.networking.traefik;
  ip = config.MODULES.networking.tailscale.hostIP;
in {
  options.MODULES.networking.dns.enable = mkOption {
    type = types.bool;
    default = traefik.enable;
    defaultText = literalExpression "config.MODULES.networking.traefik.enable";
    description = ''
      Authoritative DNS for this host's Traefik zone: one record per entry of
      `MODULES.networking.traefik.services`, all pointing at the host's tailscale IP. It answers
      nothing outside that zone. Clients reach it through split DNS in the Tailscale admin console
      (domain = the host name, nameserver = the host's tailscale IP).
    '';
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = ip != null;
        message = "MODULES.networking.dns needs MODULES.networking.tailscale.hostIP to be set.";
      }
    ];

    services.dnsmasq = {
      enable = true;
      # The default would make this the machine's own resolver, and with no upstream that would
      # break every lookup that isn't in the zone.
      resolveLocalQueries = false;
      settings = {
        port = config.PORTS.dns;
        listen-address = ["127.0.0.1" ip];
        # The tailscale address doesn't exist until tailscaled is up.
        bind-dynamic = true;
        no-resolv = true;
        no-hosts = true;
        # Authoritative for the zone: unknown names are NXDOMAIN, never forwarded.
        local = ["/${traefik.domain}/"];
        # The bare zone name too (exact match only, so unknown names under it stay NXDOMAIN).
        host-record = ["${traefik.domain},${ip}"];
        address = map (name: "/${traefik.hostOf name}/${ip}") (attrNames traefik.services);
      };
    };

    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [config.PORTS.dns];
      allowedTCPPorts = [config.PORTS.dns];
    };
  };
}
