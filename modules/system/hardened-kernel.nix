# Grafix-hardened kernel for the ZFS hosts (2026-11-11 user request).
#
# Why this exists at all: nixpkgs 26.05 removed every `linuxPackages*_hardened`
# attribute ("linux_hardened has been removed due to lack of maintenance",
# pkgs/top-level/linux-kernels.nix @ 6f06d204d8f2, removed 2026-03-18), so the
# old `boot.kernelPackages = pkgs.linuxPackages_hardened` route is gone. The
# upstream grafix patchset (anthraxx/linux-hardened) still ships the exact
# release for our pin, so we rebuild the explicitly pinned kernel with it using the
# same mechanism the old `hardenedKernelFor` used: override the vanilla kernel
# derivation with the hardened structuredExtraConfig + the grafix patch, and
# hand the result to `pkgs.linuxPackagesFor`.
#
# Boot semantics (deliberate): a deploy switch activates the new
# configuration but does NOT reboot - deploy-rs/`make switch` only swaps the
# generation, and the hardened kernel takes effect on the NEXT boot. The old
# systemd-boot generation stays selectable, so a failed hardened boot is
# recoverable from the bootloader menu without touching ZFS pools.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.MODULES.system.hardenedKernel;

  # The grafix release must match the explicitly pinned kernel exactly: the build
  # reuses the VANILLA kernel.org tarball and applies the patch on top (same
  # split the old nixpkgs mechanism used). The source and patch hashes below
  # move together; a nixpkgs update changes the toolchain, not this source pin.
  # Verified 2026-11-12 via api.github.com (release v6.18.60-hardened1,
  # published 2026-11-04) and `nix-prefetch-url` (sha256 of the raw patch).
  kernelVersion = "6.18.60";
  patchsetVersion = "${kernelVersion}-hardened1";
  # 2026-11-12 owner decision: update all flake inputs, but retain the newest
  # available hardened 6.18 release when the channel advances ahead of it.
  # Pin the source AND patch together; never apply an older patch to a new tree.
  kernelSource = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernelVersion}.tar.xz";
    hash = "sha256-PC9E72rMAhp61ETZoubsHvSI/wk2h5PQAEpggPadYh4=";
  };

  grafixPatch = pkgs.fetchurl {
    url = "https://github.com/anthraxx/linux-hardened/releases/download/v${patchsetVersion}/linux-hardened-v${patchsetVersion}.patch";
    hash = "sha256-NbXK15OoJZeDVCtZeayrp3ZBsicjU58TBUk0gc0R5Wc=";
  };

  # 2026-11-14 (owner: io_uring "makes some processes a lot faster" - turn it
  # back on; see MODULES.system.hardenedKernel.ioUring). Grafix disables
  # io_uring at BUILD time in exactly one hunk of io_uring/io_uring.c
  # (linux-hardened-v6.18.60-hardened1.patch, patch lines 1058-1080): it seeds
  # `sysctl_io_uring_disabled = 1` and narrows the sysctl's
  # proc_dointvec_minmax range from [SYSCTL_ZERO..SYSCTL_TWO] to
  # [SYSCTL_TWO..SYSCTL_TWO] ("only handle a transition from default 1 to 2").
  # There is NO boot escape, verified against the actual trees 2026-11-14:
  # upstream 6.18 has no `io_uring_disabled=` kernel parameter (no
  # __setup/early_param in io_uring.c, no entry in
  # Documentation/admin-guide/kernel-parameters.txt - checked in the v6.18.60
  # source), and the generic `sysctl.io_uring_disabled=` cmdline hook
  # (do_sysctl_args in init/main.c, which runs AFTER the io_uring sysctl table
  # is registered) writes through the SAME proc_handler the patch clamped to
  # 2..2, so a 0 write dies at EINVAL - measured live on hp + akos01
  # (sysctl -w kernel.io_uring_disabled=0 -> EINVAL; value stuck at 1). The
  # only correct opt-in is therefore build-time: this revert undoes exactly
  # that one hunk and rides in kernelPatches AFTER the grafix patch,
  # restoring vanilla semantics (default 0 = enabled, runtime sysctl tunable
  # 0/1/2 again). Grafix's rationale for the latch is exploit-mitigation
  # depth (io_uring is a chronic LPE playground); the 2026-11-14 owner
  # decision accepts that trade for fleet performance - everything else in
  # the hardened patchset stays untouched.
  #
  # The hunks below were machine-derived, NOT hand-written: `patch -p1 -F0` of
  # the grafix io_uring hunk onto pristine v6.18.60 io_uring.c, then
  # `diff -u patched pristine`; roundtrip verified byte-identical
  # (grafx-patched + this revert == pristine v6.18.60 file). A grafix version
  # bump WILL drift this context: if the kernel build then fails on
  # io_uring/io_uring.c ("Reversed (or previously applied) patch detected" or
  # a hunk reject), re-derive this file from the new release's io_uring hunk
  # with that same two-command recipe. It fails loudly at build time, never
  # silently.
  ioUringRevertPatch = pkgs.writeText "io_uring-revert-grafix.patch" ''
    --- a/io_uring/io_uring.c
    +++ b/io_uring/io_uring.c
    @@ -144,7 +144,7 @@
     struct kmem_cache *req_cachep;
     static struct workqueue_struct *iou_wq __ro_after_init;

    -static int __read_mostly sysctl_io_uring_disabled = 1;
    +static int __read_mostly sysctl_io_uring_disabled;
     static int __read_mostly sysctl_io_uring_group = -1;

     #ifdef CONFIG_SYSCTL
    @@ -154,9 +154,8 @@
     		.data		= &sysctl_io_uring_disabled,
     		.maxlen		= sizeof(sysctl_io_uring_disabled),
     		.mode		= 0644,
    -		/* only handle a transition from default "1" to "2" */
     		.proc_handler	= proc_dointvec_minmax,
    -		.extra1		= SYSCTL_TWO,
    +		.extra1		= SYSCTL_ZERO,
     		.extra2		= SYSCTL_TWO,
     	},
     	{
  '';

  # Reuse the current nixpkgs kernel recipe and standard helper patches, with
  # the explicitly paired source/version supplied through argsOverride below.
  baseKernel = pkgs.linuxPackages.kernel;

  k = lib.kernel;

  hardenedKernel = baseKernel.override {
    # mainline.nix merges `argsOverride` AFTER its own defaults
    # (`// (args.argsOverride or { })`), so pname/modDirVersion must ride in
    # here; a top-level modDirVersion would be clobbered by its
    # `modDirVersion = pad 3 version` line. This is exactly the
    # hardenedKernelFor trick from release-25.11 (which appended the patchset's
    # `extra` = "-hardened1" to modDirVersion): the grafix patch bumps the
    # Makefile's EXTRAVERSION to "-hardened1" (verified in the downloaded
    # patch, Makefile hunk `-EXTRAVERSION =` / `+EXTRAVERSION = -hardened1`;
    # the patch touches no other localversion file), so the built
    # include/config/kernel.release is "6.18.60-hardened1" and the module dir
    # MUST be named that - wrong modDirVersion = ZFS modules fail to load at
    # boot = unbootable ZFS root. build.nix double-checks this at build time
    # (it aborts if kernel.release != modDirVersion), so a mismatch here fails
    # loudly, not silently.
    argsOverride = {
      pname = "linux-hardened";
      version = kernelVersion;
      src = kernelSource;
      modDirVersion = patchsetVersion;
    };

    # Vendored nixpkgs hardened defconfig (contributed by
    # modules/system/hardened-config.nix into
    # config.MODULES.system.hardenedKernel.hardenedConfig) merged with the
    # fleet's observability/Docker floor. The hardened config deliberately
    # kills things the fleet's stack depends on (INET_DIAG=n, PROC_KCORE=n,
    # the perf/kprobe-adjacent posture), and nixpkgs' own common-config.nix
    # already carries most of the list; re-stating the mandatory ones AFTER
    # the import (plain `//` beats the mkIf'd attrs) makes the fleet contract
    # explicit and survives any future drift in either file. Each override:
    #
    #   coroot-node-agent (measured fleet-wide 2026-11-11 - it is an eBPF
    #   agent; kprobes/uprobes/bpf syscalls are its ONLY data path, and it
    #   runs as root so the unprivileged-bpf posture is irrelevant):
    #   - KPROBES, UPROBE_EVENTS: probe attachment points
    #   - BPF_SYSCALL, BPF_EVENTS: the bpf() syscall + perf-event-driven BPF
    #   - FTRACE, FUNCTION_TRACER: the ftrace machinery probes ride on
    #   - KALLSYMS, KALLSYMS_ALL: symbolization (KALLSYMS is also force-
    #     selected by KPROBES, stated for documentation)
    #   - PERF_EVENTS: bpf perf links + the profiling stack
    #   docker / OCI networking:
    #   - CGROUP_BPF: cgroupv2 eBPF device/net filters (dockerd default path;
    #     common-config only marks it `option yes`, so harden it here)
    #   - NET_SCHED: TC, which runc's and docker's eBPF/htb setups need
    #   tailscale:
    #   - BPF_LSM: kept optional exactly as common-config has it (it needs
    #     BPF_JIT, present on x86_64); tailscale's eBPF forwarding mode and
    #     future LSM hooks stay openable without a kernel rebuild.
    # Unprivileged bpf is NOT re-enabled: the vendored config is silent on it
    # and nixpkgs common-config only forces BPF_UNPRIV_DEFAULT_OFF for <5.16,
    # so we inherit 6.18's default (unprivileged bpf off) - coroot is root.
    structuredExtraConfig =
      cfg.hardenedConfig
      // {
        KPROBES = k.yes;
        BPF_SYSCALL = k.yes;
        BPF_EVENTS = k.yes;
        FTRACE = k.yes;
        FUNCTION_TRACER = k.yes;
        UPROBE_EVENTS = k.yes;
        KALLSYMS = k.yes;
        KALLSYMS_ALL = k.yes;
        PERF_EVENTS = k.yes;
        NET_SCHED = k.yes;
        CGROUP_BPF = k.yes;
        BPF_LSM = k.option k.yes;
      };

    # Order is load-bearing: the kernel build applies kernelPatches in list
    # order, so the io_uring revert (ioUringRevertPatch's comment) must ride
    # AFTER the grafix patch it undoes - never before.
    kernelPatches =
      baseKernel.kernelPatches
      ++ [
        {
          name = "linux-hardened-v${patchsetVersion}";
          patch = grafixPatch;
        }
      ]
      ++ lib.optionals cfg.ioUring [
        {
          name = "un-disable-io_uring-revert-grafix-latch";
          patch = ioUringRevertPatch;
        }
      ];

    # isHardened is deliberately NOT passed: the 26.05 generic.nix dropped the
    # argument entirely (it only survived as a passthru tag in 25.11).
  };
