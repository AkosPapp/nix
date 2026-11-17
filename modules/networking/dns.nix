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
  options.MODULES.networking.dns = {
    enable = mkOption {
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

    aliases = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["datalab"];
      description = ''
        Extra names inside the zone that resolve to THIS host's tailscale IP, emitted as
        `address=` records next to the ones `MODULES.networking.traefik.services` implies.
        DNS only: no listener, no router, no Traefik entry. The use case is an ssh client
        that keys its saved hosts by hostname and so cannot hold one host twice under one
        name - the phone reaches hp's second terminal account as `datalab.hp`, the same
        sshd and the same IP as `hp`/`hermes.hp` (2026-11-11; the rationale outlived the
        pairing pages it was first written for - retired 2026-11-14, audit #9).
      '';
    };
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
      # The default would make this the machine's own resolver; with no upstream here that would
      # break every lookup outside the zone. Hosts that add upstreams opt back in (legion5 does).
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
        address =
          map (name: "/${traefik.hostOf name}/${ip}") (attrNames traefik.services)
          # Name-only aliases (see the option docs): same whole-subtree answer as the
          # service records, just without a Traefik router behind them.
          ++ map (name: "/${traefik.hostOf name}/${ip}") cfg.aliases;
      };
    };

    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [config.PORTS.dns];
      allowedTCPPorts = [config.PORTS.dns];
    };
  };
}
