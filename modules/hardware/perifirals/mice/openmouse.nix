{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.MODULES.hardware.perifirals.mice.openmouse;

  # Upstream lists this as a `git+ssh` npm dependency, which cannot be fetched inside the sandbox.
  # It is built on its own here and spliced into node_modules of the desktop build below.
  mouse-protocol = pkgs.buildNpmPackage {
    pname = "openmouse-mouse-protocol";
    version = "0.1.0";

    src = pkgs.fetchFromGitHub {
      owner = "OpenMouse-Project";
      repo = "mouse-protocol";
      rev = "f780d0dcc4e120ba9e6a540af66a798591134c7f";
      hash = "sha256-QbbULI3vxucfIe+TxrFLlcgxYqjcpOQotmgl2UXpDAg=";
    };

    npmDepsHash = "sha256-L1mN0QzbR97hKmYU9Czy80sdBwt0tRbMhtSFhBdKFRs=";

    # `prepare` already runs the tsc build; only the package manifest and dist/ are needed.
    dontNpmInstall = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r package.json dist $out/
      runHook postInstall
    '';
  };

  openmouse-desktop = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "openmouse-desktop";
    version = "0.0.29";

    src = pkgs.fetchFromGitHub {
      owner = "OpenMouse-Project";
      repo = "Desktop";
      tag = "v${finalAttrs.version}";
      hash = "sha256-C1IAUqmKSgxLlGrobeFy69pZky+JCdv1k7LnOhX9gaQ=";
    };

    cargoRoot = "src-tauri";
    buildAndTestSubdir = finalAttrs.cargoRoot;
    cargoHash = "sha256-cM2qRb5BqZkVngiZ7tRcXI7TFahtO/v6MZJsLTeYk0s=";

    # Drop the git dependency from the manifest and lockfile so the offline npm fetch succeeds;
    # preBuild puts the separately built copy in its place.
    postPatch = ''
      ${pkgs.jq}/bin/jq 'del(.dependencies["@openmouse/protocol"])' package.json > package.json.new
      mv package.json.new package.json
      ${pkgs.jq}/bin/jq '
        del(.packages[""].dependencies["@openmouse/protocol"])
        | del(.packages["node_modules/@openmouse/protocol"])
      ' package-lock.json > package-lock.json.new
      mv package-lock.json.new package-lock.json
    '';

    npmDeps = pkgs.fetchNpmDeps {
      name = "${finalAttrs.pname}-${finalAttrs.version}-npm-deps";
      inherit (finalAttrs) src postPatch;
      hash = "sha256-jV4tu9aqi+T0H0ETFT4nzzMT353OVZp8X+Aq5mKC4B4=";
    };

    preBuild = ''
      mkdir -p node_modules/@openmouse
      cp -r ${mouse-protocol} node_modules/@openmouse/protocol
      chmod -R u+w node_modules/@openmouse
    '';

    nativeBuildInputs = with pkgs; [
      cargo-tauri.hook
      nodejs
      npmHooks.npmConfigHook
      pkg-config
      wrapGAppsHook3
    ];

    buildInputs = with pkgs; [
      glib-networking
      libayatana-appindicator
      openssl
      systemd # libudev for hidapi
      webkitgtk_4_1
    ];

    # Updater artifacts must be signed with a key that only upstream holds; updates come from Nix.
    tauriBuildFlags = ["--config" ''{"bundle":{"createUpdaterArtifacts":false}}''];

    # libappindicator-sys dlopen()s the tray library, so it is not linked and must be on the path.
    preFixup = ''
      gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [pkgs.libayatana-appindicator]})
    '';

    doCheck = false;

    meta = {
      description = "Desktop app for configuring gaming mice";
      homepage = "https://github.com/OpenMouse-Project/Desktop";
      mainProgram = "openmouse-desktop";
      platforms = lib.platforms.linux;
    };
  });
in {
  options.MODULES.hardware.perifirals.mice.openmouse.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Install OpenMouse Desktop and the udev rules that give the local user access to supported mice.";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [openmouse-desktop];

    # Upstream's 70-openmouse.rules, shipped in the source tree: tags the vendor's hidraw nodes
    # with `uaccess` so the active session user may open them.
    services.udev.packages = [
      (pkgs.runCommand "openmouse-udev-rules" {} ''
        install -Dm444 ${openmouse-desktop.src}/src-tauri/linux/70-openmouse.rules \
          $out/lib/udev/rules.d/70-openmouse.rules
      '')
    ];
  };
}