in {
  options.MODULES.system.hardenedKernel.version = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = kernelVersion;
    description = "Kernel source version paired with the audited hardened patch and hashes.";
  };

  options.MODULES.system.hardenedKernel.enable = lib.mkEnableOption ''
    the grafix linux-hardened kernel (linux-hardened patchset + the vendored
    nixpkgs hardened config, rebuilt against a paired source/patch pin because
    nixpkgs 26.05 removed linuxPackages_hardened). Switching this on installs
    the new kernel into a new boot generation but does NOT reboot and does NOT
    touch the running kernel - it takes effect on the next boot, and the old
    generation stays selectable in systemd-boot
  '';

  options.MODULES.system.hardenedKernel.ioUring = lib.mkOption {
    type = lib.types.bool;
    default = true;
    example = false;
    description = ''
      Revert the grafix io_uring latch at build time, restoring vanilla
      semantics (kernel.io_uring_disabled defaults to 0 = enabled, and stays
      a normal 0/1/2 runtime sysctl). Default ON per the 2026-11-14 owner
      decision: io_uring "makes some processes a lot faster" and the fleet
      wants it (firecracker Async drive engine, SQLite io_uring backend,
      etc.); grafix's latch is exploit-mitigation depth we accept trading
      away. Set false to preserve the stock hardened posture (latched off,
      sysctl only flips 1->2). The revert rides kernelPatches AFTER the
      grafix patch; there is NO boot-time equivalent - 6.18 has no
      io_uring_disabled kernel parameter and the generic sysctl.on-cmdline
      hook writes through the very proc_handler grafix clamps to 2..2 (EINVAL
      on 0, measured hp + akos01 2026-11-14). Changing this value rebuilds
      the kernel; like the kernel itself it activates on the NEXT boot.
    '';
  };

  options.MODULES.system.hardenedKernel.hardenedConfig = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = {};
    example = lib.literalExpression "lib.kernel.yes";
    description = ''
      structuredExtraConfig items of the hardened defconfig, contributed
      (enabled-on) by modules/system/hardened-config.nix - the vendored
      nixpkgs release-25.11 hardened config.nix adapted for 6.18 symbol
      names. hardened-kernel.nix merges it with the fleet eBPF/docker floor
      and feeds it to the kernel derivation. Keys are bare Kconfig names
      (no CONFIG_ prefix).
    '';
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasSuffix "-hardened1" hardenedKernel.modDirVersion;
        message = ''
          MODULES.system.hardenedKernel: modDirVersion came out
          ${hardenedKernel.modDirVersion}; the grafix Makefile bump appends
          "-hardened1" and the ZFS modules depend on that exact name.
        '';
      }
    ];

    boot.kernelPackages = pkgs.linuxPackagesFor hardenedKernel;

    # Both ZFS hosts keep boot.zfs.package = pkgs.zfs: the zfs NixOS module
    # derives the kernel module from boot.kernelPackages.kernelModuleAttribute,
    # so the hardened kernel automatically gets the zfs kmod built against it.
  };
}
