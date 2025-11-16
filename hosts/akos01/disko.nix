{lib, ...}: {
  PROFILES.zroot.enable = lib.mkForce false;

  disko.devices = {
    disk = {
      vdb = {
        device = "/dev/vdb";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # for grub MBR
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
