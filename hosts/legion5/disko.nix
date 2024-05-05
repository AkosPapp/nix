{
  disko.devices = {
    disk = {
      samsung980 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S649NX0T114882D";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "64M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            zfs = {
              end = "-32G";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = true; # resume from hiberation from this device
              };
            };
          };
        };
      };
      samsung-pm9a1 = { # FIXTHIS
        type = "disk";
        device =
          "/dev/disk/by-id/nvme-SAMSUNG_MZVL21T0HCLR-00BL2_S64NNF0X101746"; # FIXTHIS
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              end = "-32G";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
                resumeDevice = true; # resume from hiberation from this device
              };
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        mode = "stripe";
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };
        mountpoint = "none";
        postCreateHook =
          "zfs list -t snapshot -H -o name | grep -E '^zroot@blank$' || zfs snapshot zroot@blank";

        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
          };
          "persist" = {
            type = "zfs_fs";
            mountpoint = "none";
          };
          "persist/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
          };
        };
      };
    };
  };
}

