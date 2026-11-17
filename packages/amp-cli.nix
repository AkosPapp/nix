{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
}:
# Amp (Sourcegraph's agentic coding CLI, `amp`) from the vendor's own npm
# release. nixpkgs' `amp` is an UNRELATED package (amp.rs, "Modern text editor
# inspired by Vim" - verified 2026-11-09 on both fleet pins), so the fleet
# vendors the binary, the same doctrine as packages/kilo-cli.nix (broken nixpkgs
# name collision, vendor tarball, no allowBroken).
#
# The @ampcode/cli npm package is a stub: a postinstall picks a per-platform
# package (@ampcode/cli-<os>-<arch>), so the linux-x64 tarball IS the binary -
# fetched directly, and `npm i -g` never runs here. Version 0.0.1794225648-
# g45053b is the tag the npm dist-tag `latest` carried on 2026-11-09 (Amp
# releases continuously; tags are release timestamps, not semver). The shasum
# below is npm's own integrity for that tarball (registry metadata), so a bump
# = swap version + `nix-prefetch-url` (or read the registry's sha512 integrity).
#
# Verified running on legion5 2026-11-09: `amp --version` from the untouched
# tarball binary answers on stock NixOS - it is a bun-compiled static-ish ELF
# like kilo's, so NO autoPatchelfHook and NO dontStrip drama was needed (strip
# was simply skipped the same way; keep it that way if the release layout ever
# changes: stdenv's strip corrupts bun-appended payloads, kilo-cli.nix note).
stdenv.mkDerivation (finalAttrs: {
  pname = "amp-cli";
  version = "0.0.1794225648-g45053b";

  src = fetchurl {
    url = "https://registry.npmjs.org/@ampcode/cli-linux-x64/-/cli-linux-x64-${finalAttrs.version}.tgz";
    hash = "sha512-/TQFL63+kPYAb/nHMsd9EQAQFg5lbtcl53Zut1k17iinTFACawvSLyOUQBCp+G7KrFVn9AE/RDLpqKKQzGCj6Q==";
  };

  dontStrip = true;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/amp $out/bin
    tar xzf $src -C $out/lib/amp
    chmod +x $out/lib/amp/package/amp

    makeWrapper $out/lib/amp/package/amp $out/bin/amp

    runHook postInstall
  '';

  meta = {
    description = "Amp - agentic coding CLI (Sourcegraph)";
    homepage = "https://ampcode.com";
    license = lib.licenses.unfree;
    mainProgram = "amp";
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
  };
})
