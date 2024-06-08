{
  config,
  pkgs,
  lib,
  ...
}: {
  options = {
    MODULES.virtualisation.virt-manager.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable virt-manager";
    };
  };

  config = lib.mkIf config.MODULES.virtualisation.virt-manager.enable {
    programs.virt-manager.enable = true;
    virtualisation.libvirtd.enable = true;
    programs.dconf.enable = true;
    environment.systemPackages = with pkgs; [virt-manager libvirt qemu];
  };
}
