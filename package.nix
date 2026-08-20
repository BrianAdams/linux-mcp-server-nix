# linux-mcp-server — read-only Linux diagnostics over MCP, local or via SSH.
#
# Upstream: https://github.com/rhel-lightspeed/linux-mcp-server
# Docs:     https://rhel-lightspeed.github.io/linux-mcp-server/
{
  lib,
  python3Packages,
  fetchPypi,
  # Kerberos/GSSAPI SSH auth. Off by default — plain key or ssh-agent auth
  # needs nothing extra.
  withGssapi ? false,
}:

python3Packages.buildPythonApplication rec {
  pname = "linux-mcp-server";
  version = "1.5.0";
  pyproject = true;

  src = fetchPypi {
    # PyPI serves the sdist under the underscored name.
    pname = "linux_mcp_server";
    inherit version;
    hash = "sha256-mic1/RLS4bS86IZWu1P0HjB7Qr3KsykdIeqIq9GqSR4=";
  };

  # hatch-vcs reads the version out of git metadata, and an sdist has no .git.
  # setuptools_scm (which hatch-vcs delegates to) honours this env var.
  env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

  build-system = with python3Packages; [
    hatchling
    hatch-vcs
  ];

  # Upstream caps fakeredis <2.35 to dodge an incompatibility in pydocket, which
  # only affects the optional gatekeeper backend. nixpkgs ships 2.36.x.
  pythonRelaxDeps = [ "fakeredis" ];

  dependencies =
    with python3Packages;
    [
      asyncssh
      bcrypt # the asyncssh[bcrypt] extra
      fakeredis
      fastmcp
      litellm
      pydantic
      pydantic-settings
    ]
    ++ lib.optionals withGssapi [ gssapi ];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    pytest-mock
  ];

  # pyproject.toml's addopts pull in coverage and IPython's debugger, neither of
  # which belongs in a Nix build.
  pytestFlags = [
    "-o"
    "addopts="
  ];

  # Several tests write under $HOME, which the sandbox points at /homeless-shelter.
  preCheck = ''
    export HOME=$(mktemp -d)
  '';

  # These exercise the diagnostic tools against the live system, shelling out to
  # ps/systemctl/journalctl/top/free/findmnt/hostname. None of that exists in the
  # build sandbox. Irrelevant to SSH mode, where the commands run on the target.
  disabledTestPaths = [
    "tests/tools/test_processes.py"
    "tests/tools/test_services.py"
    "tests/tools/test_system_info.py"
  ];

  # Same reason: these run real commands through the local (non-SSH) executor.
  disabledTests = [
    "test_execute_command_local"
    "TestLocalTimeout"
  ];

  pythonImportsCheck = [ "linux_mcp_server" ];

  meta = {
    description = "MCP server for read-only Linux system administration, diagnostics, and troubleshooting";
    homepage = "https://github.com/rhel-lightspeed/linux-mcp-server";
    changelog = "https://github.com/rhel-lightspeed/linux-mcp-server/releases/tag/v${version}";
    license = lib.licenses.asl20;
    mainProgram = "linux-mcp-server";
    platforms = lib.platforms.linux;
  };
}
