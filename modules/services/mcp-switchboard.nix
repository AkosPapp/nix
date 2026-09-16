{
  config,
  lib,
  mcp-switchboard,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.mcp-switchboard;
in {
  imports = [mcp-switchboard.nixosModules.default];

  options.MODULES.services.mcp-switchboard = {
    enable = mkEnableOption ''
      mcp-switchboard, the MCP gateway/registry for this host - replaces mcp-context-forge.
      A client on each remote machine (a devcontainer, another host - anything with local stdio
      MCP servers listed in an mcp.json) spawns those servers and opens one outbound WebSocket to
      the hub run here; the hub aggregates every tunnelled server's tools behind one Streamable
      HTTP /mcp endpoint, which n8n's MCP Client Tool node points at.

      Runs as a native systemd service (DynamicUser, no Docker) rather than mcp-context-forge's
      single container. See https://github.com/AkosPapp/mcp-switchboard - its README documents
      mcp-context-forge's own tunnel/reverse-proxy code as dropping every message it receives
      (TODOs left in place through image 1.0.10), so nothing ever tunnelled through it was
      actually reachable on the other end.
    '';

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = "Register the hub's /metrics endpoint as a Prometheus scrape target.";
    };
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [mcp-switchboard.overlays.default];

    assertions = [
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.mcp-switchboard needs MODULES.security.sops.enable: the tunnel token comes from sops, with no unauthenticated fallback.";
      }
    ];

    # DynamicUser=true (set by the hub's own module) means there's no fixed uid to chown the
    # secret file to ahead of time - a dedicated group plus mode 0440 is exactly what the
    # upstream module's own doc comment recommends for this case.
    users.groups.mcp-switchboard-secrets = {};
    sops.secrets."mcp-switchboard/tunnel_token" = {
      mode = "0440";
      group = "mcp-switchboard-secrets";
    };

    services.mcp-switchboard = {
      enable = true;

      # Loopback: the only thing that needs to be reachable from outside this machine is the
      # tunnel listener, and that happens through the Tailscale Funnel below rather than a raw
      # bound port - same "proxy reaches it on loopback" shape as every other container-backed
      # service in this repo (see litellm.nix), just via `tailscale serve`'s local proxy instead
      # of Traefik's.
      tunnel.host = "127.0.0.1";
      tunnel.port = config.PORTS.mcpSwitchboardTunnel;

      # Console, /api, /mcp (what n8n's MCP Client Tool node points at) and /metrics. Left
      # unauthenticated, per upstream's own recommendation - not being reachable is a stronger
      # guarantee than a shared secret - and reachable only from the tailnet, through the
      # dedicated `tailscale serve` origin below. Not Traefik: same subpath-rewrite headaches
      # n8n.nix already avoids by giving n8n its own origin instead of a shared-origin subpath.
      private.host = "127.0.0.1";
      private.port = config.PORTS.mcpSwitchboardPrivate;

      tunnelToken = config.sops.secrets."mcp-switchboard/tunnel_token".path;
      extraGroups = ["mcp-switchboard-secrets"];

      loki.enable = config.MODULES.services.loki.enable;
      loki.url = "http://127.0.0.1:${toString config.PORTS.loki}";
      loki.labels.host = config.networking.hostName;

      prometheus.register = cfg.metrics && config.MODULES.services.prometheus.enable;
    };

    # The tunnel endpoint needs to be reachable from clients with no Tailscale client at all
    # (devcontainers, arbitrary NAT), not just tailnet members - so this is a Funnel, the same
    # call mcp-context-forge made for its own (non-functional) tunnel endpoint. Funnel is capped
    # at ports 443, 8443 or 10000 - 443 is already Traefik's own tailscale-serve port on this
    # host, hence the dedicated mcpSwitchboardFunnel port rather than reusing the tunnel port.
    MODULES.networking.tailscale.serve.mcp-switchboard-tunnel = {
      type = "funnel";
      target = "http://127.0.0.1:${toString config.PORTS.mcpSwitchboardTunnel}";
      httpsPort = config.PORTS.mcpSwitchboardFunnel;
    };

    # Tailnet-only, unlike the Funnel above: the console/API/metrics listener, on its own origin
    # rather than a Traefik subpath (see n8n.nix for the same subpath-rewrite reasoning).
    MODULES.networking.tailscale.serve.mcp-switchboard = {
      target = "http://127.0.0.1:${toString config.PORTS.mcpSwitchboardPrivate}";
      httpsPort = config.PORTS.mcpSwitchboardPrivate;
    };
  };
}
