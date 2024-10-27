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
        type = "zpool";
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };
        mountpoint = null;
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^zroot@blank$' || zfs snapshot zroot@blank";

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
