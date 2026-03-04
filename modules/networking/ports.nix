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
    grafana = 8030;
    homepage = 8082;
    i2pdWebui = 8070;
    ipfsApi = 8050;
    ipfsGateway = 8010;
    nixAutobuild = 8085;
    prometheus = 8009;
    searx = 8081;
    sftpgoHttp = 8090;
    sftpgoWebdav = 8091;
    traefikDashboard = 8888;
    vaultwarden = 8222;
    transmissionRpc = 8001;

    # prometheus exporters
    prometheusNginxExporter = 9113;
    prometheusNodeExporter = 9100;
    prometheusPostgresExporter = 9187;
    prometheusTailscaleExporter = 9200;
    prometheusZfsExporter = 9134;

    # ports bound to tailscale IP
    i2pdHttpProxy = 4444;
    i2pdSam = 7656;
    i2pdSocksProxy = 4447;

    # external ports (open to network)
    i2pdRouter = 12345;
    ipfsSwarm = 4001;
    traefikHttp = 80;
    transmissionPeer = 51413;
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
