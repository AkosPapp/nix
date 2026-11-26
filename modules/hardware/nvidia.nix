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
        libnvidia-container
        cudatoolkit
      ])
      ++ [config.hardware.nvidia.package];

    hardware.nvidia = {
      modesetting.enable = true;
      powerManagement.enable = false;
      open = false;
      nvidiaSettings = false;
      nvidiaPersistenced = false;
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
          #"nvidia-persistenced"
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

    # The nixpkgs CDI generator is a oneshot that NVMLs the store driver of
    # THIS system - i.e. the userspace of a kernel module that is not the one
    # loaded in the running kernel. Measured on legion5 2026-11-26: a switch
    # that bumped the driver 595.71.05 -> 595.112.07 restarted the unit; the
    # old module is still loaded (unreloadable, ~500 referrers), every NVML
    # call dies "Driver/library version mismatch", the oneshot exits 1, and
    # switch-to-configuration returns 4 on every switch until reboot. The
    # same race exists cold, before udev has created /dev/nvidia* (nixpkgs's
    # ExecStartPre is a `udevadm settle` it itself calls "essentially no
    # better than a random sleep"). Guard generation with an ExecCondition
    # probe: a non-zero condition skips the start and leaves the unit
    # inactive, NOT failed (measured on systemd 260.5), so the switch stays
    # clean; nixpkgs's own udev rule (KERNEL=="nvidia" -> restart this unit)
    # regenerates the spec on the coldplug and on the reboot that finally
    # swaps the module. Restart= is NOT an option: a unit that fails into
    # auto-restart still has Failed=yes and is still counted by the switch
    # (nixpkgs switch-test's autorestartServiceFailing asserts exactly that).
    systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.ExecCondition =
      lib.getExe' config.hardware.nvidia.package "nvidia-smi";

    systemd.services.k3s.path = with pkgs; [libnvidia-container];

    boot.kernel.sysctl = {
      # https://github.com/NVIDIA/libnvidia-container/issues/176
      "net.core.bpf_jit_harden" = 1;
    };

    environment.variables = {
      GPU_FLAG = "--device=nvidia.com/gpu=all";
    };

    virtualisation.docker.daemon.settings = {
      default-runtime = "nvidia";
      runtimes = {
        nvidia = {
          path = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime";
          runtimeArgs = [];
        };
      };
    };

    virtualisation.containerd.enable = true;
    virtualisation.containerd.settings = {
      plugins = {
        plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia = {
          runtime_type = "io.containerd.runc.v2";
          options = {
            BinaryName = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime";
            SystemdCgroup = true;
          };
        };
      };
    };
  };
}
