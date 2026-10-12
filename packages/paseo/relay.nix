{
  lib,
  fetchurl,
  beam,
}: let
  # getpaseo/paseo-relay's .tool-versions pins erlang 29 / elixir 1.20; beam.packages.erlang_29
  # carries an elixir_1_20 built against exactly that OTP, and both mix helpers below take it as
  # an override (their default `elixir` attr is the set's older 1.18).
  beamPackages = beam.packages.erlang_29;
  elixir = beamPackages.elixir_1_20;
  version = "0.1.0";
  rev = "3fc41c96c8c63f3a7109e832899cc57d473c4531";

  # No published image (Docker Hub and GHCR both lack getpaseo/paseo-relay) - upstream expects
  # `docker build` from source, so build the same OTP release with Nix instead.
  src = fetchurl {
    url = "https://github.com/getpaseo/paseo-relay/archive/${rev}.tar.gz";
    hash = "sha256-UABsJhDDx2kYilHnP1ks+1awwZ7ToioRX3ihOA/KsuU=";
  };

  # The GitHub archive unpacks to a <repo>-<rev>/ directory.
  sourceRoot = "paseo-relay-${rev}";

  deps = beamPackages.fetchMixDeps {
    pname = "paseo-relay-deps";
    inherit version src elixir sourceRoot;
    mixEnv = "prod";
    hash = "sha256-3J2C4XGqjdM0TYf+Vkv5/AY59tiKLVX81Gxrs9pvKuY=";
  };
in
  beamPackages.mixRelease {
    pname = "paseo-relay";
    inherit version src elixir sourceRoot;
    mixFodDeps = deps;
    # mix.exs names the single release paseo_relay; systemd starts `_build/prod/rel/.../bin/paseo_relay`.
    mixReleaseName = "paseo_relay";
    # The upstream mix.exs ignores three advisory CVEs in cowlib/cowboy's *client* code paths,
    # which the relay (a server) doesn't run - same call upstream's CI makes.
    meta = {
      description = "Paseo Relay: stateless, zero-knowledge WebSocket relay for Paseo daemons/clients";
      homepage = "https://github.com/getpaseo/paseo-relay";
      license = lib.licenses.asl20;
    };
  }
