{
  config,
  pkgs,
  lib,
  system,
  nixos-version,
  configName,
  my-nixvim,
  ...
}: {
  options = {
    PROFILES.global.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable global profile";
    };
  };

  #imports = [nixpkgs.nixosModules.readOnlyPkgs];
  config = lib.mkIf config.PROFILES.global.enable {
    MODULES = {
      networking.sshd.enable = true;
      networking.tailscale.enable = true;
      system.locale.enable = true;
      nix.gc.enable = true;
      nix.substituters.cachix.enable = true;
      nix.substituters.cuda.enable = true;
    };

    networking.hostName = configName;

    nix.settings.experimental-features = ["nix-command" "flakes"];
    # Force the nix client to always talk to nix-daemon. Without this,
    # copying dirty/uncommitted local flake inputs into the store bypasses
    # the daemon and writes directly as the calling user, which fails under
    # the default read-only /nix/store bind mount.
    environment.sessionVariables.NIX_REMOTE = "daemon";
    nixpkgs.config.allowUnfree = true;
    nixpkgs.hostPlatform.system = system;
    system.stateVersion = nixos-version;

    users.mutableUsers = false;

    # Client only (the laptop dials out; nothing here should be a mosh server).
    # The nixpkgs default openFirewall=true was accepting UDP 60000-61000 on
    # EVERY interface of every host - measured 2026-11-12: it's the only author
    # of that hole on hp and akos01 (live `-A nixos-fw -p udp --dport
    # 60000:61000`), while mosh-server itself is enabled nowhere. Close it on
    # LAN/WAN and keep it open on the tailnet only, for mosh's own UDP range
    # - the service-graph's udpElements pick the interface ranges up
    # (its nft tailnet chain then accepts the range on tailscale0/wt0). The
    # retired phone-pairing app that also rode this range is gone (2026-11-14,
    # audit #9); the tailscale0-only opening stays for real mosh.
    programs.mosh.openFirewall = false;
    networking.firewall.interfaces.tailscale0.allowedUDPPortRanges = [
      {
        from = 60000;
        to = 61000;
      }
    ];

    # No global nixpkgs.config.allowBroken (was here; 2026-10-24 audit #7): a broken package
    # is one whose build is known to fail, and silently shipping it pins the host to a
    # failure forever. Scoped imports that need it (flake.nix's pkgs-unstable, immich.nix's
    # CUDA instance) keep their own.

    environment.systemPackages = with pkgs; [
      kitty
      my-nixvim.packages.${pkgs.stdenv.hostPlatform.system}.default
      gnumake
      rsync
      (pkgs.writeShellScriptBin "nix-switch-to-generation" ''
        set -euo pipefail

        PROFILE=/nix/var/nix/profiles/system

        # List generations and format them nicely for fzf
        selected=$(${pkgs.nix}/bin/nix-env --list-generations --profile "$PROFILE" \
          | ${pkgs.fzf}/bin/fzf \
              --header="Select a NixOS generation to switch to" \
              --tac \
              --no-sort \
              --reverse)

        if [ -z "$selected" ]; then
          echo "No generation selected, aborting."
          exit 1
        fi

        # Extract the generation number (first whitespace-separated field)
        gen_number=$(echo "$selected" | awk '{print $1}')

        gen_link="$PROFILE-$gen_number-link"

        if [ ! -e "$gen_link" ]; then
          echo "Error: could not find $gen_link"
          exit 1
        fi

        echo "Switching to generation $gen_number..."
        exec sudo "$gen_link/bin/switch-to-configuration" switch
      '')
    ];
    networking = {
      extraHosts = ''
        127.0.0.1 localhost
      '';
    };

    powerManagement.cpuFreqGovernor = "performance";

    # Ensure QEMU is available for emulation
    boot.binfmt.emulatedSystems = [
      "aarch64-linux"
    ];

    users.users.root.openssh.authorizedKeys.keys = [
      # Single owner: users/akos-laptop.pub. Also trusted for hp's hermes + datalab agent
      # terminals (hosts/hp/default.nix) and for akos@legion5 - there via a hand-maintained
      # line in ~/.ssh/authorized_keys whose comment field reads "akos@nixos" (same RSA
      # blob, SHA256:bS9Kfe1zXSvIOEFV5riiRS1yXPJJfR0SA4qNT9JrZYk). Verified byte-for-byte
      # 2026-11-14 closing audit #14; matching by comment is the trap that made the old
      # claim read as false - the "akos@laptop" ED25519 line next to it is a DIFFERENT key,
      # and users/akos.nix ships hub+mobile only, so the legion5 trust is out-of-band, not
      # a deploy artifact.
      (lib.removeSuffix "\n" (builtins.readFile ../users/akos-laptop.pub))
      # The herdr HUB key (private half: sops herdr/hub_ssh_key, mounted only on hp by
      # MODULES.services.herdr.sshKeySecret - modules/services/herdr.nix). hp's TUI machine
      # catalog dials every fleet box as root over the `Host herdr-*` aliases, and measured
      # 2026-11-09 hp's root had NO usable own key for that (/root/.ssh/id_ed25519 is a
      # symlink to the nix-builder private key, whose public half is trusted only on the
      # AIRLAB builders) and the hub path runs without agent forwarding on purpose.
      # Hub-only by construction: IdentitiesOnly pins it to herdr-* aliases and nothing
      # else references it. It yields a root shell on every fleet box - accepted as the
      # hub-operator tradeoff (owner decision 2026-11-09: single-holder key, tailnet-only
      # reach, no agents run under root here).
      # Single owner: users/herdr-hub.pub (the same line users/akos.nix and the
      # hermes sshAccess trust read).
      (lib.removeSuffix "\n" (builtins.readFile ../users/herdr-hub.pub))
    ];
  };
}
