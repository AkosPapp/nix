{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  PROFILES.server.enable = true;

  networking = {
    hostId = "68bf4e0e";
    hostName = "hp";
    interfaces = {
      enp4s0f3u1u1c2 = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = "10.0.1.1";
            prefixLength = 8;
          }
        ];
      };
    };
    defaultGateway = {
      address = "10.0.0.1";
      interface = "enp4s0f3u1u1c2";
    };
  };

}
