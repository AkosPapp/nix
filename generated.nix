{ imports = [
users/akos.nix
modules/virtualization/virtualbox.nix
modules/virtualization/docker.nix
modules/virtualization/virt-manager.nix
modules/fonts/nerdfonts.nix
modules/wm/dwm.nix
modules/wm/dwmblocks.nix
modules/games/steam.nix
modules/system/bluetooth.nix
modules/system/sound.nix
modules/system/locale.nix
modules/system/binbash.nix
modules/system/gpg.nix
modules/networking/sshd.nix
modules/networking/tailscale.nix
profiles/global.nix
];
  laptop = import ./hosts/laptop;
  server1 = import ./hosts/server1;
}
