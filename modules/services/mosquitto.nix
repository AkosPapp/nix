{
  config,
  lib,
  ...
}: {
  options = {
    MODULES.services.mosquitto.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the Mosquitto MQTT broker";
    };
  };

  config = lib.mkIf config.MODULES.services.mosquitto.enable {
    services.mosquitto = {
      enable = true;
      listeners = [
        {
          # Bind on all IPv4 and IPv6 interfaces
          address = "0.0.0.0";
          port = config.PORTS.mosquitto;

          # Authentication settings - allow anonymous for development
          settings.allow_anonymous = true;
          omitPasswordAuth = true;

          # Access Control List - full read/write access for all topics
          acl = ["pattern readwrite #"];
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [config.PORTS.mosquitto];
  };
}
