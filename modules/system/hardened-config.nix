# Vendored hardened kernel config, from nixpkgs release-25.11
# pkgs/os-specific/linux/kernel/hardened/config.nix (fetched 2026-11-12:
# https://raw.githubusercontent.com/NixOS/nixpkgs/release-25.11/pkgs/os-specific/linux/kernel/hardened/config.nix)
# nixpkgs dropped this file ("linux_hardened has been removed due to lack
# of maintenance", pkgs/top-level/linux-kernels.nix @ 6f06d204d8f2); we keep
# the grafix-patched hardened kernel via modules/system/hardened-kernel.nix,
# which merges the option value defined here into the kernel's
# structuredExtraConfig.
#
# Adaptations against the original (each marked inline with ADAPTED):
#   - the GCC-plugin hardening options were renamed/removed upstream before
#     6.18 (stackleak -> KSTACK_ERASE; the randstruct/structleak plugins and
#     the whole GCC_PLUGIN_* family except LATENT_ENTROPY vanished with the
#     gcc-plugin infrastructure), so entries were pruned/renamed to what
#     v6.18's Kconfig actually defines. Verified 2026-11-12 against
#     torvalds/linux v6.18 arch/Kconfig, security/Kconfig.hardening and
#     scripts/gcc-plugins/Kconfig.
#   - CONFIG_LDISC_AUTOLOAD: the key's CONFIG_ prefix was already a bug in
#     the vendored file: structuredExtraConfig keys are matched against bare
#     Kconfig names (generate-config.pl's answer-file keys), so the prefixed
#     key could never answer the LDISC_AUTOLOAD question and the restriction
#     silently never applied.
#
# Original header:
#
# Based on recommendations from:
# http://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project#Recommended_settings
# https://wiki.gentoo.org/wiki/Hardened/Hardened_Kernel_Project
#
# Dangerous features that can be permanently (for the boot session) disabled at
# boot via sysctl or kernel cmdline are left enabled here, for improved
# flexibility.
#
# See also <nixos/modules/profiles/hardened.nix>
{
  config,
  pkgs,
  lib,
  ...
}: let
  # The grafix build reuses the pin's default kernel source, so this config is
  # written against exactly that version's Kconfig symbol set.
  version = config.MODULES.system.hardenedKernel.version;
