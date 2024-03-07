{config, pkgs, lib, ... }:
{
    config = lib.mkIf config.programs.virt-manager.enable {
        virtualisation.libvirtd.enable = true;
        programs.dconf.enable = true;
        environment.systemPackages = with pkgs; [
            virt-manager
                libvirt
                qemu
        ];
    };
}
