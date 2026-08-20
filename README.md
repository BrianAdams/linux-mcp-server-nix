# linux-mcp-server-nix

> **⚠️ Work in progress.** This flake builds and runs, but it is early and
> unstable: the version pin, the SSH/container conventions, and the layout may
> all change without notice. Nothing here is a supported release yet.

A Nix flake packaging [`linux-mcp-server`](https://github.com/rhel-lightspeed/linux-mcp-server)
(Apache-2.0, Red Hat / RHEL Lightspeed) — a read-only MCP server for Linux
diagnostics, driven either locally or over SSH.

Upstream is **not in nixpkgs** (neither top-level nor `python3Packages`), which
is why this flake exists.

The setup it was built for runs the server *inside* an agent container, reaching
the Fedora Silverblue host over SSH — so an agent can diagnose the host without
installing anything on the host itself.

```
container (this flake)                    host
┌────────────────────────┐                ┌───────────────────┐
│ claude-code            │                │                   │
│   └─ linux-mcp-server  │──── SSH ──────▶│ sshd  (Silverblue)│
│        (asyncssh)      │  agent auth    │  ps/systemctl/…   │
└────────────────────────┘                └───────────────────┘
      host.containers.internal → 169.254.1.2 (pasta host-loopback mapping)
```

Nothing about the flake itself requires a container — that is just the
environment the gotchas below were found in.

## Quick start

```bash
nix build .#linux-mcp-server        # or .#linux-mcp-server-gssapi for Kerberos
nix run .# -- --version             # -> 1.5.0
nix profile install .#              # e.g. on the host itself
```

## Layout

| File | Role |
|---|---|
| `flake.nix` | `packages.default` / `.linux-mcp-server` / `.linux-mcp-server-gssapi`, `apps.default`, `overlays.default`, `checks`, `formatter` |
| `package.nix` | the derivation — pinned PyPI sdist, `withGssapi` flag |
| `devenv.local.nix` | puts the binary on PATH in the devenv shell, via the same `package.nix` |
| `.mcp.json` | registers the server with Claude Code as `linux` |

`devenv.local.nix` is the extension point: the `devenv.nix` in this directory is
bind-mounted read-only from `devenv-base` and must not be edited (it is
gitignored for that reason). devenv auto-imports `devenv.local.nix` alongside
it, so the baseline toolchain stays intact.

## Configuration

`.mcp.json` carries the authoritative environment:

| Variable | Value | Why |
|---|---|---|
| `LINUX_MCP_USER` | remote login user | needed because a `~/.ssh/config` `Host` alias is not possible here (see below) |
| `LINUX_MCP_KNOWN_HOSTS_PATH` | `~/.ssh/known_hosts.container` | the real `known_hosts` is read-only |
| `LINUX_MCP_LOG_DIR` | `~/.local/share/linux-mcp-server/logs` | keeps logs out of the synthetic HOME |
| `SSH_AUTH_SOCK` | `/run/ssh-agent.sock` | forwarded agent supplies the keys |
| `HOME` | `~/.local/share/linux-mcp-server/home` | **must** be a directory with no `.ssh/config` — see below |

Tool calls pass `host="host.containers.internal"`.

Host-key verification stays **enabled** throughout. Nothing here sets
`--no-verify-host-keys`, and the flake does not need it.

`.mcp.json` is read at Claude Code startup and uses the bare name
`linux-mcp-server`, so Claude Code must be launched from a devenv shell. If you
launch it elsewhere, substitute an absolute path.

## Gotchas

These are the things that actually cost time. Read them before changing anything.

### The published release does not match `main`

`main`'s `pyproject.toml` lists `httpx`; the released **1.5.0 requires
`litellm>=1.80.16` and no `httpx`**. Building against the repo's dependency list
fails in `pythonRuntimeDepsCheckHook` with `litellm not installed`.

**When bumping the version, read the sdist's `PKG-INFO`, not the repo:**

```bash
curl -sSL https://pypi.org/pypi/linux-mcp-server/json | jq -r '.info.version'
tar xzf linux_mcp_server-<v>.tar.gz -O linux_mcp_server-<v>/PKG-INFO \
  | grep -E '^(Requires-Dist|Requires-Python|Provides-Extra)'
```

### A read-only `~/.ssh/config` breaks asyncssh

**This is a property of the container, not of the package**, and it will recur
in any container that mounts `~/.ssh` this way.

`~/.ssh/known_hosts` and `~/.ssh/config` are individually bind-mounted
read-only, while the `~/.ssh` *directory* is writable — so new files can be
created there but those two cannot be edited.

`~/.ssh/config` contains `Host * / IdentityFile ~/.ssh/id_rsa`, and that file
does not exist in the container. asyncssh reads the client config and **hard
fails**:

```
Error calling tool 'get_system_information': [Errno 2] No such file or directory: '/home/<user>/.ssh/id_rsa'
```

Two consequences:

- The server is given its own `HOME` pointing at an empty directory, so asyncssh
  finds no `~/.ssh/config` at all and falls through to the forwarded agent.
  `LINUX_MCP_SEARCH_FOR_SSH_KEY=false` does **not** fix this — only a clean
  `HOME` does.
- Host aliases cannot be added to `~/.ssh/config`, hence `LINUX_MCP_USER` plus
  the literal host `host.containers.internal`. Making the mount writable on the
  podman side would allow proper per-host config blocks instead.

### `fakeredis` upper bound is relaxed

Upstream pins `fakeredis<2.35`; nixpkgs ships 2.36.x, so `package.nix` sets
`pythonRelaxDeps = [ "fakeredis" ]`. The pin exists only for a `pydocket`
incompatibility affecting the optional gatekeeper backend, not the diagnostic
tools.

### Eight tests are deselected

`disabledTestPaths` / `disabledTests` drop tests that shell out to live
`ps` / `systemctl` / `journalctl` / `top` / `free` / `findmnt` / `hostname`,
none of which exist in the Nix build sandbox. `preCheck` also sets `HOME`,
because four other tests write to it and Nix points `HOME` at
`/homeless-shelter`.

Result: **555 passed, 8 deselected, 0 failed.** Nothing SSH-related is skipped —
in SSH mode those commands run on the target, not in the sandbox.

### nixpkgs is pinned to devenv's revision

`flake.nix` pins `54ba4bcec4043e72a4006d825e0d7aff5562008f`, the same revision
devenv resolves in this sandbox, so the Python closure is already in the store
and nothing rebuilds. `nix flake update` moves it, at the cost of a rebuild.

Closure is ~794 MB; `litellm` dominates.

## One-time host setup

Fedora Workstation and Silverblue ship `sshd` **disabled**. The steps below
authorize your own login user, which is the shortest path to a working
server. For anything beyond a scratch setup, use the
[least-privilege diagnostics account](#least-privilege-diagnostics-account)
instead. On the host:

```bash
sudo systemctl enable --now sshd

# authorize a key already loaded in the agent
ssh-add -L | grep '<key-comment>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
restorecon -R ~/.ssh
```

`restorecon` matters: on Silverblue an `authorized_keys` with the wrong SELinux
label is ignored silently by sshd, which looks exactly like a rejected key.

Note this is **authorizing** a public key (`authorized_keys`), not `ssh-add` —
the keys are already in the forwarded agent.

Then record the host key. Verify the fingerprint out-of-band first, since the
server has no interactive prompt to accept an unknown key:

```bash
# on the host
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# in the container, only after the fingerprint matches
ssh-keyscan -t ed25519 169.254.1.2 \
  | awk '/^[^#]/ && NF>=3 {printf "169.254.1.2,host.containers.internal %s %s\n", $2, $3}' \
  > ~/.ssh/known_hosts.container
chmod 600 ~/.ssh/known_hosts.container
```

## Least-privilege diagnostics account

The setup above authorizes your own login user, which is convenient but hands
the agent everything you can do. The better arrangement — and the one upstream's
security docs recommend — is a dedicated account with **no `sudo` at all**,
where log access comes from group membership instead.

Silverblue is immutable at the OS-image level, but `/etc` (users, groups,
sudoers) is a normal writable overlay, so user management works exactly like any
Fedora system — no `rpm-ostree` involved.

### 1. Create the account

```bash
sudo useradd -m -s /bin/bash diag
```

Use a real shell. **`/sbin/nologin` and `/usr/bin/false` break every tool
call** — the server runs `ssh diag@host "some command"`, which invokes the login
shell with `-c`, and `nologin` refuses that exactly as it refuses an interactive
login.

### 2. Grant log access by group, not by sudo

```bash
sudo usermod -a -G adm,systemd-journal diag
```

| Group | Grants |
|---|---|
| `systemd-journal` | reading `journalctl` output |
| `adm` | reading the traditional log files under `/var/log` |

Membership takes effect on the next SSH session; no reboot needed for a service
account.

**The ceiling on this approach**, worth knowing before you debug a confusing
empty result: a few things still need root even with those groups —
audit-backend journal queries (`get_journal_logs` with `transport="audit"`),
full `ss`/netstat output showing every process, and `dmidecode`-based hardware
info. Those tools return partial output rather than failing loudly.

That is usually the right trade for a read-only diagnostics account. If you
genuinely need them, scope passwordless sudo to those exact binaries and nothing
more (`visudo -f /etc/sudoers.d/diag`):

```
diag ALL=(root) NOPASSWD: /usr/bin/journalctl, /usr/sbin/ss, /usr/sbin/dmidecode
```

### 3. Lock the account to key-only auth

```bash
sudo passwd -l diag
```

### 4. Install a dedicated key

On the machine running `linux-mcp-server`:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_diag -C "diag@linux-mcp-server"
ssh-copy-id -i ~/.ssh/id_ed25519_diag.pub diag@<host>
```

On Silverblue, run `restorecon -R /home/diag/.ssh` afterwards — see the SELinux
note under [One-time host setup](#one-time-host-setup).

### 5. Restrict what the key can do

The server only ever runs non-interactive exec commands, so it needs no pty, no
forwarding, and no X11. Prefix the key in `/home/diag/.ssh/authorized_keys`:

```
no-pty,no-port-forwarding,no-x11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... diag@linux-mcp-server
```

### 6. Point the server at the account

Where a writable `~/.ssh/config` is available, a host block is cleaner than
`LINUX_MCP_USER`, since it scales to more than one target:

```
Host diag-host
  HostName silverblue-host.example.com
  User diag
  IdentityFile ~/.ssh/id_ed25519_diag
```

In the container described above this is **not** possible — `~/.ssh/config` is
mounted read-only, which is precisely why `.mcp.json` sets `LINUX_MCP_USER` and
passes a literal hostname. Set `LINUX_MCP_USER=diag` there instead.

Verify passwordless access, and record the host key first (same procedure as
above — the server has no prompt to accept an unknown key):

```bash
ssh diag@<host> 'echo success'
```

### 7. Whitelist the readable log files

`read_log_file` refuses every path that is not explicitly listed. This is a
second, independent restriction layered on top of the Unix permissions, so keep
the list narrow:

```json
"env": {
  "LINUX_MCP_ALLOWED_LOG_PATHS": "/var/log/messages,/var/log/secure,/var/log/audit/audit.log"
}
```

Together — group-based log access instead of sudo, a locked key-only account, a
restricted `authorized_keys` entry, and a curated log whitelist — this gives the
account everything the read-only tools need without ever handing out root.

## Verifying

```bash
nix flake check                                   # all checks passed
nix build .#linux-mcp-server                      # 555 passed, 8 deselected
nix run .# -- --version                           # 1.5.0

# SSH reachability, strict host-key checking on
SSH_AUTH_SOCK=/run/ssh-agent.sock ssh -o BatchMode=yes \
  -o UserKnownHostsFile=~/.ssh/known_hosts.container \
  <user>@host.containers.internal 'echo ok; systemctl is-system-running'
```

End-to-end, the server exposes **19 tools** and returns live host data
(`get_system_information` → hostname, Fedora Silverblue 44).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No such file or directory: '.../id_rsa'` | `HOME` not pointed at the clean directory; asyncssh is reading the real `~/.ssh/config` |
| `Permission denied (publickey…)` | key not in the host's `authorized_keys`, or wrong SELinux label — check `sudo journalctl -u sshd -n 20` |
| Connection refused on :22 | `sshd` not running on the host |
| `litellm not installed` at build | dependency list taken from `main` instead of the released sdist's `PKG-INFO` |
| Server missing in Claude Code | `.mcp.json` is read at startup, and needs `linux-mcp-server` on PATH from the devenv shell |

To confirm the pasta host mapping itself is working, `169.254.1.2:5355`
(systemd-resolved LLMNR) answers on a stock Fedora host — a useful signal that
traffic reaches the host and the problem is the specific service.

## License

The packaging in this repository (`flake.nix`, `package.nix`, and everything
else here) is [MIT](LICENSE) licensed.

The packaged software, [`linux-mcp-server`](https://github.com/rhel-lightspeed/linux-mcp-server),
is a separate work under Apache-2.0 and is not covered by this repository's
license.
