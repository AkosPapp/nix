{
  disko.devices = {
    disk = {
      samsung-pm9a1 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-SAMSUNG_MZVL21T0HCLR-00BL2_S64NNF0X101746";
        content = {
          type = "gpt";
          partitions = {
            NIXOS_BOOT = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                extraArgs = ["-n" "NIXOS_BOOT"];
              };
            };
            ZFS = {
              end = "-32G";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            NIXOS_SWAP = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = true; # resume from hiberation from this device
                extraArgs = ["-L" "NIXOS_SWAP"];
              };
            };
          };
        };
      };
    };

    zpool = {
      zroot = {
        datasets = {
          "persist/legion5/system-connections" = {
            type = "zfs_fs";
            mountpoint = "/etc/NetworkManager/system-connections";
          };
          "persist/legion5/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
          };
          "persist/legion5/home/akos" = {
            type = "zfs_fs";
            mountpoint = "/home/akos";
          };
        };
      };
    };
  };
}
