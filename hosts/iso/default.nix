{
  modulesPath,
  lib,
  ...
}: {
  imports = ["${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"];
  MODULES.networking.sshd.enable = true;
  MODULES.networking.tailscale.enable = lib.mkForce false;
  networking.useDHCP = true;

  systemd.services.show-ip = {
    description = "Display IP address on console";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        sh -c 'echo "IP Address: $(hostname -I)" > /dev/tty1'
      '';
    };
  };
}
