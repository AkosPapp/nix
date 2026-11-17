{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
}:
# Kilo Code CLI (the `kilo` binary) from upstream's own linux-x64 release
# tarball. nixpkgs' `kilo` is marked broken (2026-11-05: NixOS/nixpkgs#542516,
# broken on all platforms for over a month, maintainer unresponsive), and the
# fleet rule is no allowBroken, so we ship the vendor binary here instead -
# the same doctrine as packages/jmpchat-matrix-bridge.nix for unfetchable
# npm builds. fetchurl (NOT fetchzip): the tarball has several files at its
# root (kilo, bwrap, seccomp helpers), which fetchzip refuses outright, and
# a raw-file hash is verifiable against upstream's own
# https://github.com/Kilo-Org/kilocode/releases/download/v<vers>/kilo-cli-SHA256SUMS
# (kilo-linux-x64.tar.gz = 4c08aa46...de08 for v7.8.27, verified against upstream's
# SHA256SUMS 2026-11-09; the previous 7.8.18 asset was 503561fb...c02a, checked
# 2026-11-05). Bump by swapping the tag + re-hashing the release asset and
# `kilo --version`-checking the binary still runs (verified 7.8.18 on legion5 2026-11-05).
stdenv.mkDerivation (finalAttrs: {
  pname = "kilo-cli";
  version = "7.8.27";

  src = fetchurl {
    url = "https://github.com/Kilo-Org/kilocode/releases/download/v${finalAttrs.version}/kilo-linux-x64.tar.gz";
    hash = "sha256-TAiqRt2HRToyn0iw8A000Pp7jwrJEP6JN4FNToWC3gg=";
  };

  # The kiosk bwrap + seccomp helpers must live NEXT TO the kilo binary (it
  # spawns them by sibling path), and the wasm/console trees next to those -
  # so the whole tarball layout is copied verbatim into $out/lib/kilo and
  # bin/kilo is a wrapper that execs it.
  #
  # NO autoPatchelfHook: the bun-built main binary crashes under a patched
  # ELF (legion5 2026-11-05: `ld.so: dl-setup_hash.c: Assertion
  # (bitmask_nwords & (bitmask_nwords - 1)) == 0 failed` the moment patchelf
  # touched its GNU-hash section), and patching is unnecessary anyway - the
  # binary's PT_INTERP (/lib64/ld-linux-x86-64.so.2) and its libc lookup both
  # resolve on stock NixOS, verified from the untouched tarball on legion5.
  # If a future release needs libs NixOS lacks, add them to the wrapper's env
  # (LD_LIBRARY_PATH), not to the ELF.
  #
  # unpackPhase is skipped (stdenv's unpacker refuses the multi-root tarball,
  # "unpacker produced multiple directories"); installPhase untars by hand,
  # which also keeps the sibling layout verbatim.
  #
  # dontStrip is load-bearing (legion5 2026-11-05): stdenv strip rewrites
  # the bun-compiled ELF and DROPS the ~6.6 KB app payload appended after the
  # section headers - the truncated binary boots as a plain `bun` runtime
  # (kilo --version answered 1.4.4, `kilo run <prompt>` tried to execute the
  # prompt as a script file). Untouched binaries answer 7.8.18.
  dontStrip = true;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/kilo $out/bin
    tar xzf $src -C $out/lib/kilo
    chmod +x $out/lib/kilo/kilo $out/lib/kilo/bwrap $out/lib/kilo/kilo-sandbox-seccomp

    makeWrapper $out/lib/kilo/kilo $out/bin/kilo

    runHook postInstall
  '';

  meta = {
    description = "Kilo Code CLI - agentic coding in the terminal (OpenCode fork)";
    homepage = "https://github.com/Kilo-Org/kilocode";
    license = lib.licenses.asl20;
    mainProgram = "kilo";
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
  };
})
