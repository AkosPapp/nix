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
    networkmanager.enable = true;
    hostId = "68bf4e0e";
    hostName = "laptop-srv";
    extraHosts = ''
      127.0.0.1 localhost
    '';
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  system.stateVersion = "24.05";

  MODULES.virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
  USERS.admin.enable = true;

  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
}
