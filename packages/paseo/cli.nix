{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs_24,
}:
buildNpmPackage rec {
  pname = "getpaseo-cli";
  version = "0.11.2";

  # The daemon (@getpaseo/server, a dependency) ships its bundled web UI inside its own npm
  # tarball (dist/server/web-ui), so no extra assets are needed to serve the dashboard.
  src = fetchurl {
    url = "https://registry.npmjs.org/@getpaseo/cli/-/cli-${version}.tgz";
    hash = "sha256-UgrrN89+RKY4cWEg0gpdCwmlfzvEj2zV1uJbWHgmbug=";
  };

  # The npm tarball carries no lockfile; this one was generated from the tarball's own
  # package.json (`npm install --package-lock-only`) and is dropped in beside it, which is
  # what npmDepsHash (the offline node_modules fetch) is computed against.
  sourceRoot = "package";
  postPatch = ''
    cp ${./package-lock.json} ./package-lock.json
  '';

  npmDepsHash = "sha256-3gYxJ8bCZycvgJhhgsHYgxA3sL2U/gLjv8nMVMfsajs=";

  # Pure-JS dependency tree (ws, zod, commander, ...) and a prebuilt dist/ - nothing to
  # compile, and the root build/prepack scripts want the monorepo's tsconfig, absent here.
  npmRebuild = false;
  dontNpmBuild = true;

  # Install by tree copy rather than `npm install -g`: that would re-run the package's
  # prepack/build:clean scripts (which fail against the prebuilt tarball), and the whole
  # node_modules produced by the offline `npm ci` just needs to land under $out with it.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/node_modules/@getpaseo/cli"
    cp -r --no-preserve=ownership . "$out/lib/node_modules/@getpaseo/cli"

    mkdir -p "$out/bin"
    cat > "$out/bin/paseo" <<EOF
    #!/bin/sh
    exec ${nodejs_24}/bin/node --disable-warning=DEP0040 \\
      "$out/lib/node_modules/@getpaseo/cli/bin/paseo" "\$@"
    EOF
    chmod +x "$out/bin/paseo"

    runHook postInstall
  '';

  meta = {
    description = "Paseo CLI + daemon: control coding agents from any device";
    homepage = "https://github.com/getpaseo/paseo";
    license = lib.licenses.asl20;
  };
}
