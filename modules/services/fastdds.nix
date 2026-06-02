{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.services.fastdds.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the FastDDS discovery server container";
    };
  };

  config = lib.mkIf config.MODULES.services.fastdds.enable {
    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;
    };

    virtualisation.oci-containers = {
      backend = "docker";
      containers.fastdds_discovery = {
        image = "ros:humble-ros-base-jammy";
        extraOptions = [
          "--privileged" # Required for network access
          "--network=host" # Use host networking for discovery
          "--ipc=host" # Share IPC namespace
        ];
        # Start FastDDS discovery server on all interfaces
        cmd = [
          "/opt/ros/humble/bin/fastdds"
          "discovery"
          "-i"
          "0"
          "-l"
          "0.0.0.0"
          "-p"
          "11811"
          "-t"
          "0.0.0.0"
          "-q"
          "42100"
        ];
      };
    };

    networking.firewall.allowedUDPPorts = [config.PORTS.fastddsDiscovery];
    networking.firewall.allowedTCPPorts = [
      config.PORTS.fastddsDiscovery
      config.PORTS.fastddsData
    ];
  };
}
