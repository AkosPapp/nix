{lib, ...}: {
  PROFILES.zroot.enable = lib.mkForce false;
  disko.devices = {
    disk = {
      vdb = {
        type = "disk";
        device = "/dev/vdb";
        content = {
          type = "gpt";
          efiGptPartitionFirst = false;
          partitions = {
            TOW-BOOT-FI = {
              priority = 1;
              type = "EF00";
              size = "32M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = null;
              };
              hybrid = {
                mbrPartitionType = "0x0c";
                mbrBootableFlag = false;
              };
            };
            ESP = {
              type = "EF00";
              size = "512M";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
      # vdb = {
      # type = "disk";
      # device = "/dev/vdb";
      # content = {
      # type = "gpt";
      # partitions = {
      # NIXOS_BOOT = {
      # size = "1G";
      # type = "EF00";
      # content = {
      # type = "filesystem";
      # format = "vfat";
      # mountpoint = "/boot";
      # extraArgs = ["-n" "NIXOS_BOOT"];
      # };
      # };
      # ZFS = {
      # size = "100%";
      # content = {
      # type = "zfs";
      # pool = "zroot";
      # };
      # };
      # };
      # };
      # };
      # };
    };
  };
}
