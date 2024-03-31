{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  #  # Bootloader.
  #  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking = {
    networkmanager.enable = true;
    hostId = "68bf4e0e";
    hostName = "laptop";
    extraHosts = ''
      127.0.0.1 localhost 
    '';
  };

  MODULES.system.printing.enable = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "23.11";

  USERS.akos.enable = true;
  USERS.test.enable = true;
  services.znapzend.enable = true;

  services.xserver.displayManager.sddm.enable = true;
}

