# Prosody XMPP hosting the fleet's JID domain (akos@akosp.app), reachable through the
# Cloudflare Tunnel - NOT through direct 5222 from the internet.
#
# 2026-11-15 rewrite (why): the original design served clients directly over IPv6
# (AAAA DDNS + SRV at xmpp.akosp.app) and the RUNBOOK claimed "inbound v6 reaches
# Prosody unfiltered". That was measured with a hairpin from hp itself and is false
# from the internet: a TCP SYN to the AAAA on 5222/5281/443 never reaches hp's NIC
# (tcpdump on the WAN interface, 2026-11-15 - TU Wien firewalls inbound v6), the v4
# is NATed with no IGD (`upnpc -s`: "No IGD UPnP Device found"), and the firewall
# counters for 5222/5269/5281 showed 0 packets since boot while `journalctl -u
# prosody` never logged a single client connection. The same dead path broke the
# mautrix-jabber bridge (its fork dials <JID-domain>:5222 via plain A/AAAA, no SRV
# - pkg/connector/connector.go in williamkray/jmpchat-matrix-bridge v0.9.6), so the
# account existed but NOTHING could ever log in.
#
# The tunnel is therefore the only honest public door this host has (RUNBOOK-
# cloudflare.md: "nothing on hp is open to the internet"). Clients reach Prosody the
# way every other cloud behind this tunnel works - over WebSocket (XEP-0156
# discovery): the phone's client fails its direct 5222 attempt in milliseconds
# (Cloudflare's edge answers nothing on 5222), fetches
# https://akosp.app/.well-known/host-meta.json (core mod_http_altconnect, served on
# the apex route), and connects to wss://xmpp.akosp.app/xmpp-websocket through the
# tunnel. Measured against a throwaway Prosody instance before shipping: host-meta
# resolves ONLY under Host: <domain> (hence the dedicated apex path router below),
# /xmpp-websocket answers under any Host, and mod_http_file_share mounts at
# /file_share under Host: <connectHost> while the advertised slot URL is
# http_external_url + "/file_share" - keep the component's external URL path-less or
# upload links point at a path Prosody never serves.
#
# What direct 5222/5269 are still good for: tailnet/LAN clients (Conversations on
# the laptop VPN, other hosts) - declared as a service-graph edge - and Prosody's
# own outbound federation (s2s out needs no inbound). INBOUND federation from the
# public internet is not possible without a public TCP 5269, which this fleet
# deliberately does not open anywhere.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.xmpp;

  traefik = config.MODULES.networking.traefik;

  # The tunnel name the HTTP face is published under: route label -> hostOf -> hostname.
  connectHost = traefik.cloudflare.hostOf cfg.route;

  # Prosody escapes dots in per-vhost data directories as %2e.
  escapedDomain = lib.replaceStrings ["."] ["%2e"] cfg.domain;

  certDir = config.security.acme.certs.${connectHost}.directory;

  # The bridge's dial target, pinned for its unit ONLY (see the mautrix-jabber
  # BindReadOnlyPaths below): jmpchat resolves the JID's domain to reach the server and
  # akosp.app's public DNS answer is Cloudflare's edge, which forwards no XMPP. The unit
  # keeps the system file for everything else (nss "files then dns" - names absent from
  # a hosts file fall through to DNS, so remote JID domains still resolve normally).
  bridgeHostsFile = pkgs.writeText "mautrix-jabber-hosts" ''
    # unit-scoped /etc/hosts: the fleet's own XMPP domain dials loopback (Prosody on
    # this host); everything else falls through to the normal resolver.
    127.0.0.1 localhost
    ::1 localhost
    127.0.0.1 ${cfg.domain}
  '';
