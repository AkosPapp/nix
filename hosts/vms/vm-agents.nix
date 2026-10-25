# PLAN.md §6: the microVM pipeline, proven by ONE prototype guest before any jail flips
# backend. Per the review decision ("ram is not an issue ... everything in microvm with
# firecracker"), this is the pattern every Tier-B service will follow:
#
#   guest = this file's shape (microvm module + bridge tap + static IP + tailscale)
#   host  = modules/vm/microvm-host.nix on hp (creates mvbr0, NAT, runs the VMMs)
#   flake = microvmConfigurations.<name> wired into MODULES.system.microvmHost.vms
#
# The guest keeps its own tailscale identity (manual `tailscale up --authkey` over the
# console once - the keypair/ACL step lives in PLAN.md's manual list), joins the tailnet
# as a first-class node, and the SERVICE_GRAPH edges apply to it like any other peer.
# coroot-node-agent IS inside (the systemd unit below): the guest is its own kernel, so
# its services get their own node in the Coroot map instead of only the tap-side flows
# the host agent can see.
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  imports = [inputs.microvm.nixosModules.microvm];

  nixpkgs.overlays = [inputs.microvm.overlays.default];

  microvm = {
    mem = 1024; # MB - the §6 budget rows start conservative; LIMITS counts VMs later
    vcpu = 2;
    # Firecracker is the explicit choice from the review (not qemu):
    hypervisor = "firecracker";
    socket = "/run/microvm/${config.networking.hostName}.sock";
    interfaces = [
      {
        # firecracker's runner speaks tap only (bridge/user are qemu-isms); the HOST
        # enslaves every mv-* tap into mvbr0 via systemd-networkd (microvm-host.nix).
        type = "tap";
        id = "mv-vm-agents-0";
        mac = "02:00:00:00:00:0a"; # the guest matches its netdev on this MAC (below)
      }
    ];
    # /nix/store arrives read-only from the host via virtiofs (microvm default); the VM
    # needs no store disk, no rebuild space, no Nix daemon.
    forwardPorts = [];
  };

  networking.hostName = "vm-agents";
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;
    networks."40-microvm" = {
      matchConfig.MACAddress = "02:00:00:00:00:0a";
      networkConfig = {
        Address = ["10.99.0.11/24"];
        Gateway = "10.99.0.1";
        DNS = ["100.100.100.100"]; # MagicDNS resolves over tailscale once up
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services.tailscale.enable = true;

  # coroot-node-agent, package build (modules/services/coroot.nix's packageAgent path is
  # host-only - its server half references fleet MODULES options this guest lacks). Pushes
  # to hp's Coroot server (tailscale IP spelled out; a guest sees no nixosConfigurations).
  # Loopback listener on 8141 = PORTS.corootNodeAgent, kept in sync by eye. The guest
  # kernel is stock nixpkgs, so CONFIG_DEBUG_INFO_BTF is on - the CO-RE probes need it.
  systemd.services.coroot-node-agent = {
    description = "Coroot node agent (package build, microVM guest)";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "tailscaled.service"];
    wants = ["network-online.target"];
    requires = ["tailscaled.service"];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      StateDirectory = "coroot-node-agent";
      ExecStart = ''
        ${pkgs.coroot-node-agent}/bin/coroot-node-agent \
          --listen=127.0.0.1:8141 \
          --collector-endpoint=http://100.92.36.52:8080 \
          --cgroupfs-root=/sys/fs/cgroup \
          --wal-dir=/var/lib/coroot-node-agent
      '';
    };
  };

  # microvm's kernel console is ttyS0; make it a login console too so the prototype is
  # reachable via `microvm console vm-agents` before tailscale is authenticated.
  systemd.services."getty@ttyS0" = {
    enable = true;
    wantedBy = ["getty.target"];
  };

  # Console access needs no network: microvm attaches ttyS0, and the root password is
  # empty with a getty (serial getty the microvm module enables); once tailscale is up
  # this sshd + the laptop key is the admin path.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCYoxGrmlgUcVfncMnlDONPk5RwSEqbiBpvT3c2m9MIDsYdYlLfnRN5YJPZgp8CHcPnPK2rboRiHAO00j545ci2CDeAp6zGKoOhX0q/3fES3ySqMG7lJ+cplxoXekSL9GNOQqSREDymqrMfqGy9OnupqcAZForX/k1aegi99TgZwbGMAK/UIzfdkQr49VVzYbaNR14rikIfjvi23s4bdP/KgeAs0T9KEKKSAd9WJQxUr/dmTjNBODzW10llgmCCVRNk3Pj4A1qiGiz0wkjG7XmZT0QjHyrX2GzSYuhW1l8s6mY3tTBBKVoj+peBphgxGBbEwUCQh0yPVBGstM5fHqN1bvOjRfYNQboVSmLhicX7Bk0WNLPS6DtqHZTXGNuYM8NcHn4xUIX5GwlsS6Mfo2tDMcX83w1Jv0BuImfcUMl6jvYCzcpEdGENYHWisIvQLSlAK6UEIYGeG8CH/iRqRPQIrOW49EQJYlW2VSLuTf8SA6c9Z2xdSIsli9JOfr79VUdYpgrdiv7vFjiX5d+hcJVC0rjQkF6XlAWVH5yMfpr1OXFbpKqILygx9Zcj7IhMHodQsjtr6+FjIs5Xm5Nt1nY9Cpke/q3lHcgq0PVgwvMPMhTOxfv6XoKQGmDTJWsmAP8n4BotZm7H2OlO29/zJnrgJ8+ZienkAX5s2cAaT16Kvw== akos@laptop"
  ];
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Tiny RAM target: no docs/locale, xz-compressed everything the module keeps.
  documentation.enable = false;
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "26.05";
}