in
  lib.mkIf config.MODULES.system.hardenedKernel.enable {
    MODULES.system.hardenedKernel.hardenedConfig = with lib.kernel;
    with (lib.kernel.whenHelpers version);
    assert lib.versionAtLeast version "4.9"; {
      # Mark LSM hooks read-only after init.  SECURITY_WRITABLE_HOOKS n
      # conflicts with SECURITY_SELINUX_DISABLE y; disabling the latter
      # implicitly marks LSM hooks read-only after init.
      #
      # SELinux can only be disabled at boot via selinux=0
      #
      # We set SECURITY_WRITABLE_HOOKS n primarily for documentation purposes;
      # the config builder fails to detect that it has indeed been unset.
      SECURITY_SELINUX_DISABLE = whenOlder "6.4" no; # On 6.4: error: unused option: SECURITY_SELINUX_DISABLE
      SECURITY_WRITABLE_HOOKS = option no;

      # Perform additional validation of commonly targeted structures.
      DEBUG_CREDENTIALS = whenOlder "6.6" yes;
      DEBUG_NOTIFIERS = yes;
      DEBUG_PI_LIST = whenOlder "5.2" yes; # doesn't BUG()
      DEBUG_PLIST = whenAtLeast "5.2" yes;
      DEBUG_SG = yes;
      DEBUG_VIRTUAL = yes;
      SCHED_STACK_END_CHECK = yes;

      REFCOUNT_FULL = whenOlder "5.4.208" yes;

      # tell EFI to wipe memory during reset
      # https://lwn.net/Articles/730006/
      RESET_ATTACK_MITIGATION = yes;

      # restricts loading of line disciplines via TIOCSETD ioctl to
      # CAP_SYS_MODULE. ADAPTED: the vendored file spelled this
      # `CONFIG_LDISC_AUTOLOAD = option no;` - a dead key that could never
      # answer the question (see header); bare name + mandatory n now so the
      # restriction actually applies.
      LDISC_AUTOLOAD = no;

      # Wipe higher-level memory allocations on free() with page_poison=1
      PAGE_POISONING_NO_SANITY = whenOlder "5.11" yes;
      PAGE_POISONING_ZERO = whenOlder "5.11" yes;

      # Enable init_on_free by default
      INIT_ON_FREE_DEFAULT_ON = whenAtLeast "5.3" yes;

      # Wipe all caller-used registers on exit from a function
      ZERO_CALL_USED_REGS = whenAtLeast "5.15" yes;

      # ADAPTED: the eraser GCC_PLUGIN_STACKLEAK was became KSTACK_ERASE in
      # 6.13+ (security/Kconfig.hardening); its GCC-plugin implementation is a
      # def_bool under GCC_PLUGINS, so only the KSTACK_ERASE gate is set here.
      # The grafix patch already defaults INIT_ON_ALLOC/INIT_ON_FREE on and
      # adds PAGE_SANITIZE_VERIFY; this keeps the hardened intent explicit.
      KSTACK_ERASE = whenAtLeast "6.13" yes;

      # Enable the SafeSetId LSM
      SECURITY_SAFESETID = whenAtLeast "5.1" yes;

      # Reboot devices immediately if kernel experiences an Oops.
      PANIC_TIMEOUT = freeform "-1";

      # ADAPTED: dropped vs the vendored file - GCC_PLUGINS,
      # GCC_PLUGIN_STRUCTLEAK{,_BYREF_ALL}, GCC_PLUGIN_STACKLEAK,
      # GCC_PLUGIN_RANDSTRUCT{,_PERFORMANCE}, UBSAN_LOCAL_BOUNDS (a clang-only
      # def_bool) and CFI_CLANG (clang-only) do not exist as prompts on this
      # tree; a mandatory yes/no answer for a nonexistent symbol FAILS the pc
      # config build ("error: unused option", generate-config.pl +
      # ignoreConfigErrors=false on pc/x86_64). structleak's goal is served by
      # the auto-var-init defaults the hardened tree enables; randstruct is
      # gone with the gcc-plugin infrastructure.

      # Runtime undefined behaviour checks
      # https://www.kernel.org/doc/html/latest/dev-tools/ubsan.html
      # https://developers.redhat.com/blog/2014-10-16/gcc-undefined-behavior-sanitizer-ubsan
      UBSAN = yes;
      UBSAN_TRAP = whenAtLeast "5.7" yes;
      UBSAN_BOUNDS = whenAtLeast "5.7" yes;
      UBSAN_SANITIZE_ALL = whenOlder "6.9" yes;

      # Disable various dangerous settings
      ACPI_CUSTOM_METHOD = whenOlder "6.9" no; # Allows writing directly to physical memory
      PROC_KCORE = no; # Exposes kernel text image layout
      INET_DIAG = no; # Has been used for heap based attacks in the past

      # INET_DIAG=n causes the following options to not exist anymore, but
      # since they are defined in common-config.nix, make them optional
      INET_DIAG_DESTROY = option no;
      INET_RAW_DIAG = option no;
      INET_TCP_DIAG = option no;
      INET_UDP_DIAG = option no;
      INET_MPTCP_DIAG = option no;

      # Use -fstack-protector-strong (gcc 4.9+) for best stack canary
      # coverage. On 6.18 STRONG is the only variant left (REGULAR was
      # removed); the whenOlder guards below make both entries inert here,
      # kept for the day the vendored file is diffed against a new pin.
      CC_STACKPROTECTOR_REGULAR = lib.mkForce (whenOlder "4.18" no);
      CC_STACKPROTECTOR_STRONG = whenOlder "4.18" yes;

      # CONFIG_DEVMEM=n causes these to not exist anymore.
      STRICT_DEVMEM = option no;
      IO_STRICT_DEVMEM = option no;

      # stricter IOMMU TLB invalidation
      IOMMU_DEFAULT_DMA_STRICT = option yes;
      IOMMU_DEFAULT_DMA_LAZY = option no;

      # not needed for less than a decade old glibc versions
      LEGACY_VSYSCALL_NONE = lib.mkIf pkgs.stdenv.hostPlatform.isx86 yes;
    };
  }