in {
  options.MODULES.services.xmpp = {
    enable = mkEnableOption ''
      the Prosody XMPP server for `domain`, published through the Cloudflare Tunnel
      (WebSocket + XEP-0156 host-meta; direct 5222/5269 stay tailnet/LAN-only) and
      bridged into Matrix by mautrix-jabber over the loopback pin. Needs
      MODULES.networking.dns.cloudflare + traefik like MODULES.services.matrix.public.
    '';

    domain = mkOption {
      type = types.str;
      default = "akosp.app";
      description = "XMPP domain; accounts are user@domain. Same domain as the Matrix server.";
    };

    route = mkOption {
      type = types.str;
      default = "xmpp";
      example = "xmpp2";
      description = ''
        Traefik Cloudflare route label for the HTTP face; the public hostname is
        MODULES.networking.traefik.cloudflare.hostOf of it (`xmpp` -> xmpp.akosp.app),
        which also names the ACME certificate.
      '';
    };

    adminUser = mkOption {
      type = types.str;
      default = "akos";
      description = "Prosody admin (server admin tools, MUC owner privileges).";
    };

    apiTokenSecret = mkOption {
      type = types.str;
      default = "cloudflare/dns_api_token";
      description = ''
        sops secret with a Cloudflare API token holding Zone / DNS / Edit, consumed by
        the ACME DNS-01 hook (the only writer of zone records left - the AAAA DDNS and
        the SRV publisher of the pre-tunnel era are retired; see the header comment).
      '';
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
    assertions = [
      {
        assertion = config.MODULES.networking.dns.cloudflare.enable;
        message = "MODULES.services.xmpp needs MODULES.networking.dns.cloudflare - the tunnel is the only way its clients reach it.";
      }
      {
        assertion = traefik.cloudflare.services ? ${cfg.route};
        message = "MODULES.services.xmpp expects its own Cloudflare route: add `${cfg.route} = \"127.0.0.1:<prosodyHttp>\"` to MODULES.networking.traefik.cloudflare.services (the module below registers it).";
      }
    ];

    # Token for ACME; the account password secrets, declared from cfg.users.
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
        "acme-${connectHost}.service"
        "acme-order-renew-${connectHost}.service"
      ];
    };

    # The cert still matters although the tunnel terminates client TLS: it is the
    # STARTTLS certificate of direct 5222/5269 (tailnet/LAN clients, our own s2s
    # out), and XEP-0156 clients that pinned the domain expect the SAN. A single
    # DNS-01 cert covers both names: XMPP clients validate the JID domain
    # (akosp.app) even when the connection is named xmpp.akosp.app (RFC 6120).
    # HTTP-01 is impossible (the edge only proxies, never back-issues).
    security.acme = {
      acceptTerms = true;
      certs.${connectHost} = {
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

    # The tunnel route + the record dns-sync derives from it. Requests arrive from
    # Cloudflare's edge as plain HTTP on loopback, exactly like every other
    # cloudflare.services backend; Prosody decides endpoints by Host (measured: the
    # websocket path answers under ANY Host, which is what makes this one route serve
    # both the wss endpoint and the file-share uploads).
    MODULES.networking.traefik.cloudflare.services.${cfg.route} = "127.0.0.1:${toString config.PORTS.prosodyHttp}";

    # XEP-0156 discovery lives on the APEX (clients fetch akosp.app/.well-known/...,
    # not the subdomain), and the apex Host is already routed to Synapse by
    # MODULES.services.matrix - so claim exactly the two host-meta paths here, the way
    # bootstrap-installers.nix claims its apex paths. Prosody serves host-meta ONLY
    # when Host matches a configured vhost (measured 2026-11-15: 404 under any other
    # Host), hence passHostHeader stays at its default (true) and the rule pins the
    # apex Host itself.
    services.traefik.dynamicConfigOptions = lib.mkIf traefik.enable {
      http = {
        routers."${cfg.route}-apex-hostmeta" = {
          rule = "Host(`${cfg.domain}`) && (Path(`/.well-known/host-meta`) || Path(`/.well-known/host-meta.json`))";
          entryPoints = ["cloudflare"];
          service = "${cfg.route}-apex-hostmeta";
          middlewares = ["cloudflare-https"];
          # Above the matrix apex router's length-derived default (same shape as the
          # installers-apex router; the rule is longer anyway, be explicit).
          priority = 100;
        };
        services."${cfg.route}-apex-hostmeta".loadBalancer.servers = [
          {
            url = "http://127.0.0.1:${toString config.PORTS.prosodyHttp}";
          }
        ];
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

      # WebSocket framing over the tunnel is THE public client transport (see header);
      # BOSH would ride the same tunnel path and just doubles the parser surface. The
      # core mod_http_altconnect answers /.well-known/host-meta{,.json} advertising it
      # (XEP-0156) - no community-module fetch: the pinned nixpkgs communityModules
      # archive ships no mod_host_meta (measured: the withCommunityModules build of it
      # fails on a missing directory, and upstream prosody-modules@15a7749c7acb has no
      # such path either).
      modules.websocket = true;
      # BOSH rides the same tunnel/HTTP path as a second transport: long-poll POSTs over
      # plain HTTPS survive proxies and stacks where a long-lived websocket does not
      # (android 9 era okhttp, some carrier middleboxes), and mod_http_altconnect
      # advertises it in host-meta automatically, so XEP-0156 clients pick it themselves.
      modules.bosh = true;
      extraModules = ["http_altconnect"];

      # HTTP face: loopback only, on PORTS.prosodyHttp - the tunnel via Traefik is its
      # sole client. The old direct-HTTPS 5281 is gone (never reachable, see header);
      # the ACME cert now serves c2s/s2s STARTTLS only.
      httpPorts = [config.PORTS.prosodyHttp];
      httpInterfaces = ["127.0.0.1"];
      httpsPorts = [];

      extraConfig = ''
        -- mod_websocket/mod_bosh default the UNAUTHENTICATED stanza limit to 10k and the
        -- bound one to 128k (the values XEP-0474 advertises); 320k is plain OMEMO payload
        -- headroom, not a bugfix - the phone's post-auth hang-up was NOT the limit (Gajim
        -- bound and resumed fine under the stock values, measured 2026-11-15).
        c2s_stanza_size_limit = 327680

        -- The tunnel via Cloudflare's edge already decrypted and hands us plaintext on
        -- loopback - declare the proxied transports secure (XEP-0156 advertises them as
        -- wss/https, and the modules reject unencrypted c2s on connections they consider
        -- insecure).
        consider_websocket_secure = true
        consider_bosh_secure = true
        -- All advertised HTTP URLs (websocket, file-share slots) carry this public base;
        -- keep the path empty: a path prefix here desynchronizes the advertised slot URL
        -- from the component's real mount (measured 2026-11-15 - see header).
        http_external_url = "https://${connectHost}/"
      '';

      # Serve the upload endpoint (XEP-0363 file-share, also required by the module's
      # XEP-0423 compliance assertions) on the SAME tunnel name: JID component
      # uploads.akosp.app, real URL https://xmpp.akosp.app/file_share/ (measured mount
      # and advertised URL match with the path-less external URL above).
      httpFileShare = {
        domain = "uploads.${cfg.domain}";
        http_host = connectHost;
        http_external_url = "https://${connectHost}/";
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
      # copies in extraConfig would be flagged as duplicates by prosodyctl). INBOUND
      # federation needs a public 5269 this host will not open; outbound stands.
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

    # Direct c2s/s2s stay open where a route exists (tailscale0, LAN): phones on the
    # tailnet get a raw 5222 with the DNS-01 cert, which beats tunnel wss for latency.
    # No internet route reaches these (header), but the listeners are the tailnet/LAN
    # front door and the module's compliance assertions expect them.
    networking.firewall.allowedTCPPorts = [
      5222
      5269
    ];

    # Both roles, AGENTS.md: tailnet peers dialing us on c2s/s2s AND our own tap
    # seeing the accepted SYNs. Loopback (the bridge) is the jails' jurisdiction and
    # WAN inbound simply does not exist here.
    MODULES.security.serviceGraph.allow = [
      {
        name = "prosody-c2s-s2s";
        ports = [5222 5269];
        from = [
          "100.64.0.0/10" # tailscale CGNAT
          "fd7a:115c:a1e0::/48" # tailscale ULA
        ];
      }
    ];

    # The bridge's own dial path (its fork has no SRV/server setting - see header):
    # one extra bind on ITS unit only. BindReadOnlyPaths merges as a list, so this
    # coexists with jail.nix's assignment to the same key (jail contributes its own
    # value separately).
    systemd.services.mautrix-jabber.serviceConfig.BindReadOnlyPaths =
      lib.mkIf config.MODULES.services.matrix.jabber.enable
      ["${bridgeHostsFile}:/etc/hosts"];

    # The pin above only lands if the bridge's libc actually READS /etc/hosts: glibc
    # asks nscd first (active on hp) and the daemon happily serves its cached answer
    # for akosp.app - measured 2026-11-15: with the bind mounted, `getent hosts
    # akosp.app` still answered Cloudflare inside the unit namespace, while
    # `getent -s files` answered the pin. Hiding the nscd socket from this unit
    # (InaccessiblePaths) makes NSS go files->dns directly; the other domains still
    # resolve normally (dns backend, just uncached). The list restates jail.nix's
    # table defaults because the row field OVERWRITES (three-way merge can't append).
    MODULES.security.jails.mautrix-jabber.inaccessiblePaths =
      lib.mkIf
      config.MODULES.services.matrix.jabber.enable
      [
        "/run/secrets.d"
        "/run/secrets"
        "/run/docker.sock"
        "/var/lib/docker"
        "/run/nscd"
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
  };
}
