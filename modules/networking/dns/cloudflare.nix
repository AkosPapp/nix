{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) concatMapStringsSep literalExpression mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.networking.dns.cloudflare;
  traefikCloudflare = config.MODULES.networking.traefik.cloudflare;

  # Everything that must exist in the zone: the explicit `subdomains` entries, plus one per
  # Traefik Cloudflare route (`<name>.<domain>`, or the zone itself for "@") - adding a route
  # there therefore also publishes its record here, which is the whole point of the split.
  # Exposed as an internal option so the interactive setup app (nix run .#cloudflare-config)
  # can enumerate it even while `enable` is still false.
  recordNames = lib.unique (cfg.subdomains ++ builtins.attrNames traefikCloudflare.services);

  # One name per line, read by the sync script below. A store file rather than an inline list:
  # its contents change exactly when the records change, which is what makes the oneshot re-run
  # on switch.
  recordFile = pkgs.writeText "cloudflare-dns-records" (
    concatMapStringsSep "\n" traefikCloudflare.hostOf recordNames
  );

  # Idempotent upsert via cloudflared itself: `tunnel route dns -f` (re)creates the proxied
  # CNAME from the account certificate (`cloudflared tunnel login`'s cert.pem), so the whole
  # public-DNS story is driven by the same credential as the tunnel - no separate API token.
  # The cert is staged to a temp file and passed via TUNNEL_ORIGIN_CERT, since cloudflared's
  # built-in search paths are fixed. Runs as a oneshot on boot and whenever its own
  # (generated) script changes, so the zone converges on the declared records.
  dnsSync = pkgs.writeShellScript "cloudflare-dns-sync" ''
    set -u
    PATH="${lib.makeBinPath [pkgs.cloudflared pkgs.coreutils]}"

    conf=$(mktemp -d)
    trap 'rm -rf "$conf"' EXIT
    install -m600 ${config.sops.secrets.${cfg.certPemSecret}.path} "$conf/cert.pem"

    fail=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # route dns wants the tunnel by ID (names are only unique per account, the UUID is the
      # stable handle); with -f this is a create-or-overwrite, i.e. an upsert.
      if ! TUNNEL_ORIGIN_CERT="$conf/cert.pem" cloudflared tunnel route dns --overwrite-dns \
          ${
      if cfg.tunnel.uuid != null
      then cfg.tunnel.uuid
      else cfg.tunnel.name
    } "$name" < /dev/null; then
        echo "cloudflare-dns: $name: route failed" >&2
        fail=1
      fi
    done < ${recordFile}
    exit $fail
  '';
