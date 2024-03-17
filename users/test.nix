{config, pkgs, lib, pkgs-unstable, home-manager, ... }:
{
    options = {
        USERS.test.enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Enable the user test";
        };
    };


    #imports = if config.USERS.test.enable then [
    #    home-manager.nixosModules.home-manager
    #    {
    #        home-manager.useGlobalPkgs = true;
    #        home-manager.useUserPackages = true;
    #        home-manager.users.test = import ./home.nix;
    #
# Op#tionally, use home-manager.extraSpecialArgs to pass
# ar#guments to home.nix
    #    }
    #]
    #else [];

    config = lib.mkIf config.USERS.test.enable {

        users.users.test = {
            isNormalUser = true;
            shell = pkgs.zsh;
            description = "Papp Akos";
            extraGroups = [ "dialout" "networkmanager" "wheel" "libvirtd" "docker" "input" "uinput" "plugdev" "vboxusers" ];
            hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
        };
        programs.zsh.enable = true;


        MODULES = {
            fonts.nerdfonts.enable = true;
            games.steam.enable = true;
            system.binbash.enable = true;
            system.bluetooth.enable = true;
            system.gpg.enable = true;
            system.sound.enable = true;
            virtualisation.docker.enable = true;
            virtualisation.virtualbox.enable = true;
            virtualisation.virt-manager.enable = true;
            wm.dwm.enable = true;
        };

# Allow unfree packages
        nixpkgs.config.allowUnfree = true;

        environment.systemPackages = with pkgs; [
# helpful tools
            starship
                ripgrep
                httm
                mpv
                tmux
                fd
                fzf
                rsync
                htop
                neofetch
                cowsay
                graphviz

# system tools
                usbutils
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


# python
                (python311.withPackages(ps: with ps; [
                                        cstruct
                                        numpy
                                        pip
                                        matplotlib
                                        transforms3d
                                        cycler
                                        jedi-language-server
                                        bpython
                                        pep8
                                        notebook
                                        gitpython
                                        jupyter
                                        jupyter-lsp
                                        jupyterlab
                                        jupyterlab-lsp
                                        jupyterlab-server
                                        jupyter-collaboration
                ]))
                sage

# git
                gitFull
                gh

# c++
                gcc
                clang-tools
                gnumake
                cmake
# rust
                cargo
                cargo-valgrind
                bacon
                clippy
                dprint
                rust-analyzer
                pkgs-unstable.rustc
# POSIX
                shellcheck
# dev tools
                vscode
                gitkraken
                jetbrains-toolbox
                openjdk17-bootstrap
                rpi-imager
                gparted
                distrobox

# user tools
                networkmanagerapplet
                zotero
                dracula-theme
                keepassxc
                inkscape
                pcmanfm
                flameshot
                syncthing
                sxiv
                pinentry
                brave
                kitty
                nitrogen
                whatsapp-for-linux
                signal-desktop
                discord
                libreoffice
                logseq
                freecad
                librecad

# qemu
                qemu_full
                qemu-utils
                ];

        boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv6l-linux" "armv7l-linux" ];
    };

}
