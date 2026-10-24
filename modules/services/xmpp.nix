{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.xmpp;

  # Prosody escapes dots in per-vhost data directories as %2e.
  escapedDomain = lib.replaceStrings ["."] ["%2e"] cfg.domain;

  certDir = config.security.acme.certs.${cfg.connectHost}.directory;

  # Keeps the zone's SRV records pointing at this host and refreshes its AAAA whenever the
  # dynamic public IPv6 changes. hp's IPv4 sits behind NAT (TU Wien), so this endpoint is
  # IPv6-only: federation and remote clients need IPv6 to reach us (all major XMPP servers
  # have it). Upserts are idempotent: nothing is written while values are unchanged.
  ddnsScript = pkgs.writeShellApplication {
    name = "xmpp-ddns";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      token="$(cat "$CREDENTIALS_DIRECTORY/cf_api_token")"
      api() {
        curl -fsS -H "Authorization: Bearer ''${token}" -H "Content-Type: application/json" "$@"
      }

      zone=$(api "https://api.cloudflare.com/client/v4/zones?name=${cfg.domain}" | jq -r '.result[0].id // empty')
      if [ -z "$zone" ]; then
        echo "Cloudflare zone for ${cfg.domain} not found (token without Zone.DNS read?)" >&2
        exit 1
      fi

      # ---- AAAA (DDNS) ----
      # Cloudflare's trace endpoint echoes the address we are seen from. Use the IPv6 literal
      # (bypasses DNS, so no DNS64-synthesized AAAA) and additionally REJECT non-v6 answers:
      # this network has NAT64, so a v6-looking route can still egress as v4 (observed: the
      # trace returned the IPv4 address through the NAT64 prefix). Anything that is not a real
      # v6 address must never reach the AAAA record; while v6 is briefly down the old record
      # is kept rather than deleted.
      ipv6=$(curl -6 -fsS --max-time 15 "https://[2606:4700:4700::1111]/cdn-cgi/trace" | sed -n 's/^ip=//p') || ipv6=""
      case "$ipv6" in
        *:*) ;;
        *) ipv6="" ;;
      esac
      if [ -n "$ipv6" ]; then
        rec=$(api "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?name=${cfg.connectHost}&type=AAAA" | jq -c '.result[0] // empty')
        cur=$(jq -r '.content // empty' <<<"$rec")
        if [ "$cur" != "$ipv6" ]; then
          body=$(jq -n --arg c "$ipv6" '{name: "${cfg.connectHost}", type: "AAAA", content: $c, proxied: false, ttl: 1}')
          if [ -n "$cur" ]; then
            id=$(jq -r '.id' <<<"$rec")
            api -X PUT "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$id" --data "$body" >/dev/null
          else
            api -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" --data "$body" >/dev/null
          fi
          echo "xmpp AAAA record updated to $ipv6"
        fi
      else
        echo "no public IPv6 right now, leaving the AAAA record alone" >&2
      fi

      # ---- SRV records ----
      # XMPP clients query _xmpp-client._tcp.<domain>, other servers _xmpp-server._tcp. Both
      # point at ${cfg.connectHost} (the only name with a public AAAA; the apex stays
      # proxied/orange behind the Cloudflare tunnel and cannot forward raw 5222/5269).
      ensure_srv() {
        local name="$1" target="$2" port="$3" data existing have want id
        data=$(jq -n --arg name "$name" --arg target "$target" --argjson port "$port" '
          ($name / ".") as $p |
          {name: $name, type: "SRV", ttl: 1,
           data: {service: $p[0], proto: $p[1], name: ($p[2:] | join(".")),
                  target: $target, priority: 10, weight: 0, port: $port}}')
        want=$(jq -c '.data' <<<"$data")
        existing=$(api "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?name=$name&type=SRV" | jq -c '.result[0] // empty')
        have=$(jq -c '.data // empty' <<<"$existing")
        if [ "$have" = "$want" ]; then return 0; fi
        if [ -n "$have" ]; then
          id=$(jq -r '.id' <<<"$existing")
          api -X PUT "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$id" --data "$data" >/dev/null
        else
          api -X POST "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" --data "$data" >/dev/null
        fi
        echo "xmpp SRV record $name -> $target:$port"
      }
      ensure_srv "_xmpp-client._tcp.${cfg.domain}" "${cfg.connectHost}" 5222
      ensure_srv "_xmpp-server._tcp.${cfg.domain}" "${cfg.connectHost}" 5269
    '';
  };
