_: {
  # crates.io 403s any request whose User-Agent starts with "curl/", which is exactly what
  # nixpkgs' fetchurl sends ("curl/<ver> Nixpkgs/<ver>"). Every uncached crate download - the
  # per-crate FODs behind fetchCargoVendor and crane's cargo-vendor-dir - dies on it.
  #
  # NIX_CURL_FLAGS is in fetchurl's impureEnvVars and is appended after the hardcoded
  # --user-agent; curl honours the last one it is given. Builds run under the daemon, so the
  # variable has to live in the daemon's environment rather than the caller's.
  #
  # Applies to every host: each one builds its own closure, and akos01 additionally builds
  # other repos through nix_autobuild.
  systemd.services.nix-daemon.environment.NIX_CURL_FLAGS = "--user-agent nixpkgs";
}
