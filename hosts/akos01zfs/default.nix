{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  config,
  ...
}: {
  config = {
    #MODULES.nix.builders.airlab = true;
    #MODULES.security.vaultwarden.enable = true;
    #MODULES.networking.tailscale.hostIP = "100.71.138.61";
    #MODULES.networking.searx.enable = true;
    PROFILES.qemu-vm.enable = true;

    networking = {
      useDHCP = true;
    };

    #environment.systemPackages = with pkgs; [
    #  vim
    #  wget
    #  curl
    #  git
    #  htop
    #  tmux
    #  dnsutils
    #];

    #services.tailscale = {
    #  extraSetFlags = lib.mkForce ["--accept-dns=false" "--accept-routes=false" "--advertise-routes=10.50.0.0/23,10.44.0.0/24"];
    #  useRoutingFeatures = "both";
    #};

    #MODULES.security.sops.enable = true;
    #sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key" = {
    #  mode = "0400";
    #  #owner = "nix-serve";
    #  #group = "nix-serve";
    #};
    #services.nix-serve = {
    #  enable = true;
    #  secretKeyFile = config.sops.secrets."nix-serve/akos01.tail546fb.ts.net/private_key".path;
    #};
    #nix.settings = {
    #  download-buffer-size = 524288000; # 500 MiB
    #};

    networking.hostId = "68bf4e0e";
    boot.loader.grub.enable = true;
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.forceImportRoot = true;
    boot.loader.grub.zfsSupport = true;
    #fileSystems."/".device = "zroot/root";
    #fileSystems."/".fsType = "zfs";
    #fileSystems."/nix".device = "zroot/nix";
    #fileSystems."/nix".fsType = "zfs";
    #fileSystems."/boot".device = "/dev/disk/by-partlabel/disk-VDA-boot-ext4";
    #fileSystems."/boot".fsType = "ext4";

    disko.devices.disk = {
      VDA = {
        device = "/dev/vda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # BIOS Boot Partition for GRUB core image embedding
            };
            boot-ext4 = {
              size = "1G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/boot";
                mountOptions = ["defaults"];
              };
            };
            ZFS = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
    };

    disko.devices.zpool = {
      zroot = {
        type = "zpool";
        mountpoint = null;
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };

        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
          };
        };
      };
    };
  };
}
