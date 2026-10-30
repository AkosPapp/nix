# gpu-unlock (https://github.com/Zagitta/gpu-unlock) as packaged by the still-open PR #186:
# a kernel module that lifts NVIDIA's GeForce half-rate cap on FP16/BF16/TF32 tensor math
# (FP32 accumulation) by writing the speed selectors in the card's firmware *before* the
# nvidia driver binds - so it must run from the initrd, which the upstream flake module
# wires (mkBefore in the module list / a sysinit unit ahead of udev coldplug).
#
# This file only adds the fleet's opinion on top of upstream's `hardware.nvidia.gpuUnlock`:
# the MODULES.* flip, the unfree-firmware allowance, and the laptop power-management
# footgun. Hosts declare the PCI target (a hardware fact, Rule 1) and nothing else.
#
# Bench note (measuring this, not a generic GPU benchmark): harness in ~/gpu-bench on the
# unlocked host (bench.py + run.sh, torch env pinned by store path and GC-rooted at
# /nix/var/nix/gcroots/gpu-bench-torch so a reboot cannot delete half of an A/B pair).
# Method v1 mirrored the 3090 write-up at toy scale: 30s heat soak, then 10 timed 8192^3
# GEMMs per cell, FP32 as the control. Method v2 (2026-10-29) runs ~10 min: 300s soak to the
# THROTTLING PLATEAU, then a time-budgeted round-robin of the four cells so every cell sees
# the same thermal trace; the per-cell median power/temp now travels in the JSON. Protocol
# both halves must share: performance mode, charger in, only zed+niri open (the v1 morning
# numbers predate the protocol and are a different family - the saturated locked ratio is
# lower than the burst one: measured 3.2-3.9 v2/short vs 4.0 v1).
#
# Measured on legion5 (torch 2.11.0, driver 595.71.05, kernel 6.18.57, desktop session live in
# all three runs so they are comparable; the v1 raw cells were deleted 2026-10-29 when the
# method changed - this table is their surviving record):
#
#   cell            stock 10-28 23:23  stock 10-29 08:03  UNLOCKED 10-29 08:2x   gain
#   bf16                     23.4                24.0                    35.6   +48.2%
#   fp16                     23.1                23.7                    35.1   +47.9%
#   tf32                     10.7                10.9                    16.5   +51.1%
#   fp32 (control)            5.9                 6.0                     5.9    -1.8%
#
# Two stock sessions on purpose: the card drifts 2.3-2.9% boot-to-boot, so anything under ~3%
# is not a gain and the unlocked side is graded against the FASTER stock session. The control
# cell is what makes the rest credible - it did not move while all three tensor cells did.
#
# The v2 saturated pair (protocol pinned: performance mode, charger, zed+niri only; 300s soak,
# 280s round-robin, per-cell median power/temp in the JSONs) supersedes the burst numbers as
# the operating point, same generation on both sides (grub OFF specialisation vs default):
#
#   cell            stock 12:08   UNLOCKED 11:53   gain
#   bf16                   19.6             35.3   +80.1%
#   fp16                   22.5             35.3   +56.9%
#   tf32                   11.4             16.4   +43.9%
#   fp32 (control)          6.0              5.8    -3.3%
#
# The gain GROWS under saturation, and the sample traces say why: median board power identical
# (54.9 W both), median clock 1875 -> 1545 MHz - the unlocked cells are cap-insensitive (burst
# 35.6 -> saturated 35.3) while the locked ones collapse (24.0 -> 19.6), because at half tensor
# rate the sustained 55 W buys ever less clock. The control's -3.3% is the clock the tensor win
# is paid in, missing on non-tensor paths. bf16-vs-fp16 (19.6 vs 22.5 stock, 35.3 vs 35.3
# unlocked): the locked card's bf16 cell degrades under sustained load more than its fp16 one.
#
# The 0.5 Hz power/clock samples say where the win comes from and what caps it: board power was
# the same in both states (median 54.9 W, max 55.1 vs 55.2 - this Max-Q part is power-capped),
# and the unlocked run earned its throughput by clocking DOWN, 1995 -> 1575 MHz median at
# 63 -> 71 C. Same watts, ~1.5x the work per second, i.e. energy per TFLOP of work fell
# 2.29 -> 1.54 J (-33%). Wattage is therefore the ceiling in BOTH states - and since nvidia-smi
# reports this part's power limit as N/A (a laptop: not raisable), the one lever left is the
# undervolt the 3090 write-up pairs with the unlock. At a fixed cap, lowering the voltage each
# clock needs buys the clock back, which is exactly what the unlocked run is now spending its
# 55 W on. (Do it after soak-testing an offset of your own; a bad offset gives wrong results
# without crashing.)
#
# First boot attempt did nothing at all, and the log said so quietly: `gpu_unlock: no
# supported card at "0000:01:00.0"` (legion5, 2026-10-29 morning). The PR branch head we had
# locked was upstream 1.1.0, whose recipe table is GA10x + AD102; AD107 (this RTX 4060 Laptop,
# 10de:28e0) arrived in the 2.0.0 rebase. Two lessons kept here because both bit once:
# (1) check the pinned input's recipes.c for the card's id, and (2) this module's failure mode
# is a silent no-op, not an error - the driver binds happily afterwards, so nvidia-smi looks
# normal and only the kernel log distinguishes the two states (see ~/gpu-bench/check-unlock.sh).
#
# Lock-state detection, measured wrong once (legion5, 2026-10-29 afternoon): `clocks.max.sm`
# reads 3105 MHz whether the card is unlocked or re-locked by a suspend, and the instantaneous
# clock can even look BETTER locked (the pm-locked run peaked at 2100 MHz vs 1620 for the
# unlocked one, because the unlock's win is tensor work per watt, and the 55 W cap spends the
# difference on clock when the selectors are stock). Trust, in order: check-unlock.sh's
# ordered kernel log (authoritative), then the bf16/fp32 cell RATIO - but ratio references are
# METHOD-specific (v1 short bursts: ~4.0 locked / ~6.0 unlocked; v2 saturated: 3.27 / 6.12,
# measured 2026-10-29 boot2 pair), so grade a v2 run against the v2 pair, never against the v1
# numbers. Raw cell TFLOPS are comparable only within one method AND one session protocol
# (see run.sh header).
{
  config,
  lib,
  inputs,
  ...
}: let
  cfg = config.MODULES.hardware.nvidia.gpuUnlock;
  types = lib.types;
