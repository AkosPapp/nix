{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.MODULES.dev.md2pdf;
in {
  options.MODULES.dev.md2pdf = {
    enable = lib.mkEnableOption ''
      md2pdf, a Markdown -> PDF converter that renders LaTeX math for real
      (pandoc -> HTML with bundled MathJax -> headless Chromium print-to-pdf;
      emoji and CJK included), renders mermaid diagrams through mermaid-cli
      as vector SVGs, and treats a '---' line as a PAGE break. Installs the
      `md2pdf` binary into environment.systemPackages.
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/md2pdf/default.nix {};
      description = ''
        The md2pdf derivation to install. Override to retarget the MathJax
        pin or the bundled stylesheet without forking the module.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];
  };
}
