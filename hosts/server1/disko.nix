{ disko }: {
  imports = [ disko.nixosModules.disko ];
  disko.devices = {
    disk = {
      main = {
        device = "/dev/disk/by-id/usb-Verbatim_STORE_N_GO_23101424050993-0:0";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              type = "EF00";
              size = "500M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            }; # ESP
            swap = {
              size = "8G";
              content = {
                type = "swap";
                resumeDevice = true; # resume from hiberation from this device
              };
            }; # swap
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            }; # root
          };
        };
      }; # main

      vdev1 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-ST1000LM014-1EJ164_W380W05X";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "data-pool";
              };
            };
          };
        };
      }; # vdev1

      vdev2 = {
        type = "disk";
        device = "/dev/disk/by-id/ata-TOSHIBA_MQ01ABD100_X2V8SFXWS";
        content = {
          type = "gpt";
          partitions = {
            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "data-pool";
              };
            };
          };
        };
      }; # vdev2

    }; # disk
    zpool = {
      data-pool = {
        type = "zpool";
        mode = "mirror";
        rootFsOptions = {
          compression = "off";
          "com.sun:auto-snapshot" = "false";
        };
        mountpoint = "/data-pool";
        postCreateHook =
          "zfs list -t snapshot -H -o name | grep -E '^data-pool@blank$' || zfs snapshot zroot@blank";
        datasets = { }; # datasets
      };
    }; # zpool
  }; # disko
}