in {
  imports = [inputs.gpu-unlock.nixosModules.default];

  options.MODULES.hardware.nvidia.gpuUnlock = {
    enable = lib.mkEnableOption ''
      gpu-unlock on this host's NVIDIA card (see modules/hardware/nvidia-gpu-unlock.nix)
    '';

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["0000:01:00.0"];
      description = ''
        PCI addresses to unlock, from `lspci -D -d 10de:` (or the single "all"). Deliberately
        explicit - a card the unlock sequence fails on is unusable until a FULL power-off
        (a warm reboot does not reset it), so which slot gets handed to the module is a
        per-host hardware decision, not a fleet default.
      '';
    };

    resume = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Re-apply the unlock after suspend, matching the module's OWN default (upstream
        `static bool resume = true`). The NixOS module agreed with that at our rev - it omits
        the parameter when resume is on so the module default applies - but it did NOT at the
        1.1.0-era rev (defaulted false, i.e. a NixOS box silently behaved differently from every
        other packaging). Off is not a safe default on a laptop: legion5 measured 2026-10-29 that
        a single lid close (s2idle) reset the tensor selectors, the bf16/fp32 ratio falling
        6.0 -> 4.07 with no error anywhere. `keepAwake` cannot prevent that: it pins RUNTIME power
        management, while system suspend is the platform's own PCIe/D3cold path. Enabling this
        also turns on nvidia's kernel suspend notifiers below, which is what upstream's ordering
        guarantee ("its suspend notifier runs just ahead of the one nvidia resumes its cards
        from") rests on - and with the notifier parameter set, it MEASURES true the same day on
        legion5 (resume=true boot 2026-10-29): journal shows stage=resume-entry reading the stock
        selectors back (the card does re-lock over s2idle), a full 4-pass re-unlock, and
        "unlocked again after resume" before PM: suspend exit, probe bf16 35.2 TF afterwards.
        Set false only on a host that genuinely never suspends.
      '';
    };

    stockEntry = lib.mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add a labelled boot entry that is this exact system with the unlock switched off. Why a
        specialisation rather than "just boot an older generation": a failed or unwanted unlock
        clears only on a FULL power-off, so the way back has to be pre-built while the machine is
        booting normally, and it has to be legible in the firmware menu at 2am.

        It is a real stock boot, not a cosmetic label, for two verified reasons. Forcing the flag
        false drops this module's ENTIRE config block (it is `config = lib.mkIf cfg.enable`), so
        nothing the unlock adds survives: no kernel param, no modprobe line, no initrd module.
        And install-grub.pl's addEntry() reads kernel, initrd and kernel-params off the
        specialisation's OWN toplevel, so GRUB boots that stripped-down pair. Verified on
        legion5 2026-10-29: parent initrd 2100 members, stock initrd 2077, the difference being
        gpu_unlock.ko.xz, lib/firmware/gpu-unlock/** and the gpu-unlock unit; parent
        kernel-params carries gpu_unlock.targets, the child's carries none. Costs one extra
        initrd and one extra zImage under /boot/kernels.

        To use it: `sudo grub-reboot "NixOS Generation <n> ... - gpu-unlock OFF (stock tensor
        rate)"` (the label below is a suffix on the generation's own name) and then a FULL power
        -off, not a reboot - a warm reboot keeps whatever the card already decided.
      '';
    };

    postBootBench = lib.mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/home/akos/gpu-bench/postboot-bench.sh";
      description = ''
        A root-run script executed once, at the first boot after this module is installed, to
        measure the unlock (an agent that arranges a reboot cannot survive it, so the
        measurement has to be boot-owned). A `boot`-only install is what makes this usable:
        the unit exists in the new generation and runs there, not at switch time. Guarded by
        `benchOnceMarker` so a forgotten flip cannot re-heat the GPU on every boot; the script
        is expected to touch that marker. Temporary by nature - drop the option once the
        numbers are in.
      '';
    };

    benchOnceMarker = lib.mkOption {
      type = types.path;
      default = "/var/lib/gpu-unlock/bench.done";
      description = ''
        Path whose ABSENCE lets postBootBench run; the script creates it when it finishes.
      '';
    };

    keepAwake = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pin the card out of runtime D3 (`NVreg_DynamicPowerManagement=0x00`; the driver's
        stock default is 3) for as long as the unlock is on. Upstream's own README: on
        laptops the unlock silently resets whenever the dGPU is fully powered off, and
        dynamic PM does exactly that on an idle Legion - so with this off, the unlock is
        only trustworthy right after boot or resume. Costs idle battery on battery power;
        set false on a host whose dGPU demonstrably never sleeps.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The upstream option stays read-only from the outside: this module is the single
    # place that fills it (targets/resume), so keepAwake and the unfree allowance below
    # can never drift from what actually loads.
    assertions = [
      {
        assertion = !(config.hardware.nvidia.gpuUnlock.enable or false) || cfg.enable;
        message = ''
          hardware.nvidia.gpuUnlock.enable is set directly - drive the unlock through
          MODULES.hardware.nvidia.gpuUnlock instead (this module owns the wiring).
        '';
      }
    ];

    hardware.nvidia.gpuUnlock = {
      enable = true;
      inherit (cfg) targets resume;
    };

    # The firmware package is unfreeRedistributableFirmware (it extracts NVIDIA blobs at
    # build time). mkAfter keeps modules/hardware/nvidia.nix's predicate as the base -
    # allowUnfreePredicate is a single function, last writer wins without the merge.
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) ["gpu-unlock-firmware"];

    # Written after nvidia.nix's own line (that module ASSIGNS extraModprobeConfig, so a
    # plain assignment here would collide outright).
    #
    # keepAwake pins RUNTIME power management only. resume additionally needs nvidia's kernel
    # suspend notifiers: gpu_unlock re-unlocks from a PM notifier that must run before nvidia
    # resumes the card, and upstream states that precondition outright ("its suspend notifier
    # runs just ahead of the one nvidia resumes its cards from ... needs
    # NVreg_UseKernelSuspendNotifiers=1").
    #
    # Set here rather than via hardware.nvidia.powerManagement.kernelSuspendNotifier because
    # nixpkgs ANDs that option with powerManagement.enable, which modules/hardware/nvidia.nix
    # turns OFF fleet-wide (legion5 force-enables it in its generated hardware-configuration.nix
    # for VRAM preservation across suspend, so the hosts already differ - and an option that
    # silently no-ops on half the fleet is worse than the explicit parameter). Going through the
    # raw parameter also avoids importing powerManagement where it is not wanted, i.e.
    # PreserveVideoMemoryAllocations and the nvidia-suspend/nvidia-resume units.
    boot.extraModprobeConfig = lib.mkAfter (
      lib.concatStringsSep "\n" (
        lib.optionals cfg.keepAwake ["options nvidia NVreg_DynamicPowerManagement=0x00"]
        ++ lib.optionals cfg.resume ["options nvidia NVreg_UseKernelSuspendNotifiers=1"]
      )
      + "\n"
    );

    # A labelled entry that is this same system minus the unlock. The mechanism is that this
    # module's entire config block is `lib.mkIf cfg.enable`, so forcing the flag false in the
    # child drops everything the unlock adds at once - the hardware.nvidia.gpuUnlock handoff, the
    # kernel params, the initrd module and firmware, and the modprobe lines above - and
    # install-grub.pl then builds the entry from the CHILD's own kernel/initrd/kernel-params.
    # Verified on legion5 2026-10-29 (member counts in the stockEntry description). Note the
    # option is top-level `specialisation.<name>`, NOT `boot.specialisation`: the latter does not
    # exist on nixpkgs 26.05 and fails eval.
    specialisation.gpu-unlock-stock = lib.mkIf (cfg.enable && cfg.stockEntry) {
      inheritParentConfig = true;
      configuration = {
        MODULES.hardware.nvidia.gpuUnlock.enable = lib.mkForce false;
        # install-grub.pl reads this off the specialisation's toplevel and uses it verbatim as
        # the menu entry name.
        boot.loader.grub.configurationName = "gpu-unlock OFF (stock tensor rate)";
      };
    };

    # The measurement is boot-owned because the agent that arranged the reboot cannot survive
    # it. Installed with `nixos-rebuild boot` (generation written, not activated) so the unit
    # fires on the FIRST BOOT of the new kernel - activating it instead would measure the
    # still-locked card and burn the once-marker. No After= on the target that wants us:
    # multi-user is ordered after its own Wants, and the script's own settle-sleep covers it.
    # 30 min of headroom: the v2 bench alone is ~10.5 min (5-min soak), and the script around
    # it settles 45 s before that.
    systemd.services.gpu-unlock-bench = lib.mkIf (cfg.postBootBench != null) {
      description = "One-shot gpu-unlock tensor-rate measurement";
      wantedBy = ["multi-user.target"];
      unitConfig.ConditionPathExists = "!${cfg.benchOnceMarker}";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = cfg.postBootBench;
        TimeoutStartSec = "30min";
      };
    };

    # resume=false is now a measured loss, not a theoretical one, so make the eval say it.
    warnings = lib.optionals (!cfg.resume) [
      ''
        gpu-unlock is on with resume=false: one suspend powers the card off and the unlock is
        GONE until the next cold boot (measured on legion5 2026-10-29 - a single lid close took
        the bf16/fp32 tensor ratio from 6.0 back to 4.07, with no error in any log). Use
        resume=true unless this host genuinely never suspends.
      ''
    ];
  };
}
