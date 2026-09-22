{
  config,
  lib,
  pkgs,
  configName,
  ...
}:
with lib; let
  cfg = config.MODULES.networking.step-ca;
  domain = config.MODULES.networking.traefik.domain;

  # Public halves live in the repo, private halves in sops - see pki/generate.sh.
  rootCert = cfg.pkiDir + "/root_ca.crt";
  intermediateCert = cfg.pkiDir + "/intermediate_${configName}.crt";
  rootPresent = builtins.pathExists rootCert;
  intermediatePresent = builtins.pathExists intermediateCert;

  traefik = config.MODULES.networking.traefik;
  ip = config.MODULES.networking.tailscale.hostIP;

  # What the QR code points at: the tailscale IP over plain HTTP, so it works before the phone
  # trusts anything and before split DNS is set up. WireGuard already encrypts and authenticates
  # the hop for a phone on the tailnet, and the page shows the fingerprint to check against.
  certUrl = "http://${toString ip}/root_ca.crt";

  # Static page: the QR code is rendered at build time from the certificate itself, so it can
  # never go stale.
  page =
    pkgs.runCommand "ca-page" {
      nativeBuildInputs = [pkgs.qrencode pkgs.openssl];
    } ''
        mkdir $out
        cp ${rootCert} $out/root_ca.crt
      cat > $out/favicon.svg <<'SVG'
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#2563eb" d="M12 1 3 5v6c0 5.5 3.8 10.7 9 12 5.2-1.3 9-6.5 9-12V5z"/><path fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="m8 12 3 3 5-6"/></svg>
      SVG
        qrencode -t SVG -m 2 -o $out/qr.svg ${lib.escapeShellArg certUrl}
        fp=$(openssl x509 -in ${rootCert} -noout -fingerprint -sha256 | cut -d= -f2)
        subject=$(openssl x509 -in ${rootCert} -noout -subject | sed 's/^subject= *//')
        expires=$(openssl x509 -in ${rootCert} -noout -enddate | cut -d= -f2)
        cat > $out/index.html <<EOF
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Root CA</title>
      <link rel="icon" href="favicon.svg" type="image/svg+xml">
        <style>
          :root { --bg: #fff; --fg: #1a1a1a; --muted: #666; --card: #f4f4f5; --accent: #2563eb; }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #111; --fg: #eee; --muted: #999; --card: #1c1c1e; --accent: #60a5fa; }
          }
          body { background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, sans-serif; margin: 0; padding: 24px 16px; }
          main { max-width: 34rem; margin: 0 auto; }
          h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
          p, li { color: var(--muted); }
          .qr { background: #fff; border-radius: 12px; padding: 12px; width: 260px; max-width: 100%; margin: 1.25rem 0; }
          .qr img { display: block; width: 100%; }
          a { color: var(--accent); }
          code { display: block; word-break: break-all; background: var(--card); padding: .6rem .75rem; border-radius: 8px; font-size: .8rem; color: var(--fg); }
          h2 { font-size: 1rem; margin: 1.5rem 0 .25rem; }
        </style>
        </head>
        <body>
        <main>
          <h1>Install the root CA</h1>
          <p>$subject &middot; valid until $expires</p>
          <div class="qr"><img src="qr.svg" alt="QR code for ${certUrl}"></div>
          <p>Scan with your phone, or <a href="root_ca.crt">download root_ca.crt</a>. The phone must be on the tailnet.</p>

          <h2>SHA-256 fingerprint</h2>
          <p>Compare this with what the phone shows before you install.</p>
          <code>$fp</code>

          <h2>Android</h2>
          <p>Open the file, or Settings &rarr; Security &rarr; Encryption &amp; credentials &rarr; Install a certificate &rarr; CA certificate.</p>
          <h2>iOS</h2>
          <ol>
            <li>Allow the profile download, then Settings &rarr; General &rarr; VPN &amp; Device Management &rarr; install it.</li>
            <li>Settings &rarr; General &rarr; About &rarr; Certificate Trust Settings &rarr; enable full trust for it.</li>
          </ol>
          <h2>Firefox</h2>
          <p>Settings &rarr; Privacy &amp; Security &rarr; Certificates &rarr; View Certificates &rarr; Authorities &rarr; Import. Firefox keeps its own trust store.</p>
        </main>
        </body>
        </html>
        EOF
    '';

  keySecret = "step-ca/${configName}/intermediate_key";
  passwordSecret = "step-ca/intermediate_password";
in {
  options.MODULES.networking.step-ca = {
    enable = mkOption {
      type = types.bool;
      default = config.MODULES.networking.traefik.enable;
      defaultText = literalExpression "config.MODULES.networking.traefik.enable";
      description = ''
        Run a step-ca ACME server on this host for its own Traefik. Every host has its own
        intermediate, all signed by the one root, so a client trusts a single certificate and a
        host that is down never stops another from renewing.
      '';
    };

    pkiDir = mkOption {
      type = types.path;
      default = ../../pki;
      description = "Directory holding root_ca.crt and intermediate_<host>.crt (public certificates only).";
    };

    trustRoot = mkOption {
      type = types.bool;
      default = true;
      description = "Add the root CA to this host's system trust store (when pkiDir has one).";
    };

    rootCertFile = mkOption {
      type = types.path;
      readOnly = true;
      default = rootCert;
      description = "The root CA certificate.";
    };
  };

  config = mkMerge [
    (mkIf (cfg.trustRoot && rootPresent) {
      security.pki.certificateFiles = [rootCert];
    })

    (mkIf cfg.enable {
      assertions = [
        {
          assertion = rootPresent && intermediatePresent;
          message = ''
            step-ca on ${configName} needs ${toString rootCert} and ${toString intermediateCert}.
            Run pki/generate.sh, git add pki/*.crt, and put the printed secrets into sops.
          '';
        }
      ];

      sops.secrets.${keySecret} = {
        owner = "step-ca";
        mode = "0400";
      };
      # Read by systemd (LoadCredential), not by the service user.
      sops.secrets.${passwordSecret} = {};

      # The page that hands out the root certificate: https://ca.<host> for a laptop that already
      # trusts the CA, and the plain-HTTP /root_ca.crt on any host name for a phone that doesn't.
      services.nginx = mkIf (traefik.enable && rootPresent) {
        enable = true;
        virtualHosts.${traefik.hostOf "ca"} = {
          root = page;
          listen = [
            {
              addr = "127.0.0.1";
              port = config.PORTS.caPage;
            }
          ];
        };
      };
      MODULES.networking.traefik.services.ca = mkIf (traefik.enable && rootPresent) "127.0.0.1:${toString config.PORTS.caPage}";
      services.traefik.dynamicConfigOptions.http.routers.ca-root-cert = mkIf (traefik.enable && rootPresent) {
        rule = "Path(`/root_ca.crt`)";
        entryPoints = ["web"];
        service = "ca";
        priority = 100;
      };

      services.step-ca = mkIf (rootPresent && intermediatePresent) {
        enable = true;
        # Loopback only: the sole client is this host's Traefik.
        address = "127.0.0.1";
        port = config.PORTS.stepCa;
        intermediatePasswordFile = config.sops.secrets.${passwordSecret}.path;
        # http-01 validation must resolve <name>.<domain>; ask the DNS server on this host
        # (dns.nix) directly rather than whatever the system resolver would do with a made-up TLD.
        extraArgs = ["--resolver=127.0.0.1:${toString config.PORTS.dns}"];

        settings = {
          root = "${rootCert}";
          crt = "${intermediateCert}";
          key = config.sops.secrets.${keySecret}.path;
          dnsNames = ["localhost" "127.0.0.1"];
          db = {
            type = "badgerv2";
            dataSource = "/var/lib/step-ca/db";
          };
          logger.format = "text";

          authority = {
            # Only ever sign names inside this host's own zone (and the zone name itself).
            policy.x509.allow.dns = ["*.${domain}" domain];
            provisioners = [
              {
                type = "ACME";
                name = "acme";
                # Default is 24h, which Traefik would treat as expired on arrival.
                claims = {
                  maxTLSCertDuration = "2160h";
                  defaultTLSCertDuration = "2160h";
                };
              }
            ];
          };

          tls = {
            cipherSuites = [
              "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
              "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
            ];
            minVersion = 1.2;
            maxVersion = 1.3;
            renegotiation = false;
          };
        };
      };
    })
  ];
}
