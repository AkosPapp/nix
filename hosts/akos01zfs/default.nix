{
  pkgs,
  lib,
  modulesPath,
  pkgs-unstable,
  config,
  ...
}: {
  config = {

    users.users.root.hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";

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
    boot.zfs.devNodes = "/dev";
    boot.loader.grub.zfsSupport = true;

    # Explicit mount order - root must mount first
    fileSystems."/" = {
      device = "zroot/root";
      fsType = "zfs";
      neededForBoot = true;
    };
    fileSystems."/nix" = {
      device = "zroot/nix";
      fsType = "zfs";
      neededForBoot = true;
    };

    # Add both swap partitions
    swapDevices = [
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDA";}
      {device = "/dev/disk/by-label/NIXOS_SWAP_VDB";}
    ];

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
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDA"]; # unique label for the swap partition on vda
              };
            };
          };
        };
      };
      VDB = {
        device = "/dev/vdb";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              end = "-16G"; # leave 16G for swap at the end of the disk
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = false; # resume from hibernation from this device
                extraArgs = ["-L" "NIXOS_SWAP_VDB"]; # unique label for the swap partition on vdb
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
            options.canmount = "noauto";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.canmount = "noauto";
          };
        };
      };
    };
  };
}
