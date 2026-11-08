# git-cli-wrapper

Keeps the tokens of `gh` and `gt` in gopass or the macOS Keychain instead of plaintext files.

One shell script wraps the GitHub CLI (`gh`) and the Gitea CLI (`gt`). It behaves as the tool it is
called as: link it under both names in a directory that comes before the real tools in `PATH`.
After `auth login`, the token lives in the backend, and every other call runs the real tool with
the token in its environment, so `hosts.yml` never holds it.

## Prerequisites

- `bash` 3.2 or newer
- `gh` and/or `gt` in `PATH`
- `gopass` with the age backend, for the `gopass` backend
- macOS and the `security` command, for the `keychain` backend

## Installation

```bash
git clone https://github.com/audivir/git-cli-wrapper
mkdir -p ~/.local/wrapper-bin
ln -s "$PWD/git-cli-wrapper/git-cli-wrapper" ~/.local/wrapper-bin/gh
ln -s "$PWD/git-cli-wrapper/git-cli-wrapper" ~/.local/wrapper-bin/gt
export PATH="$HOME/.local/wrapper-bin:$PATH"
```

The wrapper finds the real tool by skipping itself in `PATH`. It can also be called as
`git-cli-wrapper gh ...` or `git-cli-wrapper gt ...`.

## Usage

```bash
gh auth login                    # browser flow, the token goes to the backend
gh auth login --with-token < f   # store a token you already have
gh auth logout
gt auth login --host https://git.example.com   # OAuth in the browser
gt auth login --host https://git.example.com --with-token   # token from stdin or a hidden prompt
gt auth logout --host https://git.example.com
```

Everything else is passed to the real tool, with the stored token in `GH_TOKEN` (`github.com`),
`GH_ENTERPRISE_TOKEN` (other hosts), or `GITEA_TOKEN`. A token that is already set in the
environment wins.

### gh

`gh auth login` runs the real login in a temporary directory on a tmpfs (`$XDG_RUNTIME_DIR` or
`/dev/shm`), moves the token into the backend, and discards the directory. `gh auth status` reports
against a config without `hosts.yml`.

### gt

Two kinds of login are managed. The instance is selected by `--host`, `GITEA_CLI_HOST`, or
`GITEA_INSTANCE_URL`. If none is given, the only instance with a stored login is used, but
`gt auth login` itself needs an explicit instance.

- **Token**: `gt auth login --host <url> --with-token` reads the token from a hidden prompt or from stdin and
  stores it. `gt` gets it as `GITEA_TOKEN`.
- **OAuth** (the default): `gt auth login --host <url>` runs the real login in a temporary config dir
  and stores its whole record (access token, refresh token, expiry, client id) in the backend.
  OAuth tokens expire, so before every call the wrapper restores the record, lets `gt` refresh
  it, writes it back when it changed, and gives `gt` the access token as `GITEA_TOKEN`. This runs
  under a lock (`mkdir` based, a lock of a dead process is taken over, 60 seconds at most), so
  concurrent calls do not use the same single-use refresh token twice.

**No browser on this machine?** `gt` waits for the browser on `127.0.0.1:<port>` of the machine
it runs on, which a browser elsewhere cannot reach. Open the printed URL on another machine and
approve. The browser then fails to load a page at `http://127.0.0.1:<port>/?code=...&state=...`.
Paste that address into the terminal of the login. The wrapper sends the request to the port on
its own machine, and the login finishes as if the browser had reached it. This works in parallel
to the normal callback, so nothing needs to be chosen up front. Only addresses on `127.0.0.1` or
`localhost` are accepted.

`gt auth logout` removes the stored login from the backend, but the authorization stays valid in
Gitea, because neither `gt` nor Gitea offers a way to revoke it from a client. Revoke it at
`<instance>/user/settings/applications`. The wrapper prints that address after an OAuth logout.

`--ssh-*`, `--client-cert`, `--client-key`, `--header`, `--insecure`, and `--credential-store`
are refused. `gt auth status` and `gt auth token` ignore `GITEA_TOKEN`, so they do not see the
stored login.

## Proxy and certificates

`gh` and `gt` are Go programs. They use no PAC file and no system proxy settings, only
`HTTPS_PROXY` and `HTTP_PROXY`, and they trust the system roots plus `SSL_CERT_FILE`. If
[`curlp`](https://github.com/audivir/curlp) 0.1.1 or newer is in `PATH`, the wrapper asks it
(`curlp --curlp-env <url>`) for the instance of the call and sets `HTTPS_PROXY` and `HTTP_PROXY`
from the PAC, and `SSL_CERT_FILE` to the bundle with its additional certificates. `gh` on
`github.com` is looked up as `api.github.com`. Variables that are already set win, `socks4`
proxies are skipped because Go cannot use them, and `GIT_CLI_WRAPPER_CURLP=0` turns this off.
Without `curlp`, or with an older one, nothing changes.

## Backends

Set `GIT_CLI_WRAPPER_BACKEND`:

| Value | Storage |
| ---------- | ------------------------------------------------------------------ |
| `gopass` | gopass with age, entry `github/gh-token`, `<host>/gh-token`, `<host>/gt-token`, `<host>/gt-oauth` |
| `keychain` | macOS Keychain, service `git-cli-wrapper`, account `<tool>:<entry>` |
| `native` | no wrapping, the tool keeps its own storage |
| `auto` | `native` on macOS, `gopass` elsewhere (default) |

- `GIT_CLI_WRAPPER_KEYCHAIN` selects another keychain file than the default one.
- `GIT_CLI_WRAPPER_AGENT_TIMEOUT` sets how long the age agent of gopass stays unlocked, in seconds
  (default 3600).
- With `gopass`, a login asks for the passphrase of the age key only if the store cannot be written
  without it, for example when the agent is locked. `GOPASS_AGE_PASSWORD` gives it up front.
- `GH_TOKEN_ENTRY` overrides the gopass entry for `github.com`.
- With `native`, a login still defaults to the browser: `--web` is added for `gh` and `--oauth` for
  `gt`, unless the call names a method (`--with-token`, `--ssh-key`, ...).
- With `native` on macOS, the wrapper only unlocks the keychain, so `gh` and `gt` do not fall back
  to plaintext files while it is locked.

## Tests

```bash
bash tests/test.sh
```

The tests use stub `gh`, `gt`, `gopass`, and `security` binaries.

## License

MIT
