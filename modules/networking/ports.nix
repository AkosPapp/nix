{
  lib,
  config,
  ...
}: let
  portValues = lib.attrValues config.PORTS;
  uniquePortValues = lib.unique portValues;
in {
  options.PORTS = lib.mkOption {
    type = lib.types.attrsOf lib.types.int;
    default = {};
    description = "User-defined port mappings (e.g. for custom services not managed by this configuration)";
  };

  config.PORTS = {
    # internal services (bound to localhost)
    fireflyIii = 8093;
    grafana = 8030;
    homepage = 8082;
    i2pdWebui = 8070;
    immich = 2283;
    librechat = 8100;
    librechatMongo = 8101;
    litellm = 8095;
    loki = 8031;
    n8n = 8097;
    n8nSandbox = 8098;
    nextcloud = 8088;
    nixAutobuild = 8085;
    nginxStatus = 8087;
    omniroute = 8102;
    openWebui = 8094;
    prometheus = 8009;
    stepCa = 9000;
    caPage = 8103;
    elementWeb = 8104;
    mdbook = 8106;
    # Traefik's Funnel-facing entry point (plain HTTP; tailscaled terminates TLS).
    traefikFunnel = 8107;
    oauth2Proxy = 8108;
    webhook = 8109;
    hermesDashboard = 8110;
    outline = 8111;
    # Hermes' Matrix reader MCP server - loopback only; both Hermes units connect to it (E2EE
    # state means exactly one reader process may run, so it is a service rather than a stdio child).
    matrixReader = 8112;
    # Paseo (modules/services/paseo.nix) - loopback only.
    paseoDaemon = 6767;
    paseoRelay = 8113;
    paseoWeb = 8114;
    paseoRegistry = 8115;
    # Hermes' own Paseo daemon (modules/services/paseo-hermes.nix) - loopback only, never shared
    # with the hub's 6767.
    paseoHermesDaemon = 8116;
    # Hermes' ICS feed server (modules/services/hermes-ics.nix) - loopback only; Traefik's funnel
    # entry point is its only client. Kept clear of PORTS.paseoMachine's 8117+idx range.
    hermesIcs = 8130;
    # Trilium Notes (modules/services/trilium.nix) - loopback only, behind Traefik.
    trilium = 8131;
    # Traefik's Cloudflare-facing entry point (modules/networking/traefik.nix's `cloudflare`
    # options) - loopback only; cloudflared is its sole client, TLS ends at Cloudflare's edge.
    traefikCloudflare = 8140;
    synapse = 8008;
    # Matrix Authentication Service (MODULES.services.matrix.mas) - loopback only, behind
    # Traefik/Cloudflare like Synapse; its OAuth/compat endpoints are served through PORTS.matrixCompat.
    matrixAuth = 8089;
    # Splitter vhost in front of Synapse + MAS: legacy /_matrix/client/*/login|logout|refresh go
    # to MAS, everything else to Synapse (modules/services/matrix.nix). This is what bridges,
    # Hermes and Traefik/Cloudflare point at when MAS is on.
    matrixCompat = 8096;
    # mautrix bridges' appservice listeners - only Synapse on the same host connects to these.
    mautrixWhatsapp = 29318;
    mautrixSignal = 29328;
    mautrixSlack = 29335;
    mautrixDiscord = 29342;
    mautrixMattermost = 29349;
    mautrixJabber = 29356;
    roundcube = 8086;
    searx = 8081;
    sftpgoHttp = 8090;
    sftpgoWebdav = 8091;
    syncthingWebui = 8092;
    traefikDashboard = 8888;
    vaultwarden = 8222;
    transmissionRpc = 8001;

    # prometheus exporters
    prometheusImmichApiExporter = 9201;
    prometheusImmichMicroservicesExporter = 9202;
    prometheusNginxExporter = 9113;
    prometheusNextcloudExporter = 9205;
    prometheusNodeExporter = 9100;
    prometheusPhpFpmExporter = 9253;
    prometheusPostgresExporter = 9187;
    prometheusSynapse = 9206;
    prometheusOauth2Proxy = 9207;
    prometheusTailscaleExporter = 9200;
    prometheusZfsExporter = 9134;
    # cloudflared's built-in Prometheus endpoint. Not chosen here: it's `tunnel run`'s own
    # `--metrics` default and nixpkgs' cloudflared module exposes no flag to move it, so the
    # scrape has to hit wherever it listens (modules/networking/dns/cloudflare.nix).
    cloudflaredMetrics = 35555;

    # ports bound to tailscale IP
    i2pdHttpProxy = 4444;
    i2pdSam = 7656;
    i2pdSocksProxy = 4447;
    ipfsApi = 5001;
    ipfsGateway = 5002;
    immichMachineLearning = 3003;
    syncthingSync = 22000;

    # external ports (open to network)
    fastddsData = 42100;
    fastddsDiscovery = 11811;
    i2pdRouter = 12345;
    # Tailscale Funnel only, not a raw firewall port: Funnel accepts exactly 443, 8443 or 10000,
    # and 443 is Traefik's own HTTPS listener (see traefik.nix). This is the public face of
    # Traefik's `funnel` entry point (traefik.nix's `funnel` options). Registered here anyway so
    # the duplicate-port assertion below still catches a future collision.
    traefikFunnelPublic = 8443;
    # Funnel port for Paseo's self-hosted relay (modules/services/paseo.nix): the relay client
    # dials a bare host:port with the protocol-fixed path /ws, so no path-prefix sharing of
    # traefikFunnelPublic is possible and it gets the third of Funnel's three allowed ports.
    # It used to belong to Outline's own Funnel listener (modules/services/outline.nix, since
    # disabled on hp); outline.nix still points at it for the day Outline returns - re-enable
    # would then need its own port, since Funnel allows no fourth.
    paseoRelayFunnel = 10000;
    ipfsSwarm = 4001;
    mosquitto = 1883;
    dns = 53;
    traefikHttp = 80;
    traefikHttps = 443;
    transmissionPeer = 51413;
    cups = 631;
  };

  config.assertions =
    [
      {
        assertion = lib.length portValues == lib.length uniquePortValues;
        message = "PORTS contains duplicate port numbers: ${
          lib.concatStringsSep ", " (
            lib.mapAttrsToList (name: port: "${name}=${toString port}") (
              lib.filterAttrs (_: port: lib.count (p: p == port) portValues > 1) config.PORTS
            )
          )
        }";
      }
    ]
    ++ lib.mapAttrsToList (name: port: {
      assertion = port >= 1 && port <= 65535;
      message = "PORTS.${name} = ${toString port} is not a valid port number (must be between 1 and 65535)";
    })
    config.PORTS;
}
