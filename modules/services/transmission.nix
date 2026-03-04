{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.transmission;
in {
  options.MODULES.services.transmission = {
    enable = mkEnableOption "Transmission BitTorrent daemon";

    downloadDir = mkOption {
      type = types.str;
      default = "/var/lib/transmission/Downloads";
      description = "Directory where completed downloads are saved";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/transmission";
      description = "Directory where Transmission stores its data";
    };
  };

  config = mkIf cfg.enable {
    services.transmission = {
      enable = true;
      home = cfg.dataDir;

      settings = {
        rpc-port = config.PORTS.transmissionRpc;
        rpc-bind-address = "127.0.0.1";
        rpc-whitelist-enabled = false;
        rpc-host-whitelist-enabled = false;
        peer-port = config.PORTS.transmissionPeer;
        peer-port-random-on-start = false;
        download-dir = cfg.downloadDir;
        incomplete-dir = "${cfg.dataDir}/.incomplete";
        incomplete-dir-enabled = true;
      };
    };

    networking.firewall.allowedTCPPorts = [config.PORTS.transmissionPeer];
    networking.firewall.allowedUDPPorts = [config.PORTS.transmissionPeer];

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.path_routes = {
      "/transmission" = "http://127.0.0.1:${toString config.PORTS.transmissionRpc}/transmission";
    };
  };
}
