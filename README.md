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
gh auth login                    # browser or device flow, the token goes to the backend
gh auth login --with-token < f   # store a token you already have
gh auth logout
gt auth login --host https://git.example.com   # asks for the token, hidden
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

Only tokens are managed: `gt auth login` reads the token from a terminal prompt or stdin and
refuses `--oauth`, SSH key, and client certificate options, because the wrapper only stores
tokens. The instance is selected by `--host`, `GITEA_CLI_HOST`, or `GITEA_INSTANCE_URL`. If none
is given, the only instance with a stored token is used. `gt auth login` itself needs an explicit
instance.

## Backends

Set `GIT_CLI_WRAPPER_BACKEND`:

| Value | Storage |
| ---------- | ------------------------------------------------------------------ |
| `gopass` | gopass with age, entry `github/gh-token`, `<host>/gh-token`, `<host>/gt-token` |
| `keychain` | macOS Keychain, service `git-cli-wrapper`, account `<tool>:<entry>` |
| `native` | no wrapping, the tool keeps its own storage |
| `auto` | `native` on macOS, `gopass` elsewhere (default) |

- `GIT_CLI_WRAPPER_KEYCHAIN` selects another keychain file than the default one.
- `GIT_CLI_WRAPPER_AGENT_TIMEOUT` sets how long the age agent of gopass stays unlocked, in seconds
  (default 3600).
- `GH_TOKEN_ENTRY` overrides the gopass entry for `github.com`.
- With `native` on macOS, the wrapper only unlocks the keychain, so `gh` and `gt` do not fall back
  to plaintext files while it is locked.

## Tests

```bash
bash tests/test.sh
```

The tests use stub `gh`, `gt`, `gopass`, and `security` binaries.

## License

MIT
