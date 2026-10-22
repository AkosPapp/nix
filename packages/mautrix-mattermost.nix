{
  lib,
  buildGoModule,
  fetchFromGitHub,
  pkg-config,
  sqlite,
  openssl,
}:
# mautrix-mattermost: a Matrix<->Mattermost puppeting bridge built on mautrix-go bridgev2.
# NOT in nixpkgs and NOT an official mautrix project: github.com/aiku/mautrix-mattermost is a
# one-contributor, AI-assisted codebase frozen at its last commit (2026-02-26, 17 commits total).
# It is pinned to that exact sha, audited (no exec/phone-home/telemetry paths found; official
# Mattermost Go SDK + mautrix-go v0.23.3 only; analytics disabled via config), and runs under the
# same unit sandboxing as the other bridges. A rebuild only ever happens by bumping `rev` here.
#
# The bridge speaks Mattermost through a Personal Access Token (revocable in the MM UI); the
# Matrix side is a normal appservice like the discord/slack bridges.
#
# go-sqlite3 (indirect, for the bridgev2 sqlite driver) is a CGO package, hence CGO_ENABLED +
# sqlite; the `goolm` build tag swaps libolm's cgo bindings for pure-Go olm, so no libolm here
# (and no nixpkgs insecure-olm warning).
let
  mmVersion = "0.3.0-unstable-2026-02-26";
in
  buildGoModule {
    pname = "mautrix-mattermost";
    version = mmVersion;

    src = fetchFromGitHub {
      owner = "aiku";
      repo = "mautrix-mattermost";
      rev = "96283ac8e34181e089dcdc09ffd2bcf22732c9f4";
      hash = "sha256-3hNLThK/rYhc06nwyYw8HZNxA8SNE/IhHdt2rYM3GcA=";
    };

    vendorHash = "sha256-pMdOaYPQCHzJxx4MGRp8ywwKMMLJIUMdAmCcHV+DMFM=";

    # Upstream-frozen fork: fetches a whole channel window when bridgev2 asks for a
    # thread's messages, duplicating every backfilled message in threaded channels.
    # See the patch header for the incident details. Drop if the fork ever revives.
    patches = [./mautrix-mattermost/thread-backfill.patch ./mautrix-mattermost/dp-member.patch];

    subPackages = ["cmd/mautrix-mattermost"];
    tags = ["goolm"];

    # CGO stays on (native stdenv default): go-sqlite3 needs it.
    nativeBuildInputs = [pkg-config];
    buildInputs = [
      sqlite
      openssl
    ];

    # The Makefile stamps version info via -X ldflags from git; unnecessary here (the binary only
    # logs it), and there is no .git in the fixed-output source.
    ldflags = [
      "-s"
      "-w"
      "-X main.Tag=${mmVersion}"
    ];

    doCheck = false;

    meta = {
      description = "Matrix-Mattermost puppeting bridge (mautrix-go bridgev2)";
      homepage = "https://github.com/aiku/mautrix-mattermost";
      license = lib.licenses.mpl20;
      mainProgram = "mautrix-mattermost";
      platforms = lib.platforms.linux;
    };
  }
