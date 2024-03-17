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
    services.printing = {
        enable = true;
        drivers = with pkgs; [ gutenprint canon-cups-ufr2 cups-filters  samsung-unified-linux-driver  ];
    };

    environment.systemPackages = with pkgs; [
        hplipWithPlugin
        xsane
        dbus
        cups-pk-helper
        avahi
        libjpeg
        libthreadar
        libusb1
        sane-airscan
        libtool
        python311Packages.notify2
        sane-backends
    ];
    # services.avahi = {
    #     enable = true;
    #     nssmdns = true;
    # };
    # services.printing.browsing = true;
    # services.printing.browsedConf = ''
    #     BrowseDNSSDSubTypes _cups,_print
    #     BrowseLocalProtocols all
    #     BrowseRemoteProtocols all
    #     CreateIPPPrinterQueues All
    #     BrowseProtocols all
    #     '';


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

