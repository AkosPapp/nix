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

    # Scoped to tailscale0 per the 2026-10-24 audit (#2): FastDDS discovery is
    # unauthenticated by design, so it must not answer on any other interface. Caveat:
    # clients that reach this host over a plain LAN instead of the tailnet lose access -
    # if that turns out to matter, add that interface explicitly here rather than
    # reverting to all-interfaces.
    networking.firewall.interfaces.tailscale0 = {
      allowedUDPPorts = [config.PORTS.fastddsDiscovery];
      allowedTCPPorts = [
        config.PORTS.fastddsDiscovery
        config.PORTS.fastddsData
      ];
    };
  };
}
