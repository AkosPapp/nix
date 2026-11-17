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
    loki = 8031;
    # loki's gRPC (scheduler/ingester ring traffic) - loopback-only since 2026-10-27; see
    # modules/services/loki.nix. Named so the jail rule and the config share one source.
    lokiGrpc = 9095;
    nextcloud = 8088;
    nixAutobuild = 8085;
    nginxStatus = 8087;
    omniroute = 8102;
    openWebui = 8094;
    prometheus = 8009;
    # The single-node Slurm pair (modules/services/slurm.nix). Both are upstream's defaults, and
    # both are dialled only from this box: the module pins SlurmctldHost to 127.0.0.1 and opens no
    # firewall rule, which is why they need no service-graph edge. Named so slurm.conf and any
    # future tailnet exposure read from the same place.
    slurmctld = 6817;
    slurmd = 6818;
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
    # Joplin (modules/services/joplin.nix) - the Selkies container shares the host network and
    # its nginx binds all interfaces, so all three listeners it owns are registered: joplin is
    # the HTTP one Traefik proxies, joplinTls the image's self-signed listener Traefik does NOT
    # use, joplinStream the selkies server behind that nginx (loopback-bound by the image
    # itself, but still a port on this host's network namespace).
    joplin = 8132;
    joplinTls = 8133;
    joplinStream = 8134;
    # paperless-ngx (modules/services/paperless.nix) - loopback only, behind Traefik. Both of
    # its containers share the host network (the v3 image has no bundled db/broker, so a valkey
    # one runs beside it), hence a PORTS entry each, both bound to loopback by the container's
    # own flag (PAPERLESS_BIND_ADDR / valkey --bind) rather than by a published mapping.
    paperless = 8135;
    paperlessBroker = 8136;
    # Coroot (modules/services/coroot.nix) - server UI/API, loopback + tailscale0 only.
    coroot = 8080;
    # The Blender addon's MCP socket (modules/services/blender-mcp.nix) - loopback only,
    # owned by the desktop app, not a systemd service. 9876 is the addon's own default and
    # the server's (BLENDER_PORT) default; the port lives here so the addon, the harness
    # entries and any future override share one source. Named so a scene that moves the
    # addon's port restates it once.
    blenderMcp = 9876;
    # coroot-node-agent's own /metrics listener - loopback only; scraped locally by
    # modules/services/prometheus.nix (job coroot-node-agent), nothing connects remotely.
    # 8141 -> 10300 (measured 2026-11-13): the 1.36.x agent IGNORES --listen whenever a
    # collector pushes metrics - flags.go overrides ListenAddress to exactly
    # 127.0.0.1:10300 once MetricsEndpoint (derived from --collector-endpoint) is set -
    # so the scrape had been hitting a dead port (up=0) since the agent bump. The
    # --listen flag is kept in coroot.nix because its value must match this one.
    corootNodeAgent = 10300;
    # ClickHouse for Coroot - loopback only; 9000/8123 are unavailable here (PORTS.stepCa).
    corootClickhouseNative = 8142;
    corootClickhouseHttp = 8143;
    # Coroot alert webhook receiver (modules/services/coroot-alerts.nix): bound to all
    # interfaces like the Coroot server's own listener, reachable only over tailscale0
    # (the firewall's default zone drops everything else); the Coroot SERVER posts its
    # alert/incident notifications here from the tailnet.
    corootAlerts = 8144;
    # The token-gated installer endpoint (modules/services/bootstrap-installers.nix):
    # loopback nginx serving /install/<token>/<name>.sh, exposed only through Traefik's
    # funnel route. Named so the module and the firewall share one source (PORTS rule).
    bootstrapInstallers = 8145;
    # The per-device installer key mint daemon (modules/services/installer-mint.nix):
    # loopback-only HTTP; the sole client is the bootstrap-installers nginx mintProxy
    # (which carries the X-Mint-Token header ACL), so no funnel/tailnet edge entry is
    # needed - same loopback reasoning as the omniroute seed unit's API calls. 8149,
    # not 8147: that number sits between the ultraTrainer 8146/8148 tunnel ladder and
    # lab-web-tunnels.nix says the next robot instance claims the next slot - take the
    # number above the pair instead of cutting in.
    installerMint = 8149;
    # The Perplexity MCP server (modules/services/mcp-perplexity.nix): loopback
    # streamable-HTTP MCP daemon whose upstream is this host's own OmniRoute sonar
    # route; its sole non-local client is the bootstrap-installers proxies.mcp nginx
    # gate (the funnel's /install/mcp), so like installerMint it needs no firewall
    # edge and rides the edge tap's funnel-port scope already in place.
    mcpPerplexity = 8150;
    # Prosody's HTTP face (websocket/BOSH/file-share/host-meta, modules/services/xmpp.nix):
    # loopback-only, reached through the Cloudflare Tunnel via Traefik's `cloudflare` entry
    # point. Not 5280 - that is prosody's public-by-default port and the number the retired
    # IPv6 era opened in the firewall; the replacement sits on the registry ladder instead.
    prosodyHttp = 8151;
    # The UltraTrainer web app on the TU cluster, surfaced on hp (modules/services/
    # datalab-harness.nix web tunnels): the SAME number is hp's loopback forward-bind
    # AND the UT_PORT the app binds on the cluster head - ssh -L bridges identical
    # ports, so one registry entry describes both ends. Traefik routes
    # ultra-trainer.datalab.hp here.
    ultraTrainer = 8146;
    # The robot-side UltraTrainer instance (modules/services/lab-web-tunnels.nix):
    # hp's loopback bind == the app's bind on the robot, same one-number doctrine.
    # Distinct from ultraTrainer (the datalab instance) AND from whatever the robots run
    # locally - r4uai01 already has a foreign :8000 service (measured 2026-11-13).
    # r4uai00 can earn its own entry later; do not reserve numbers here for it.
    ultraTrainerR4uai01 = 8148;
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

    # Grafana Alloy's own /metrics + UI listener (modules/services/loki.nix). NOT the
    # component's 12345 default: PORTS.i2pdRouter owns that (the duplicate-port
    # assertion caught it), so loki.nix passes --server.http.listen-addr explicitly and
    # the scrape job reads the same key.
    alloy = 12346;

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
    # 8470/8471 freed 2026-11-14 with the retired phone-pairing pages (audit
    # finding #9): the modules and their Traefik routes are deleted; do not
    # reuse these ports without re-checking nothing still caches them.
    netbirdWireguard = 51820;
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
