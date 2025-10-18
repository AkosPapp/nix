{
  pkgs,
  modulesPath,
  my-nixvim,
  system,
  nixos-version,
  ...
}: {
  imports = ["${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"];
  MODULES.networking.sshd.enable = true;

  # TODO
}
