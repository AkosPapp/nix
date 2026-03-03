{
  disko.devices = {
    disk = {
      samsung-980 = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S649NX0T114882D";
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

    # additional zpool definition for the sftpgo dataset
    zpool = {
      zroot = {
        type = "zpool";
        mountpoint = null;
        datasets = {
          # create a nested dataset named persist/hp/sftpgo
          "persist/hp/sftpgo" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/sftpgo";
          };
        };
      };
    };
  };
}
