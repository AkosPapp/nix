# PLAN.md §6 host side: run firecracker microVMs declared elsewhere in the flake.
#
# The guests arrive as fully-evaluated nixosConfigurations through specialArgs
# (`microvmConfigurations`), the microvm.nix host module turns each into a
# microvm.service unit (socket-activated runner under /run/microvm, state under
# /var/lib/microvm), and this module owns the ONE shared L2 bridge `mvbr0` with NAT
# out - deliberately isolated from the LAN bridge: VMs reach the world through
# masquerade, reach humans through their own tailscale identity, and nothing on the
# physical network can knock on a VM port it didn't earn. The bridge address is
# unnumbered-here-elsewhere: 10.99.0.1 is the guests' gateway and nothing else, so
# SERVICE_GRAPH (modules/security/service-graph.nix) never sees east-west VM chatter
# on tailscale0 except what the guest's tailscale itself originates - which is exactly
# the containment property the §6 tier was asked for.
#
# Flip list when a jail moves to backend="microvm" (jail.nix refuses the flip until a
# row of the same name exists in MODULES.system.microvmHost.vms):
#   1. define hosts/vms/<name>.nix (copy vm-agents.nix; the service config moves in,
#      read-only root means its state needs a sharedDir + the §4.3 dataset carve),
#   2. add the flake microvmConfigurations entry,
#   3. MODULES.system.microvmHost.vms += [ "<name>" ],
#   4. jails.<name>.backend = "microvm" + disable the host-side service,
#   5. SERVICE_GRAPH allow rows for how the VM must be reached (its tailnet IP).
{
  config,
  lib,
  pkgs,
  inputs,
  microvmConfigurations ? {},
  ...
}: let
  inherit (lib) mkOption mkIf types;

  cfg = config.MODULES.system.microvmHost;

  guestSubnet = "10.99.0.0/24";
  bridge = "mvbr0";
  gateway = "10.99.0.1";
in {
  # The host module is imported unconditionally: `imports` cannot live inside an mkIf'd
  # config, and the module self-gates on microvm.host.enable (which we set only when
  # MODULES.system.microvmHost.enable does).
  imports = [inputs.microvm.nixosModules.host];

  options.MODULES.system.microvmHost = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };

    vms = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Names from the flake's microvmConfigurations to run on this host.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      map (n: {
        assertion = microvmConfigurations ? ${n};
        message = "MODULES.system.microvmHost.vms: '${n}' is not defined in the flake's microvmConfigurations.";
      })
      cfg.vms;

    # Firecracker needs /dev/kvm. Load only the module matching the host CPU where the
    # generated hardware config tells us the vendor (a listed-but-missing module fails
    # systemd-modules-load.service); probe both when the vendor is unknown - one loads,
    # one logs, same tolerance as before.
    boot.kernelModules = let
      intel = config.hardware.cpu.intel.updateMicrocode or false;
      amd = config.hardware.cpu.amd.updateMicrocode or false;
    in (lib.optionals intel ["kvm-intel"]
      ++ lib.optionals amd ["kvm-amd"]
      ++ lib.optionals (!intel && !amd) ["kvm-intel" "kvm-amd"]);

    nixpkgs.overlays = [inputs.microvm.overlays.default];

    microvm = {
      # /var/lib/microvm - per-VM console sockets, taps, disks (state dirs)
      stateDir = "/var/lib/microvm";
      host = {
        enable = true;
        # microvm.nix starts the runners; restartIfChanged keeps them in step with
        # system activations without orphaning stale VMs.
        startupTimeout = 300;
      };
      vms = builtins.listToAttrs (
        map (n: {
          name = n;
          value = {
            # `config` would re-evaluate the guest inside the host eval (it takes a
            # module list); evaluatedConfig accepts the finished nixosConfiguration.
            evaluatedConfig = microvmConfigurations.${n};
            autostart = true;
            restartIfChanged = true;
          };
        })
        cfg.vms
      );
    };

    # The bridge below is systemd-networkd configuration. Hosts that use useNetworkd as
    # their backend get it for free; NetworkManager hosts (hp) must opt in explicitly -
    # the systemd.network module only renders units and starts networkd when
    # systemd.network.enable is set (it defaults to the networking backend being
    # networkd). Both coexist: NM keeps the physical NICs and tailscale0, networkd only
    # ever sees what it is configured for, and the unmanaged-devices keys below stop NM
    # from racing over the bridge and the guests' taps.
    systemd.network.enable = true;
    networking.networkmanager.unmanaged =
      lib.optionals
      config.networking.networkmanager.enable
      [
        "interface-name:${bridge}"
        "interface-name:mv-*" # firecracker taps, enslaved by name pattern
      ];

    # hp-style hosts keep legacy dhcpcd for their WAN interface, and dhcpcd probes every
    # interface NOT on its deny list - a bridge whose ports are attacker-influenced guest
    # taps is exactly where a hostile VM could hand the HOST a lease (DNS, routes) via
    # mvbr0 or its own mv-* port (2026-10-25 review #4). Denied unconditionally: a no-op
    # wherever dhcpcd is off, mandatory wherever useDHCP coexists with this bridge.
    networking.dhcpcd.denyInterfaces = [bridge "mv-*"];

    # The shared guest bridge: created even with zero VMs so taps attach instantly.
    systemd.network.netdevs."40-${bridge}" = {
      netdevConfig = {
        Name = bridge;
        Kind = "bridge";
      };
    };
    systemd.network.networks."40-${bridge}" = {
      matchConfig.Name = bridge;
      networkConfig.Address = ["${gateway}/24"];
    };
    # Firecracker hands us plain taps (microvm.nix creates them pre-start); enslaving by
    # name pattern means a new VM's tap joins with zero host edits.
    systemd.network.networks."40-${bridge}-members" = {
      matchConfig.Name = "mv-*";
      networkConfig.Bridge = bridge;
    };
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # NAT + forwarding for the guest subnet; mirrored stop commands keep activation
    # idempotent (the firewall flushes INPUT/FORWARD chains before extraCommands run).
    # FORWARD only gates VM->OUTSIDE transit (guests ride MASQUERADE; return traffic
    # is conntrack). VM->host traffic never traverses FORWARD - it hits INPUT - so
    # the host's own ssh/tailscale surface is gated by the regular INPUT policy and
    # the jails' chains, not by anything here.
    networking.firewall = {
      extraCommands = ''
        iptables -w -t nat -A POSTROUTING -s ${guestSubnet} ! -o ${bridge} -j MASQUERADE
        iptables -w -A FORWARD -i ${bridge} -j ACCEPT
        iptables -w -A FORWARD -o ${bridge} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      '';
      extraStopCommands = ''
        iptables -w -t nat -D POSTROUTING -s ${guestSubnet} ! -o ${bridge} -j MASQUERADE 2>/dev/null || true
        iptables -w -D FORWARD -i ${bridge} -j ACCEPT 2>/dev/null || true
        iptables -w -D FORWARD -o ${bridge} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
      '';
    };
  };
}
