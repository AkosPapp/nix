{
  config,
  nixos-version,
  lib,
  ...
}: {
  options = {
    PROFILES.server.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable server profile";
    };
  };

  config = lib.mkIf config.PROFILES.server.enable {
    boot = {
      loader.systemd-boot.enable = true;
      loader.efi.canTouchEfiVariables = true;

      initrd = {
        availableKernelModules = ["nvme" "xhci_pci" "usbhid" "usb_storage" "sd_mod"];
        kernelModules = [];
      };
      kernelModules = ["kvm-amd"];
      kernelParams = ["consoleblank=300"]; # 300 seconds = 5 minutes
    };

    networking = {
      networkmanager.enable = false;
      extraHosts = ''
        127.0.0.1 localhost
      '';
      useDHCP = false;
    };

    MODULES.virtualisation.docker.enable = true;
    USERS.admin.enable = true;
    PROFILES.zroot.enable = true;

    services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