in {
  options.MODULES.networking.dns.cloudflare = {
    enable = mkEnableOption ''
      a Cloudflare Tunnel for this host, plus declarative proxied DNS records in the zone:
      cloudflared runs the tunnel (its whole ingress is one wildcard rule into Traefik's
      `cloudflare` entry point, so Traefik keeps deciding by Host like everywhere else) and a
      oneshot service upserts every declared record to point at the tunnel with
      `cloudflared tunnel route dns`. TLS terminates at Cloudflare's edge (Universal SSL
      covers the zone and `*.` of it); nothing on this host ever listens on a public port.
      One-time setup (login, tunnel creation, sops secrets, the UUID below) is automated by
      `nix run .#cloudflare-config`; rerun it to refresh the secrets. Details in
      hosts/hp/RUNBOOK/RUNBOOK-cloudflare.md.
    '';

    domain = mkOption {
      type = types.str;
      default = "";
      example = "akosp.app";
      description = "The Cloudflare zone (registered domain) to publish records in.";
    };

    certPemSecret = mkOption {
      type = types.str;
      default = "cloudflare/cert_pem";
      description = ''
        sops secret holding the origin certificate from `cloudflared tunnel login`
        (cert.pem). It authorizes the DNS record upserts and the tunnel creation; the
        tunnel daemon itself only ever sees the narrower per-tunnel credentials.
      '';
    };

    _recordNames = mkOption {
      type = types.listOf types.str;
      internal = true;
      readOnly = true;
      default = recordNames;
      description = "The declared record labels (evaluated even while `enable` is false), for the setup app.";
    };

    tunnel = {
      name = mkOption {
        type = types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "Local name of the tunnel; names the cloudflared unit.";
      };

      uuid = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "00000000-0000-0000-0000-000000000000";
        description = ''
          Tunnel UUID, i.e. the name of the JSON file `cloudflared tunnel create` left behind.
          It is also the DNS target (`<uuid>.cfargotunnel.com`), so it goes into every record.
          `nix run .#cloudflare-config` sets it automatically; see RUNBOOK-cloudflare.md.
        '';
      };

      credentialsSecret = mkOption {
        type = types.str;
        default = "cloudflare/tunnel_credentials";
        description = ''
          sops secret holding the tunnel's credentials JSON (`<uuid>.json` from
          `cloudflared tunnel create`), written out to a root-only file at activation.
        '';
      };
    };

    subdomains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["@" "www"];
      description = ''
        Extra names to publish as proxied CNAMEs to the tunnel, on top of the ones Traefik's
        `cloudflare.services` already imply. Labels below `domain`; "@" is the zone itself
        (Cloudflare flattens the apex CNAME). Use them for names that need DNS but no router
        of their own - anything Traefik should actually answer for belongs in
        `cloudflare.services` instead, which registers the record *and* the route together.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.domain != "";
        message = "MODULES.networking.dns.cloudflare.domain must name the Cloudflare zone (e.g. \"akosp.app\").";
      }
      {
        assertion = cfg.tunnel.uuid != null;
        message = ''
          MODULES.networking.dns.cloudflare.tunnel.uuid is unset. Run `nix run
          .#cloudflare-config` once - it logs in with `cloudflared tunnel login`, creates
          the tunnel `${cfg.tunnel.name}`, stores its credentials and the login certificate
          into sops (`${cfg.tunnel.credentialsSecret}`, `${cfg.certPemSecret}`) and writes
          the UUID into hosts/hp/default.nix. See hosts/hp/RUNBOOK/RUNBOOK-cloudflare.md.
        '';
      }
      {
        assertion = traefikCloudflare.services != {};
        message = ''
          MODULES.networking.dns.cloudflare is enabled but nothing is routed: the tunnel's
          ingress leads to Traefik's `cloudflare` entry point and that only exists once
          MODULES.networking.traefik.cloudflare.services has an entry. Add one (or set
          MODULES.networking.dns.cloudflare.subdomains and a matching service).
        '';
      }
      {
        assertion = recordNames != [];
        message = "MODULES.networking.dns.cloudflare: no records to publish (subdomains and traefik.cloudflare.services are both empty).";
      }
    ];

    # Token for the record sync; credentials for the tunnel daemon. The credentials have to end
    # up in one JSON file on disk, which is what the template is for (sops writes the secret
    # value verbatim, so it carries the JSON as-is).
    sops.secrets.${cfg.certPemSecret} = {};
    sops.secrets.${cfg.tunnel.credentialsSecret} = {};
    sops.templates."cloudflared-credentials.json" = {
      mode = "0400";
      content = config.sops.placeholder.${cfg.tunnel.credentialsSecret};
      restartUnits = ["cloudflared-tunnel-${cfg.tunnel.name}.service"];
    };

    # nixpkgs' cloudflared module (services/networking/cloudflared.nix) supplies the unit
    # skeleton (DynamicUser, LoadCredential of the tunnel key, Restart=on-failure); we own the
    # ingress config and ExecStart (below) because the module exposes neither a protocol knob
    # nor raw config passthrough, and cloudflared's --config YAML outranks the TUNNEL_PROTOCOL
    # env var. One exact-hostname rule per routed record - cloudflared refuses a lone "*" rule
    # when a fallback exists - and Traefik's Host routers decide what actually answers.
    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnel.name} = {
        credentialsFile = config.sops.templates."cloudflared-credentials.json".path;
        ingress = builtins.listToAttrs (map (sub: {
            name = traefikCloudflare.hostOf sub;
            value = {service = "http://127.0.0.1:${toString config.PORTS.traefikCloudflare}";};
          })
          cfg._recordNames);
        default = "http_status:404";
      };
    };

    # Mirror of what the nixpkgs module generates (same credentials-file destination, same
    # ingress order, same catch-all) plus protocol pinning - QUIC/UDP-7840 never completes from
    # this network (precheck suggested_protocol=http2, 2026-10-24), and http2-over-TCP registers
    # fine. If the nixpkgs module grows a protocol option, drop this override.
    systemd.services."cloudflared-tunnel-${cfg.tunnel.name}" = {
      # sops-install-secrets.service is transient - it exists only while the activation script
      # runs, so it may only ever appear in after= (a requires=/wants= ref fails any later start
      # with "Unit sops-install-secrets.service not found", seen 2026-10-24). The secrets land
      # in /run/secrets before activation ends, so ordering is all we need.
      after = ["sops-install-secrets.service" "traefik.service"];
      startLimitIntervalSec = 0;
      serviceConfig.ExecStart = let
        tunnelConfig = builtins.toJSON {
          tunnel = cfg.tunnel.name;
          credentials-file = "/run/credentials/cloudflared-tunnel-${cfg.tunnel.name}.service/credentials.json";
          protocol = "http2";
          ingress =
            map (sub: {
              hostname = traefikCloudflare.hostOf sub;
              service = "http://127.0.0.1:${toString config.PORTS.traefikCloudflare}";
            })
            cfg._recordNames
            ++ [{service = "http_status:404";}];
        };
      in
        lib.mkForce "${config.services.cloudflared.package}/bin/cloudflared tunnel --config=${
          pkgs.writeText "cloudflared-${cfg.tunnel.name}.yml" tunnelConfig
        } --no-autoupdate run";
      # The metrics server (Prometheus format, scraped by prometheus.nix) is on by default at
      # PORTS.cloudflaredMetrics - nothing to configure, cloudflared just starts it.
    };

    systemd.services.cloudflare-dns-sync = {
      description = "Converge Cloudflare DNS records for ${cfg.domain} onto the tunnel";
      after = ["network-online.target" "sops-install-secrets.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      # A oneshot re-runs on every switch whose generated script changed, i.e. whenever the
      # declared records, the tunnel target or the certificate change - which is exactly when the
      # zone needs to converge again.
      script = "${dnsSync}";
      serviceConfig = {
        Type = "oneshot";
      };
    };
  };
}
