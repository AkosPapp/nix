{ config, pkgs, options, lib, ... }: {
  options = {
    MODULES.networking.sshd.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the OpenSSH daemon.";
    };
  };

  config = lib.mkIf config.MODULES.networking.sshd.enable {
    security.pam.enableSSHAgentAuth = true;
    programs.ssh.forwardX11 = true;
    services.openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
  };
}
