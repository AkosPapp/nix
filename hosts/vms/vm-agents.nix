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
    # Sync (pread/pwrite), NOT the runner's io_uring-based "Async" default -
    # kept deliberately even though the blocker is gone. Original incident
    # (measured on hp's first hardened boot, gen 437, 2026-11-13): the grafix
    # host kernel latched io_uring off (io_uring_disabled=1, sysctl only
    # flips 1->2), so Async died at io_uring_setup(EPERM) and
    # microvm@vm-agents flapped 156x. 2026-11-14: the host kernel now reverts
    # that latch at build time (MODULES.system.hardenedKernel.ioUring,
    # default on), so Async is technically available again from the NEXT
    # hardened boot - but this unit keeps Sync: the owner's rule is no churn
    # on a working VM, and Sync has no measured deficit at this guest's load.
    # Flip to "Async" only with a measured reason (and only after the
    # ioUring-revert kernel is actually booted on hp). Note the whole story is
    # HOST-side: this is firecracker's drive-backend engine. The GUEST kernel
    # is stock nixpkgs (flake.nix's microvmConfigurations imports only this
    # file - the hardened-kernel module never enters a guest), so the guest's
    # own io_uring was never disabled by any of this.
    firecracker.driveIoEngine = "Sync";
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

  # coroot-node-agent, package build. The fleet module's agent is the nixpkgs-unstable package
  # (paired with the 1.27.x server), but guests never receive pkgs-unstable (flake.nix nulls it),
  # so this inline unit uses the 26.05 package (1.32.0); the server accepts older agents and
  # marks the node's version in the UI. Bump by checking it against the server on akos01.
  # Pushes to akos01's Coroot server (tailscale IP spelled out; a guest sees no
  # nixosConfigurations; 2026-10-26: was hp, whose server half was disabled and aggregation
  # moved to akos01). The --listen value is moot: with a collector endpoint set, the agent
  # (>=1.32, flags.go) forces its metrics listener to 127.0.0.1:10300 = PORTS.corootNodeAgent
  # - which nothing on a guest scrapes anyway (data flows by push).
  # The guest kernel is stock nixpkgs, so CONFIG_DEBUG_INFO_BTF is on - the CO-RE probes need it.
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
          --collector-endpoint=http://100.83.255.5:8080 \
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
  # this sshd + the laptop key is the admin path. Builtins.readFile is fine even though
  # microVM guests deliberately see `nixosConfigurations = {}` - this reads repo files,
  # not cross-host facts, so there is no specialArgs dependency to break (and per Rule 2
  # the key material lives in one place: users/*.pub). The phone's public key rides along
  # so `ssh vm-agents` works from the tailnet with the same key the fleet roots trust.
  users.users.root.openssh.authorizedKeys.keys = [
    (lib.removeSuffix "\n" (builtins.readFile ../../users/akos-laptop.pub))
    (lib.removeSuffix "\n" (builtins.readFile ../../users/herdr-mobile.pub))
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
