{config, pkgs, lib, ... }:
{
    options = {
        USERS.admin.enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Admin user for Servers";
        };
    };

    config = lib.mkIf config.USERS.admin.enable {
        users.users.admin = {
            isNormalUser = true;
            description = "Admin";
            extraGroups = [ "wheel" "docker" "input" "uinput" "plugdev" ];
            hashedPassword = "$y$j9T$3G1lwFZrgipfzE8NwHKjC1$mnTAupZ2cQ1WHuZNLK9TT3MkdgEB18LYn6LjFecpsu6";
            openssh.authorizedKeys.keys = [
                "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCYoxGrmlgUcVfncMnlDONPk5RwSEqbiBpvT3c2m9MIDsYdYlLfnRN5YJPZgp8CHcPnPK2rboRiHAO00j545ci2CDeAp6zGKoOhX0q/3fES3ySqMG7lJ+cplxoXekSL9GNOQqSREDymqrMfqGy9OnupqcAZForX/k1aegi99TgZwbGMAK/UIzfdkQr49VVzYbaNR14rikIfjvi23s4bdP/KgeAs0T9KEKKSAd9WJQxUr/dmTjNBODzW10llgmCCVRNk3Pj4A1qiGiz0wkjG7XmZT0QjHyrX2GzSYuhW1l8s6mY3tTBBKVoj+peBphgxGBbEwUCQh0yPVBGstM5fHqN1bvOjRfYNQboVSmLhicX7Bk0WNLPS6DtqHZTXGNuYM8NcHn4xUIX5GwlsS6Mfo2tDMcX83w1Jv0BuImfcUMl6jvYCzcpEdGENYHWisIvQLSlAK6UEIYGeG8CH/iRqRPQIrOW49EQJYlW2VSLuTf8SA6c9Z2xdSIsli9JOfr79VUdYpgrdiv7vFjiX5d+hcJVC0rjQkF6XlAWVH5yMfpr1OXFbpKqILygx9Zcj7IhMHodQsjtr6+FjIs5Xm5Nt1nY9Cpke/q3lHcgq0PVgwvMPMhTOxfv6XoKQGmDTJWsmAP8n4BotZm7H2OlO29/zJnrgJ8+ZienkAX5s2cAaT16Kvw== akos@laptop"
            ];
        };

        environment.systemPackages = with pkgs; [
# helpful tools
            tmux
                rsync
                htop

# system tools
                sshpass
                sshfs
                lm_sensors
                lsof
                cryptsetup
                openssl
                lz4
                nmap
                iperf2
                netcat
                file
                tree
                dig
                pciutils
                acpi
                glib
                wget
                ffmpeg
                zip
                unzip
                killall
                bc
                fuse
                wireguard-tools

# nvim
                neovim
                xclip
                tree-sitter
                lua-language-server
                cmake-language-server
                lldb
                gdb
                nil
                nixd
                valgrind
                nodejs_18



# git
                gitFull
                gh

# POSIX
                shellcheck
                ];
    };

}
