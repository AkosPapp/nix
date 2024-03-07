{config, pkgs, lib, ... }:
{
    options = {
        programs.dwmblocks.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable custom dwmblocks";
        };
    };
    config = lib.mkIf config.programs.dwmblocks.enable {
        environment.systemPackages = with pkgs; [
            dwmblocks
        ];
        nixpkgs.overlays = [
            (final: prev: {
             dwmblocks = prev.dwmblocks.overrideAttrs (old: { src = /home/akos/Programs/dwmblocks ;});
             })
        ];
    };
}
