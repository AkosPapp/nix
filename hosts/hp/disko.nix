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
          # Live-box parity (already-present chain is NOT recreated by disko) - the two
          # manual steps below were applied to the live pool on 2026-10-26:
          #   zfs set mountpoint=/persist zroot/persist      (was the /zroot/persist default)
          #   zfs set mountpoint=/persist/hp zroot/persist/hp
          #   zfs create -o mountpoint=/var/lib/pgdump zroot/persist/hp/dump   # new child
          "persist" = {
            type = "zfs_fs";
            mountpoint = "/persist";
          };
          "persist/hp" = {
            type = "zfs_fs";
            mountpoint = "/persist/hp";
          };
          # dump is what killed the first 2026-10-26 deploy: declaring a dataset makes disko
          # emit a REQUIRED mount for its mountpoint, the dataset did not exist yet, the
          # failing var-lib-pgdump.mount failed local-fs.target, and systemd pulled in
          # emergency.target mid-activation (magic-rollback recovered the box, but only a
          # console reboot did after that). The znapzend-pg-dump ExecStartPre in
          # hosts/hp/default.nix creates the dataset lazily, so this mount is intentionally
          # not load-bearing: nofail turns a missing dump dataset back into a plain
          # `zfs list` gap instead of an emergency shell.
          "persist/hp/dump" = {
            type = "zfs_fs";
            mountpoint = "/var/lib/pgdump";
            mountOptions = [ "defaults" "nofail" ];
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
