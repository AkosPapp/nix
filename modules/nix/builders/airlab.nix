{
  lib,
  config,
  ...
}: {
  options = {
    MODULES.nix.builders.airlab = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Airlab builders";
    };
  };

  config = lib.mkIf config.MODULES.nix.builders.airlab {
    MODULES.security.sops.enable = true;
    sops.secrets."nix-builder/private_key" = {
      mode = "0400";
      owner = "root";
      group = "root";
      path = "/root/.ssh/id_ed25519";
    };

    # remote build
    nix.buildMachines = [
      {
        sshUser = "builder";
        hostName = "r4unb02.airlab";
        #system = "x86_64-linux";
        protocol = "ssh-ng";
        # if the builder supports building for multiple architectures,
        # replace the previous line by, e.g.
        systems = ["x86_64-linux" "aarch64-linux"];
        maxJobs = 60;
        speedFactor = 2;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        mandatoryFeatures = [];
        sshKey = config.sops.secrets."nix-builder/private_key".path;
      }
    ];
    nix.distributedBuilds = true;
    # optional, useful when the builder has a faster internet connection than yours
    nix.extraOptions = ''
      builders-use-substitutes = true
    '';

    # The daemon dials ssh-ng with sshKey but takes its pin/host options from ssh's own
    # config, and neither nix nor the daemon has a pin for r4unb02 by default (this box
    # never had one: 2026-11-11 "Host key verification failed" during the re-enable). Same
    # doctrine as the herdr/znapzend blocks: dedicated alias-free Host stanza (the hostname
    # IS the builder name here; no admin path collides with IdentitiesOnly, because no
    # human dials builder@r4unb02), pins supplied here, and BatchMode so an auth/hostkey
    # problem fails loud into the nix log instead of hanging on a prompt.
    # Key material: users' TOFU pins, cross-checked 2026-11-11 between legion5's
    # known_hosts, akos01's pin and a fresh hp keyscan over the transit - all three match;
    # the lab owns the box, so a re-key WILL surface as a loud pin failure, which is the
    # intended behaviour for a machine we do not administer.
    # 2026-11-14 (audit #5 close-out): the audit measured the deployed pins NOT matching
    # the builder's live keys, so offload failed closed (pinning working as designed - loud
    # failure, no TOFU). Re-verified from a trusted position today: r4unb02 is invisible
    # from the r4uai00 netbird VLAN (NXDOMAIN + no ICMP), so the keys were scanned as
    # 172.18.2.21 from akos01 - the same transit /32 the daemon path rides. Pinned ==
    # scanned byte-for-byte for both keys (ed25519
    # SHA256:KckGa8FSlCMoG6vQwWX2xXy/rV+qHhu04xhOJgoHfoc, rsa
    # SHA256:MrA1+092DkIY6wYedH2Afdlh2jU0000ezRY8udyj8N0), the deployed /etc/ssh/
    # airlab-known-hosts on akos01 AND hp match, and BatchMode ssh to builder@r4unb02.airlab
    # against the pinned file now returns 0. If it ever mismatches again: re-scan over the
    # transit and confirm with the lab before touching these lines - never TOFU-accept.
    MODULES.networking.sshClient.blocks = [
      ''
        Host r4unb02.airlab
          IdentityFile ${config.sops.secrets."nix-builder/private_key".path}
          IdentitiesOnly yes
          BatchMode yes
          UserKnownHostsFile /etc/ssh/airlab-known-hosts
          StrictHostKeyChecking yes
      ''
    ];
    environment.etc."ssh/airlab-known-hosts".text = ''
      r4unb02.airlab ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTcgbKLiOQ9u4GIN+V17YMvaVMvKzBQx6O0QYZ0Hd3K
      r4unb02.airlab ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCQfJqXDcfVu8YZ36wTTqDDo+htthJuOSbIndWea+4bUijbz39R64X5wIT+PyJEitooQCS4ctkxpjQt0A3UA3+bXZDNv3rSP1fo5ZY91hnV3vOEkr2YMk+GSuj4EnGjkiIJQJL5FS534PhAn9UOLbCSTphd0dqpxvBWGDt3ytafhUQQfZdDGBSVsztVKji+/joOc58rP8lBJT21f/roBBGQbZhc0YHv1JDK54uGZHiXfXIxvNr0p2avPmXl6A6iHJjkASNnZzbxHRmEZ+Y4Jt3Mrp9ssRz85weMv8FqYAc0SaVcCLNJVMhLPYE3i/nn4d444jpoNl8y2SiglX7Io2LFeVCjGc5rFKARHr067fu76q/sWcfY96I9dmm/WIomIjueGZTzXoVgEaaCVI2Hp22jDd0KUMRDhE70762UezUuPD/wqe8sRXVMTYtIOUPLsbaakzUrfc14d0IGANAtYeal3dthDKjPD+d6EAKPrjIvVQZFpHIwDPkNTvTu5ymNeb5E+PzyQSTnqINL3KBs49B/HHqThbxHnyJaIaKwdYCCc81QAOLcv+pjvI/KW8IxOjVpGIfIB/8SgjC+WfHDI0ONrmrwWl2PNwYV4cZZ8vzlQanuQoH9E+xTxIcZt6D6cAf6z5OvU1yQ6nHYbg2sp8hx4xSxunQVVQ2KN26ISCZXZQ==
    '';
  };
}
