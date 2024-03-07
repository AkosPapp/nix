{config, pkgs, lib, ... }:
{
    options = {
        users.akos.enable = lib.mkOption {
            default = false;
            type = lib.types.bool;
            description = "Enable the user akos";
        };
    };

    config = lib.mkIf config.users.akos.enable {
        users.users.akos = {
            isNormalUser = true;
            shell = pkgs.zsh;
            description = "Papp Akos";
            extraGroups = [ "dialout" "networkmanager" "wheel" "libvirtd" "docker" "input" "uinput" "plugdev" "vboxusers" ];
            hashedPassword = "$y$j9T$gEhP/0Jlrlwb4ndmLs06L1$7qkdPdgqjCrEH8bAQvJqRn/Mj4m5X9GCRAyM33z0mdA";
        };

        environment.binbash = true;
        programs.zsh.enable = true;
        programs.dwm.enable = true;
        virtualisation.docker.enable = true;
        programs.virt-manager.enable = true;
        virtualisation.virtualbox.enable = true;
        sound.enable = true;
        services.tailscale.enable = true;
        programs.steam.enable = true;
        programs.gpg.enable = true;



# Allow unfree packages
        nixpkgs.config.allowUnfree = true;
        nixpkgs.config.permittedInsecurePackages = [
            "electron-25.9.0"
        ];

# List packages installed in system profile. To search, run:


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
# POSIX
                shellcheck
# dev tools
                vscode
                gitkraken
                jetbrains-toolbox
                openjdk17-bootstrap
                rpi-imager
                gparted

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
                ];
    };

}
