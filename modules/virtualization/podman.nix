{config, pkgs, lib, ... }:
{
    config = lib.mkIf config.virtualisation.podman.enable {
        virtualisation.podman = {
            dockerCompat = true;
            defaultNetwork.settings.dns_enabled = true;
            extraPackages = [ pkgs.zfs ];
        };
    };
}
