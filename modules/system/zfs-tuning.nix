# Fleet ZFS ARC behavior: never cap the ARC, make it yield FAST instead.
#
# Measured on akos01 2026-11-11 (the motivating incident): with an uncapped ARC on an
# 11 GiB box, arcstats sat at ~6.4G while anon was ~10G - fine until a cgroup hit its
# MemoryHigh throttle line, because kswapd only wakes at watermark_scale_factor=10
# (0.1% of managed RAM ≈ 11M here, plus the 67M min_free) - by then direct reclaimers
# are ALREADY stalling everywhere, and the ARC - the biggest reclaimable pool - yields
# only after them. Result: node-exporter (capped right at the time) hung scrapes for
# >20s at 83% PSI, immich-api/microservices blew their scrape deadlines, coroot
# alerted "high memory stall" on three units. The fix is wake-up latency, not a ceiling:
# at factor 400 + min_free 128M kswapd starts shrinking ARC at ~570M free, keeps a
# permanent cushion, and services never wait on reclaim. The ARC still uses (and reuses,
# cache-warm, seconds later) whatever RAM is left - which is the point: akos01's files
# live on a slow CIFS-mounted Ceph drive, where an evicted-then-refetched block costs
# seconds, not microseconds. Same host, after the live sysctls: all exporters answer in
# 0.04-0.28s with PSI avg10 at 0.0 while the ARC refills under kswapd's supervision.
#
# Deliberately NOT touched (checked live on the fleet's OpenZFS 2.4.4): the shrink
# amount per call (zfs_arc_shrink_shift=0 already reclaims the maximum), unlimited
# shrinker retries (zfs_arc_shrinker_limit=0) and instant regrowth (zfs_arc_grow_retry
# =0) are all already at their most responsive defaults. Only the wake-up was wrong.
#
# Two mechanisms, two jobs:
# - the watermarks below are REACTIVE (yield fast once anything wants RAM back);
# - zfs_arc_sys_free (arcHeadroom) is PROACTIVE: it keeps a standing free-RAM floor
#   the ARC grows up to but never into, so the first byte a service needs is already
#   there instead of waiting on a shrink. 1 GiB (owner call 2026-11-11; the 2 GiB
#   value it was set with measured 0 direct-reclaim stalls/15s on akos01 - 1 GiB
#   leaves more of the slow-Ceph read cache warm with the watermarks still backing
#   it up). This one is a zfs module
#   parameter, so it rides the kernel command line (module params there apply at the
#   module's first load - inside the initrd for our root-on-ZFS hosts - and persist
#   for the module's lifetime; a /etc/modprobe.d entry would arrive after zfs is
#   already loaded and do nothing).
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.MODULES.system.zfsTuning;
in {
  options.MODULES.system.zfsTuning = {
    enable = mkOption {
      type = types.bool;
      default = config.boot.supportedFilesystems.zfs or false;
      defaultText = lib.literalExpression "config.boot.supportedFilesystems.zfs or false";
      description = ''
        Apply the fleet's ARC fast-release VM tunings. Defaults to on for every host
        that supports ZFS (i.e. every zroot host) - the stall this fixes is structural
        (default watermarks vs an uncapped ARC), not host-specific, so a host opts OUT
        only if it genuinely wants the stock latency back.
      '';
    };

    arcHeadroom = mkOption {
      type = types.nullOr types.ints.unsigned;
      default = 1073741824; # 1 GiB
      defaultText = lib.literalExpression "1073741824 # 1 GiB";
      description = ''
        Bytes of RAM the ARC must always leave free (zfs_arc_sys_free): the ARC keeps
        shrinking while system free memory sits below this floor, so it is a standing
        headroom cushion for services, not a cap on the cache itself - everything
        above the floor is still fair game for ARC and regrows into it the moment a
        cache miss wants it. null disables the floor and leaves the watermarks alone
        to do the yielding.
      '';
    };
  };

  config = mkIf cfg.enable {
    boot.kernel.sysctl = {
      # 0.1% -> 4% of managed RAM: kswapd wakes ~440M (12G host) to ~840M (21G host)
      # before free runs dry and keeps the cushion warm against ARC growth.
      "vm.watermark_scale_factor" = 400;
      # 66M -> 128M floor under `min`. Cheap on these boxes; it lifts every watermark
      # together and gives atomic allocations real headroom during shrink storms.
      "vm.min_free_kbytes" = 131072;
    };

    boot.kernelParams = mkIf (cfg.arcHeadroom != null) [
      "zfs.zfs_arc_sys_free=${toString cfg.arcHeadroom}"
    ];
  };
}
