{
  lib,
  python3,
  fetchPypi,
}:
# MCP for Blender (`mcp-for-blender`, formerly PyPI `blender-mcp`): the MCP
# server side of https://github.com/ahujasid/blender-mcp - a stdio MCP server
# that relays tool calls to the addon's socket in a running Blender
# (BLENDER_HOST/BLENDER_PORT env, --host/--port flags). Not in nixpkgs
# (verified against the pinned input 2026-11-06), and MODULES.services.blender-mcp
# needs the bundled addon.py too, so the sdist is built here from the repo's
# `callPackage ../../packages/*.nix` pattern.
#
# Bump: version + hash from https://pypi.org/project/mcp-for-blender/ (the
# sdist's sha256 is listed under the release's files); the addon it bundles is
# re-pinned by `mcp-for-blender install-addon`-equivalent flows, and MODULES
# reads it from ${finalAttrs}/${python3.sitePackages}/blender_mcp/bundled/addon.py.
#
# Deps are just mcp + httpx (METADATA of 2.2.7); both live in nixpkgs
# python3Packages at satisfying versions (mcp 1.26.0 = the pin's exact floor).
# Tests are pytest suites against the addon's socket protocol (they need a
# live Blender), so doCheck is off.
python3.pkgs.buildPythonApplication rec {
  pname = "mcp-for-blender";
  version = "2.2.7";
  pyproject = true;

  src = fetchPypi {
    # The sdist keeps the import-name spelling (underscore); pypi only
    # normalises the dash for the wheel filename. This fetchPypi builds
    # mirror://pypi/<head>/<pname>/<pname>-<version>.tar.gz verbatim.
    pname = "mcp_for_blender";
    inherit version;
    hash = "sha256-CPh7Vjyb4NjTKCtJ5pHhXE1VbCdpicS535jLDMnliM4=";
  };

  build-system = with python3.pkgs; [
    setuptools
    wheel
  ];

  dependencies = with python3.pkgs; [
    mcp
    httpx
  ];

  doCheck = false;

  meta = {
    description = "MCP server for Blender (relays tools to the Blender addon's socket)";
    homepage = "https://github.com/ahujasid/blender-mcp";
    license = lib.licenses.mit;
    mainProgram = "mcp-for-blender";
  };
}
