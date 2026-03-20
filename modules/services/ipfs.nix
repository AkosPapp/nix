{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.ipfs;
in {
  options.MODULES.services.ipfs = {
    enable = mkEnableOption "IPFS Kubo daemon";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/ipfs";
      description = "Directory where IPFS data is stored";
    };

    storageMax = mkOption {
      type = types.str;
      default = "10GB";
      description = "Maximum disk storage for the IPFS datastore (e.g. 50GB, 100GiB)";
    };
  };

  config = mkIf cfg.enable (
    let
      apiPort = toString config.PORTS.ipfsApi;
      gatewayPort = toString config.PORTS.ipfsGateway;
      swarmPort = toString config.PORTS.ipfsSwarm;
      fqdn = config.networking.fqdn;
      tailscaleIP = config.MODULES.networking.tailscale.hostIP;
    in {
      services.kubo = {
        enable = true;
        dataDir = cfg.dataDir;

        settings = {
          Addresses = {
            API = [
              # "/ip4/127.0.0.1/tcp/${apiPort}"
              "/ip4/${tailscaleIP}/tcp/${apiPort}"
            ];
            Gateway = [
              # "/ip4/127.0.0.1/tcp/${gatewayPort}"
              "/ip4/${tailscaleIP}/tcp/${gatewayPort}"
            ];
            Swarm = [
              "/ip4/0.0.0.0/tcp/${swarmPort}"
              "/ip6/::/tcp/${swarmPort}"
              "/ip4/0.0.0.0/udp/${swarmPort}/quic-v1"
              "/ip6/::/udp/${swarmPort}/quic-v1"
            ];
          };
          API.HTTPHeaders = {
            Access-Control-Allow-Origin = [
              "https://${fqdn}"
              "http://${fqdn}:${apiPort}"
              "https://${fqdn}:${apiPort}"
              "https://${tailscaleIP}"
              "http://${tailscaleIP}:${apiPort}"
              "https://${tailscaleIP}:${apiPort}"
            ];
            Access-Control-Allow-Methods = ["PUT" "POST" "GET"];
          };
          Datastore.StorageMax = cfg.storageMax;
          AutoNAT.ServiceMode = "enabled";
          Swarm.ConnMgr = {
            HighWater = 200;
            LowWater = 150;
            GracePeriod = "300s";
          };
          Gateway = {
            PublicGateways = {
              # "${fqdn}" = {
              #   Paths = ["/ipfs" "/ipns"];
              #   UseSubdomains = false;
              # };
              "ipfs.io" = {
                Paths = ["/ipfs" "/ipns"];
                UseSubdomains = true;
              };
            };
          };
        };
      };
      networking.firewall.allowedTCPPorts = [config.PORTS.ipfsSwarm];
      networking.firewall.allowedUDPPorts = [config.PORTS.ipfsSwarm];
    }
  );
}
