{ config, pkgs, ... }:

{
    imports = [ ./hardware-configuration.nix ];

#  # Bootloader.
#  boot.loader.efi.efiSysMountPoint = "/boot/efi";

    networking = {
        networkmanager.enable = true;
        hostId = "68bf4e0e";
        hostName = "laptop";
        extraHosts =
            ''
            127.0.0.1 localhost 
            '';
    };


# Enable CUPS to print documents.
    services.printing.enable = true;
    services.printing.drivers = [ pkgs.gutenprint ];
    services.avahi = {
        enable = true;
        nssmdns = true;
    };


    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 7d";
    };

    system.stateVersion = "23.11";

    USERS.akos.enable = true;
    services.znapzend.enable = true;

    services.xserver.displayManager.sddm.enable = true;
}

