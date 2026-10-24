{
  lib,
  stdenvNoCC,
  fetchurl,
  buildGoModule,
  fetchFromGitHub,
  pkg-config,
  sqlite,
  openssl,
  olm,
}: let
  # nixpkgs marks libolm insecure (side-channel CVEs in Matrix E2EE). This is the one bridge in
  # this repo that genuinely uses E2EE, so we accept the flagged library for this build rather
  # than export NIXPKGS_ALLOW_INSECURE host-wide - the exact informed decision discord's comment
  # in modules/services/mautrix.nix describes for its libolm-linked bridge.
  olmInsecureCleared = olm.overrideAttrs (finalOlm: prevOlm: {
    meta =
      prevOlm.meta
      // {
        knownVulnerabilities = [];
      };
  });

  # go.mod pins `go 1.26.8`; nixpkgs (26.05) ships Go only up to 1.24, and buildGoModule
  # cannot let the toolchain auto-download in the sandbox. Pin the official tarball instead -
  # a GOROOT-shaped derivation, unpacked verbatim, is exactly what buildGoModule expects of
  # its `go` argument (pkgs.go is built the same way).
  go_1_26 = stdenvNoCC.mkDerivation {
    pname = "go";
    version = "1.26.8";
    src = fetchurl {
      url = "https://go.dev/dl/go1.26.8.linux-amd64.tar.gz";
      hash = "sha256-0PdDsz6NiUXmsfQy7dFXhccFBxIdbipyOyEoXt34tXs=";
    };
    sourceRoot = "go";
    dontFixup = true;
    installPhase = "cp -r . $out";
    # buildGoModule's hooks read these off the go package (see pkgs.go's passthru).
    passthru = {
      GOOS = "linux";
      GOARCH = "amd64";
      CGO_ENABLED = 1;
    };
  };
  # jmpchat-matrix-bridge - the maintained successor of mautrix-jabber (mautrix-go bridgev2
  # generation): a per-user XMPP puppeting bridge (DMs, MUCs, carbons, MAM backfill, media,
  # reactions), command prefix !jabber. Built with the `nocrypto` tag: Matrix-side E2EE is off
  # on every bridge in this repo (see mautrix.nix bridgeSettings), which drops the libolm/CGO
  # olm dependency. CGO stays on because the sqlite driver needs it. XMPP-side OMEMO is on the
  # upstream roadmap but unimplemented: messages encrypted on the phone arrive as a "this was
  # E2EE, open in an XMPP client" notice.
in
  (buildGoModule.override {go = go_1_26;}) {
    pname = "jmpchat-matrix-bridge";
    version = "0.9.6";

    src = fetchFromGitHub {
      owner = "williamkray";
      repo = "jmpchat-matrix-bridge";
      rev = "v0.9.6";
      hash = "sha256-eNnbvWmsjpjncWJ4P0r4z1lvBgA3McSVRC+DFvtyvoQ=";
    };

    # Default build = with end-to-bridge encryption (E2BE), which the Matrix side of this bridge
    # uses (see the jabber block in mautrix.nix). CGO stays on both for go-sqlite3 and for libolm,
    # which E2BE links. nixpkgs flags libolm insecure (Matrix E2EE side-channel CVEs); the jabber
    # bridge is the one bridge here that actually uses E2EE, so we accept libolm rather than the
    # pure-Go path (mautrix v0.32 dropped goolm). Same informed tradeoff discord's comment notes.
    tags = [];

    vendorHash = "sha256-ymvKhJhEu7bdc0Xe/OUf+aQkOZctVgHD7cDGapzsGb4=";

    nativeBuildInputs = [pkg-config];
    buildInputs = [
      sqlite
      openssl
      olmInsecureCleared
    ];

    ldflags = ["-s" "-w"];

    doCheck = false;

    meta = {
      description = "Matrix <-> XMPP/Jabber puppeting bridge (successor of mautrix-jabber)";
      homepage = "https://github.com/williamkray/jmpchat-matrix-bridge";
      license = lib.licenses.agpl3Plus;
      mainProgram = "jmpchat-matrix-bridge";
      platforms = lib.platforms.linux;
    };
  }
