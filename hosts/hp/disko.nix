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
          # PLAN §4.3: the persist chain made explicit. These three already exist on the
          # live pool as implicit ancestors of persist/hp/sftpgo (disko creates the parent
          # chain and ZFS inherits mountpoint) - declaring them pins their properties so a
          # re-apply and `zfs get` agree, and the replica plan (persist/hp recursive) has
          # an authored home. dump = §4.1 L3 landing point for the nightly pg_dumpall,
          # recursive-replicated to akos01 as a child of persist/hp.
          #
          # Live-box parity (already-present chain is NOT recreated by disko, so verify
          # once after deploy):
          #   zfs get mountpoint zroot/persist zroot/persist/hp   # -> /persist /persist/hp
          #   zfs create -o mountpoint=/var/lib/pgdump zroot/persist/hp/dump   # new child
          "persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
          };
          "persist/hp" = {
            type = "zfs_fs";
            mountpoint = "/persist/hp";
          };
          "persist/hp/dump" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/pgdump";
          };
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
