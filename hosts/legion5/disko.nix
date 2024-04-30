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
              size = "100%";
              content = {
                type = "zfs";
                pool = "zroot";
              };
            };
          };
        };
      };
      y = {
        type = "disk";
        device = "/dev/sdy";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
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
    zpool = {
      zroot = {
        type = "zpool";
        mode = "mirror";
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };
        mountpoint = "none";
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^zroot@blank$' || zfs snapshot zroot@blank";

        datasets = {
          "persistent/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
          };
          root = {
            type = "zfs_fs";
            mountpoint = "/";
          };
        };
      };
    };
  };
}

