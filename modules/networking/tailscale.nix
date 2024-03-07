{config, pkgs, lib, ... }:
{
# tailscale
    config = lib.mkIf config.services.tailscale.enable {
        networking.firewall.allowedUDPPorts = [ 41641 ];
        networking.firewall.allowedTCPPorts = [ 41641 ];
        networking.firewall.checkReversePath = "loose";
    };
}
