{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [./hardware-configuration.nix];

  #  # Bootloader.
  #  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking = {
    networkmanager.enable = false;
    hostId = "68bf4e0e";
    hostName = "laptop-srv";
    extraHosts = ''
      127.0.0.1 localhost
    '';
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
    nameservers = ["100.100.100.100" "9.9.9.9" "1.1.1.1" "8.8.8.8"];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "24.05";

  MODULES.virtualisation.docker.enable = true;
  USERS.admin.enable = true;

  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
}
