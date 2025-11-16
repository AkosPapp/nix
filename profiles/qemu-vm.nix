{
  config,
  lib,
  modulesPath,
  ...
}: {
  options = {
    PROFILES.qemu-vm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable global profile";
    };
  };

  # todo fix this
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  config = lib.mkIf config.PROFILES.qemu-vm.enable {
    MODULES.networking.tailscale.enable = true;
    MODULES.virtualisation.docker.enable = true;
    MODULES.networking.sshd.enable = true;

    boot.loader.grub.enable = true;
    services.qemuGuest.enable = true;

    boot.initrd.availableKernelModules = [
      "uhci_hcd"
      "ehci_pci"
      "ahci"
      "virtio_pci"
      "sr_mod"
      "virtio_blk"
    ];

    systemd.suppressedSystemUnits = [
      "dev-mqueue.mount"
      "sys-kernel-debug.mount"
      "sys-fs-fuse-connections.mount"
    ];
  };
}
