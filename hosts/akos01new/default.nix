{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  config,
  ...
}: {
  config = {
    MODULES.nix.builders.airlab = true;
    MODULES.security.vaultwarden.enable = true;
    MODULES.networking.tailscale.hostIP = "100.71.138.61";
    MODULES.networking.searx.enable = true;
    PROFILES.qemu-vm.enable = true;

    networking = {
      useDHCP = true;
    };

    environment.systemPackages = with pkgs; [
      vim
      wget
      curl
      git
      htop
      tmux
      dnsutils
    ];

    services.tailscale = {
      extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24"];
      useRoutingFeatures = "both";
    };

    MODULES.security.sops.enable = true;
    sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key" = {
      mode = "0400";
      #owner = "nix-serve";
      #group = "nix-serve";
    };
    services.nix-serve = {
      enable = true;
      secretKeyFile = config.sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key".path;
    };
    nix.settings = {
      download-buffer-size = 524288000; # 500 MiB
    };

    boot.supportedFilesystems = ["zfs"];
    boot.zfs.forceImportRoot = false;
    networking.hostId = "68bf4e0e";

    disko.devices = {
      disk = {
        vdb = {
          device = "/dev/vdb";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "1M";
                type = "EF02"; # for grub MBR
              };
              root = {
                size = "100%";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };
      };
    };
  };
}
