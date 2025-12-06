{
  config,
  lib,
  pkgs,
  ...
}: {
  options = {
    MODULES.hardware.nvidia.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable NVIDIA hardware support.";
    };
  };
  config = lib.mkIf config.MODULES.hardware.nvidia.enable {
    # See also https://nixos.wiki/wiki/Nvidia
    boot.initrd.kernelModules = ["nvidia"];
    boot.extraModulePackages = [config.hardware.nvidia.package];

    environment.systemPackages =
      (with pkgs; [
        nvitop
        nvidia-container-toolkit
        nvidia-container-toolkit.tools
      ])
      ++ [config.hardware.nvidia.package];

    hardware.nvidia = {
      modesetting.enable = true;
      powerManagement.enable = false;
      open = false;
      nvidiaSettings = false;
      nvidiaPersistenced = true;
    };

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    services.xserver.videoDrivers = ["nvidia"];

    nixpkgs.config = {
      nvidia.acceptLicense = true;
      allowUnfreePredicate = pkg:
        builtins.elem (lib.getName pkg) [
          "nvidia-x11"
          "nvidia-persistenced"
        ];
    };

    # https://nixos.wiki/wiki/K3s#Nvidia_support
    services.k3s.containerdConfigTemplate = ''
      {{ template "base" . }}

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
        # privileged_without_host_devices = false
        runtime_type = "io.containerd.runc.v2"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
        BinaryName = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime"
        SystemdCgroup = true
    '';

    hardware = {
      nvidia-container-toolkit.enable = true;
    };

    systemd.services.k3s.path = with pkgs; [libnvidia-container];

    boot.kernel.sysctl = {
      # https://github.com/NVIDIA/libnvidia-container/issues/176
      "net.core.bpf_jit_harden" = 1;
    };

    virtualisation.docker.daemon.settings = {
      "default-runtime" = "nvidia";
      "runtimes" = {
        "nvidia" = {
          "path" = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime";
          "runtimeArgs" = [];
        };
      };
    };
  };
}
