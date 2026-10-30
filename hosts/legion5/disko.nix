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
          # Job scratch, and the point of it is where it ISN'T: a sibling of persist/, not a
          # child. legion5's snapshot/replication scope (hosts/legion5/default.nix, PLAN §4.1-4.2)
          # is zroot/root + zroot/persist/legion5, so a top-level dataset falls outside both with
          # no exclusion rule to maintain - and multi-GB training/inference scratch stays out of
          # the hourly snaps and off the wire to hp. The other half of the reason: /tmp on this
          # box is a directory on zroot/root, i.e. ON the snapshotted dataset, which is why
          # Slurm's TmpFS is pointed here instead (modules/services/slurm.nix).
          #
          # refquota because /home shares this pool: scratch with no ceiling is how a laptop
          # reaches 100% and cannot boot. Raise it with `zfs set refquota=<size> zroot/scratch`.
          #
          # Live-box parity, per PLAN §4.3 (declare in disko, create by hand, keep them equal or
          # the next reboot disagrees): the dataset was created before the switch that declared it
          #   zfs create -o refquota=200G -o mountpoint=/scratch zroot/scratch
          # and `nofail` is here because of hp's 2026-10-26 activation, where a declared dataset
          # that did not exist yet made its required mount fail local-fs.target and pulled the
          # whole switch into emergency.target (see hosts/hp/disko.nix). A missing scratch should
          # cost a job, not the boot.
          "scratch" = {
            type = "zfs_fs";
            mountpoint = "/scratch";
            options.refquota = "200G";
            mountOptions = ["defaults" "nofail"];
          };
        };
      };
    };
  };
}
