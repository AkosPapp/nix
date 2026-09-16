{
  config,
  lib,
  ...
}: {
  options.MODULES.hardware.accelerator = lib.mkOption {
    type = lib.types.enum ["cpu" "cuda" "rocm"];
    default =
      if config.environment.variables ? GPU_FLAG
      then "cuda"
      else "cpu";
    defaultText = lib.literalMD ''"cuda" when `environment.variables.GPU_FLAG` is set (MODULES.hardware.nvidia sets it), otherwise "cpu"'';
    description = ''
      The compute backend this host's GPU offers to inference runtimes. The one piece of hardware
      detection the LLM runtimes share: MODULES.services.vllm and MODULES.services.ollama both
      default their own backend choice to this, so a host is described once and every runtime on
      it agrees. Set it explicitly for an AMD card ("rocm"), which nothing detects.
    '';
  };
}