in {
  options.MODULES.services.xmpp = {
    enable = mkEnableOption "the Prosody XMPP server (public over IPv6, bridged by mautrix-jabber)";

    domain = mkOption {
      type = types.str;
      default = "akosp.app";
      description = "XMPP domain; accounts are user@domain. Same domain as the Matrix server.";
    };

    connectHost = mkOption {
      type = types.str;
      default = "xmpp.akosp.app";
      description = "Public hostname the SRV records target; gets the DDNS AAAA and the ACME cert.";
    };

    adminUser = mkOption {
      type = types.str;
      default = "akos";
      description = "Prosody admin (server admin tools, MUC owner privileges).";
    };

    apiTokenSecret = mkOption {
      type = types.str;
      default = "cloudflare/dns_api_token";
      description = "sops secret with a Cloudflare API token holding Zone / DNS / Edit (covers DDNS, SRV and the ACME DNS-01 challenge).";
    };

    acmeEmail = mkOption {
      type = types.str;
      default = "it.akos.papp@gmail.com";
      description = "ACME contact email (expiry notices from Let's Encrypt).";
    };

    users = mkOption {
      type = types.attrsOf (types.submodule {
        options.passwordSecret = mkOption {
          type = types.str;
          description = "sops secret with the account's XMPP password (hashed into Prosody at first boot).";
        };
      });
      default = {
        akos.passwordSecret = "xmpp/akos_password";
      };
      description = "XMPP accounts created once (register) if their hash file is missing.";
    };
  };

  config = mkIf cfg.enable {
    # A single DNS-01 cert covers both names: XMPP clients validate the *JID domain*
    # (akosp.app) even though the SRV target is xmpp.akosp.app (RFC 6120), and federation
    # peers validate the same. HTTP-01 is impossible (no direct 80 behind the tunnel).
    # The Cloudflare API token plus the account password secrets, declared from cfg.users.
    sops.secrets =
      lib.mapAttrs' (name: u: lib.nameValuePair u.passwordSecret {}) cfg.users
      // {
        ${cfg.apiTokenSecret} = {};
      };

    # lego's cloudflare provider only understands CLOUDFLARE_DNS_API_TOKEN-style env vars - it
    # does not do the nixpkgs *_FILE convention - so the token is rendered into a real env file
    # (sops template) that the acme units read as EnvironmentFile. Owner acme: lego runs as that
    # user; restartUnits makes the acme units order after the template is rendered.
    sops.templates."acme-xmpp.env" = {
      owner = "acme";
      mode = "0400";
      content = "CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.${cfg.apiTokenSecret}}\n";
      restartUnits = [
        "acme-${cfg.connectHost}.service"
        "acme-order-renew-${cfg.connectHost}.service"
      ];
    };

    security.acme = {
      acceptTerms = true;
      certs.${cfg.connectHost} = {
        email = cfg.acmeEmail;
        extraDomainNames = [cfg.domain];
        dnsProvider = "cloudflare";
        # Verify the TXT through a public resolver: lego's default asks the zone's own SOA
        # first, which briefly answers stale on Cloudflare right after the write.
        dnsResolver = "1.1.1.1:53";
        environmentFile = config.sops.templates."acme-xmpp.env".path;
        group = "prosody";
        postRun = "systemctl restart prosody.service";
      };
    };

    services.prosody = {
      enable = true;
      # prosodyctl check config runs in the build sandbox, where /var/lib/acme holds nothing -
      # the cert only exists on the host once lego's DNS-01 challenge has run.
      checkConfig = false;
      admins = ["${cfg.adminUser}@${cfg.domain}"];
      # internal_hashed (the module default) is what the provisioning unit below fills.
      authentication = "internal_hashed";
      allowRegistration = false;

      # No plain-HTTP endpoint; HTTPS only, and only for the file-share component (XEP-0363,
      # also required by the module's XEP-0423 compliance assertions). Bosh/websocket stay off.
      httpPorts = [];
      httpsPorts = [5281];

      # Serve the upload endpoint under the existing cert/DNS name instead of adding a third
      # hostname: JID component uploads.akosp.app, actual URL on xmpp.akosp.app:5281.
      httpFileShare = {
        domain = "uploads.${cfg.domain}";
        http_host = cfg.connectHost;
        http_external_url = "https://${cfg.connectHost}:5281/";
      };

      ssl = {
        cert = "${certDir}/fullchain.pem";
        key = "${certDir}/key.pem";
      };

      # The module's "advanced server" baseline minus in-band registration (accounts come from
      # sops via the provisioning unit; allowRegistration=false already refuses it too).
      modules.register = false;

      # c2s/s2s require-encryption are the module defaults (true); certificate-verified
      # federation is the deliberate non-default (the module's own lines then carry it - raw
      # copies in extraConfig would be flagged as duplicates by prosodyctl).
      s2sSecureAuth = true;

      # mkForce drops the module's default localhost vhost; this is a single-domain server.
      virtualHosts = lib.mkForce {
        ${cfg.domain} = {
          domain = cfg.domain;
          enabled = true;
        };
      };

      # Groupchat component (the bridge maps XMPP MUCs to Matrix rooms with !jabber groupchat).
      muc = [
        {
          domain = "conference.${cfg.domain}";
          # Room locks would serialize the bridge's joins; real JIDs in occupant lists keep
          # Matrix ghost identities legible.
          roomLocking = false;
          roomDefaultPublicJids = true;
        }
      ];
    };

    # Client-to-server and server-to-server, public (v6). Loopback clients (the bridge) do not
    # need a firewall hole; these also only answer where a route exists. 5281 is the HTTPS face
    # of the file-share component (upload links are handed out to remote clients too).
    networking.firewall.allowedTCPPorts = [
      5222
      5269
      5281
    ];

    # ---- First-boot account creation ----
    # `register` only when Prosody's account file is absent, so this is safe to run every boot
    # and never overwrites a rotated password (rotate manually with `prosodyctl passwd akos@…`).
    systemd.services.xmpp-provision = {
      description = "Create missing Prosody XMPP accounts";
      after = [
        "prosody.service"
        "sops-install-secrets.service"
      ];
      wants = ["prosody.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "prosody";
        Group = "prosody";
        # Prosody's own StateDirectory stays writable; everything else is read-only.
        StateDirectory = "prosody";
        RemainAfterExit = "no";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = ["AF_UNIX"];
        SystemCallFilter = ["@system-service"];
        LoadCredential = lib.mapAttrsToList (name: u: "xmpp_password_${name}:${config.sops.secrets.${u.passwordSecret}.path}") cfg.users;
      };
      script = let
        prosodyctl = "${config.services.prosody.package}/bin/prosodyctl";
        mkRegister = name: u: ''
          # Prosody 0.12 stores internal_hashed accounts as .dat (older releases: .txt).
          if [ ! -e "/var/lib/prosody/${escapedDomain}/accounts/${name}.dat" ] \
             && [ ! -e "/var/lib/prosody/${escapedDomain}/accounts/${name}.txt" ]; then
            echo "registering XMPP account ${name}@${cfg.domain}"
            ${prosodyctl} --config /etc/prosody/prosody.cfg.lua register \
              '${name}' '${cfg.domain}' "$(cat "$CREDENTIALS_DIRECTORY/xmpp_password_${name}")"
          fi
        '';
      in
        lib.concatStringsSep "\n" (lib.mapAttrsToList mkRegister cfg.users);
    };

    # ---- Public reachability (DDNS + SRV), every 10min and at boot ----
    systemd.services.xmpp-ddns = {
      description = "Publish Prosody's AAAA/SRV records in Cloudflare DNS";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        # "-" prefix: a 400/429 from the DNS API must never poison an unrelated deployment -
        # the new persistent timer fires its first run inside the activation transaction, and
        # one failed oneshot there rolls back the whole switch (2026-10-24). The journal still
        # shows the error; the next timer tick retries.
        ExecStart = "-${ddnsScript}/bin/xmpp-ddns";
        LoadCredential = ["cf_api_token:${config.sops.secrets.${cfg.apiTokenSecret}.path}"];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        SystemCallFilter = ["@system-service"];
      };
      restartIfChanged = false;
    };

    systemd.timers.xmpp-ddns = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "10min";
        Persistent = true;
      };
    };
  };
}
