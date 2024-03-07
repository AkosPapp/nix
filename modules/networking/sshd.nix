{config, pkgs, options, lib, ... }:
{
    options = {
        services.ssh.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the OpenSSH daemon.";
        };
    };

    config = lib.mkIf config.services.ssh.enable {
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
