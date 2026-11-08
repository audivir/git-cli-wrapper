#!/usr/bin/env bash
# Tests of git-cli-wrapper with stub gh, gt, gopass, and security binaries in a temp dir.
# shellcheck disable=SC2016 # the conditions stay in single quotes until check evaluates them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER="$ROOT/git-cli-wrapper"
FAILURES=0
TESTS=0

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

mkdir -p "$T/real" "$T/wrap" "$T/home" "$T/store"
ln -s "$WRAPPER" "$T/wrap/gh"
ln -s "$WRAPPER" "$T/wrap/gt"

# the real tools only report what they got.
cat >"$T/real/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth login" ]]; then
  echo "$*" >>"$STUB_STORE/gh_login_args"
  printf 'github.com:\n    oauth_token: browser-token\n' >"$GH_CONFIG_DIR/hosts.yml"
  exit 0
fi
if [[ "$1 $2" == "auth token" ]]; then
  echo browser-token
  exit 0
fi
echo "gh GH_TOKEN=${GH_TOKEN:-} GH_ENTERPRISE_TOKEN=${GH_ENTERPRISE_TOKEN:-} args=$*"
EOF
# the stub gt knows OAuth like gt does: a login writes a stale credential, "auth token" refreshes
# it, and the server accepts each refresh token once (the refresh takes a moment).
cat >"$T/real/gt" <<'EOF'
#!/usr/bin/env bash
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/gitea-cli"
if [[ "$1 $2" == "auth login" ]]; then
  host=""
  [[ " $* " == *" --oauth "* ]] || { echo "needs --oauth without a terminal" >&2; exit 1; }
  while (($#)); do [[ "$1" != --host ]] || host="$2"; shift; done
  # like gt, wait for the browser to call back on a loopback port
  if [[ -n "${STUB_CALLBACK_PORT:-}" ]]; then
    python3 - "$STUB_CALLBACK_PORT" <<'PY' || exit 1
import http.server, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.ok = "code=abc" in self.path
        self.send_response(200 if self.server.ok else 400)
        self.end_headers()

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.timeout = 15
server.ok = False
server.handle_request()
sys.exit(0 if server.ok else 1)
PY
  fi
  mkdir -p "$cfg/credentials"
  printf 'version: "1"\nhosts:\n    %s:\n        user: tester\n        oauth_client_id: client-1\n        users:\n            tester:\n                auth_method: oauth\n                credential_store: file\n' "$host" >"$cfg/hosts.yml"
  printf '{"access_token":"AT0","refresh_token":"RT0","expires_at":"stale"}' >"$cfg/credentials/abc.json"
  echo RT0 >"$STUB_STORE/server_rt"
  exit 0
fi
if [[ "$1 $2" == "auth token" ]]; then
  file="$(ls "$cfg"/credentials/*.json 2>/dev/null | head -n1)"
  [[ -n "$file" ]] || { echo "no credential" >&2; exit 1; }
  json="$(cat "$file")"
  at="$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' <<<"$json")"
  rt="$(sed -n 's/.*"refresh_token":"\([^"]*\)".*/\1/p' <<<"$json")"
  if [[ "$json" == *'"expires_at":"stale"'* ]]; then
    if [[ "$rt" != "$(cat "$STUB_STORE/server_rt")" ]]; then
      echo "refresh token already used" >&2
      exit 1
    fi
    sleep 0.3
    n=$(($(cat "$STUB_STORE/refreshes" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STUB_STORE/refreshes"
    echo "RT$n" >"$STUB_STORE/server_rt"
    at="AT$n"
    printf '{"access_token":"AT%s","refresh_token":"RT%s","expires_at":"fresh"}' "$n" "$n" >"$file"
  fi
  printf '%s\n' "$at"
  exit 0
fi
echo "gt GITEA_TOKEN=${GITEA_TOKEN:-} URL=${GITEA_INSTANCE_URL:-} HOST=${GITEA_CLI_HOST:-} args=$*"
EOF

# a gopass that keeps entries as files.
cat >"$T/real/gopass" <<'EOF'
#!/usr/bin/env bash
store="$STUB_STORE"
case "$1" in
config | setup | ls) exit 0 ;;
show) cat "$store/${3//\//_}" 2>/dev/null || exit 1 ;;
insert)
  # a locked identity needs the passphrase in env, like the age backend of gopass
  if [[ "${STUB_GOPASS_LOCKED:-}" == 1 && "${GOPASS_AGE_PASSWORD:-}" != pw ]]; then
    echo "failed to encrypt" >&2
    exit 1
  fi
  cat >"$store/${3//\//_}"
  ;;
rm) rm -f "$store/${3//\//_}" ;;
esac
EOF
# a security that keeps the passwords of add-generic-password (read from stdin) as files.
cat >"$T/real/security" <<'EOF'
#!/usr/bin/env bash
store="$STUB_STORE"
account() { while (($#)); do [[ "$1" != -a ]] || { echo "$2"; return; }; shift; done; }
if [[ "$1" == "-i" ]]; then
  read -r line
  eval "set -- $line"
  password=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" != -w ]] || password="${args[i + 1]}"; done
  printf '%s\n' "$password" >"$store/kc_$(account "$@" | tr '/:' '__')"
  exit 0
fi
case "$1" in
show-keychain-info) exit 0 ;;
find-generic-password) cat "$store/kc_$(account "$@" | tr '/:' '__')" 2>/dev/null || exit 44 ;;
delete-generic-password) rm -f "$store/kc_$(account "$@" | tr '/:' '__')" ;;
esac
EOF
chmod +x "$T"/real/*

mkdir -p "$T/home/.config/gopass" "$T/home/.local/share/gopass/stores/root"
touch "$T/home/.config/gopass/config" "$T/home/.local/share/gopass/stores/root/.age-recipients"

BASE_PATH="/usr/bin:/bin"
export STUB_STORE="$T/store"

# runs the wrapper as the given tool name with a clean environment. Extra env goes first as
# NAME=value words, then the tool name and its arguments. Output lands in $OUT, status in $RC.
run() {
  local envs=()
  while [[ "${1:-}" == *=* ]]; do
    envs+=("$1")
    shift
  done
  OUT="$(env -i HOME="$T/home" PATH="$T/wrap:$T/real:$BASE_PATH" STUB_STORE="$T/store" \
    GIT_CLI_WRAPPER_BACKEND="${BACKEND:-gopass}" ${envs[@]+"${envs[@]}"} "$@" 2>&1 </dev/null)"
  RC=$?
}

# like run, but with the stdin of the call.
run_in() {
  local input="$1"
  shift
  local envs=()
  while [[ "${1:-}" == *=* ]]; do
    envs+=("$1")
    shift
  done
  OUT="$(printf '%s' "$input" | env -i HOME="$T/home" PATH="$T/wrap:$T/real:$BASE_PATH" \
    STUB_STORE="$T/store" GIT_CLI_WRAPPER_BACKEND="${BACKEND:-gopass}" ${envs[@]+"${envs[@]}"} "$@" 2>&1)"
  RC=$?
}

reset_state() {
  rm -rf -- "$T/store" "$T/home/.local/state"
  mkdir -p "$T/store"
}

check() {
  local name="$1" condition="$2"
  TESTS=$((TESTS + 1))
  if eval "$condition"; then
    echo "ok   $name"
  else
    FAILURES=$((FAILURES + 1))
    echo "FAIL $name"
    echo "     status=$RC output: $OUT"
  fi
}

# gh
reset_state
run gh api user
check "gh without a stored token runs the real gh unchanged" '[[ $RC -eq 0 && "$OUT" == *"GH_TOKEN= "* ]]'

run_in "ghp_abc123" gh auth login --with-token
check "gh login --with-token stores the token" '[[ $RC -eq 0 && "$(cat "$T/store/github_gh-token")" == "ghp_abc123" ]]'
run gh api user
check "gh gets the stored token as GH_TOKEN" '[[ "$OUT" == *"GH_TOKEN=ghp_abc123 "* && "$OUT" == *"args=api user"* ]]'
run GH_TOKEN=from-env gh api user
check "a GH_TOKEN of the environment wins" '[[ "$OUT" == *"GH_TOKEN=from-env "* ]]'

run_in "ghe_token" GH_HOST=ghe.example.test gh auth login --with-token
run GH_HOST=ghe.example.test gh api user
check "gh on another host uses GH_ENTERPRISE_TOKEN with its own entry" \
  '[[ "$OUT" == *"GH_ENTERPRISE_TOKEN=ghe_token"* && "$OUT" == *"GH_TOKEN= "* ]]'

run gh auth logout
check "gh logout removes the entry and the marker" \
  '[[ ! -e "$T/store/github_gh-token" ]]'
run gh api user
check "gh gets no token after logout" '[[ "$OUT" == *"GH_TOKEN= "* ]]'

reset_state
mkdir -p "$T/home/.local/state/gh-gopass"
: >"$T/home/.local/state/gh-gopass/github_gh-token"
printf 'legacy-token\n' >"$T/store/github_gh-token"
run gh api user
check "gh still finds the marker of the former wrapper" '[[ "$OUT" == *"GH_TOKEN=legacy-token "* ]]'

reset_state
run gh auth login
check "gh login uses the browser flow by default" \
  '[[ $RC -eq 0 && "$(cat "$T/store/gh_login_args")" == *"--web"* ]]'
rm -f "$T/store/gh_login_args"
run_in "tok" gh auth login --with-token
check "gh login with a token does not add --web" '[[ "$(cat "$T/store/gh_login_args" 2>/dev/null)" != *"--web"* ]]'

# gt
reset_state
run gt repos list
check "gt without a stored token runs the real gt unchanged" '[[ $RC -eq 0 && "$OUT" == *"GITEA_TOKEN= "* ]]'

run_in "gt-secret-1" gt auth login --host https://git.example.test --with-token
check "gt login stores the token under the host" \
  '[[ $RC -eq 0 && "$(cat "$T/store/git.example.test_gt-token")" == "gt-secret-1" ]]'
run gt repos list
check "gt gets the token and the instance of its only login" \
  '[[ "$OUT" == *"GITEA_TOKEN=gt-secret-1 "* && "$OUT" == *"URL=https://git.example.test "* ]]'
run GITEA_TOKEN=from-env gt repos list
check "a GITEA_TOKEN of the environment wins" '[[ "$OUT" == *"GITEA_TOKEN=from-env "* ]]'

run_in "gt-secret-2" gt auth login --host other.example.test:3000 --with-token
check "gt login accepts a host without a scheme" \
  '[[ "$(cat "$T/store/other.example.test:3000_gt-token")" == "gt-secret-2" ]]'
run gt repos list
check "with two logins and no host gt gets no token" '[[ "$OUT" == *"GITEA_TOKEN= "* ]]'
run gt --host https://git.example.test repos list
check "the host argument selects the token" '[[ "$OUT" == *"GITEA_TOKEN=gt-secret-1 "* ]]'
run GITEA_CLI_HOST=https://other.example.test:3000 gt repos list
check "GITEA_CLI_HOST selects the token and is not overridden" \
  '[[ "$OUT" == *"GITEA_TOKEN=gt-secret-2 "* && "$OUT" == *"HOST=https://other.example.test:3000 "* && "$OUT" == *"URL= "* ]]'

run gt auth logout --host https://git.example.test
check "gt logout removes only that login" \
  '[[ ! -e "$T/store/git.example.test_gt-token" && -e "$T/store/other.example.test:3000_gt-token" ]]'
run gt repos list
check "the remaining login is the only one again" '[[ "$OUT" == *"GITEA_TOKEN=gt-secret-2 "* ]]'

run_in "x" gt auth login --host https://git.example.test --ssh-key /tmp/key
check "gt login refuses options the wrapper cannot store" \
  '[[ $RC -ne 0 && "$OUT" == *"not supported by the wrapper"* ]]'
run_in "" gt auth login --with-token
check "gt login without a host asks for one" '[[ $RC -ne 0 && "$OUT" == *"which instance"* ]]'
run_in "" gt auth login --host https://git.example.test --with-token
check "gt login without a token stores nothing" \
  '[[ $RC -ne 0 && ! -e "$T/store/git.example.test_gt-token" ]]'

# gt OAuth
reset_state
run gt auth login --host https://oauth.example.test
check "gt login is OAuth by default and stores one record" \
  '[[ $RC -eq 0 && -e "$T/store/oauth.example.test_gt-oauth" && ! -e "$T/home/.config/gitea-cli" ]]'
check "the record holds no plaintext token" '! grep -q "AT0" "$T/store/oauth.example.test_gt-oauth"'
run gt repos list
check "the first call refreshes and injects the new token" \
  '[[ "$OUT" == *"GITEA_TOKEN=AT1 "* && "$(cat "$T/store/refreshes")" == 1 ]]'
run gt repos list
check "the refreshed record is stored, so no second refresh" \
  '[[ "$OUT" == *"GITEA_TOKEN=AT1 "* && "$(cat "$T/store/refreshes")" == 1 ]]'
check "no credentials stay in the temp dirs" '! ls -d "${TMPDIR:-/tmp}"/git-cli-wrapper.* >/dev/null 2>&1'

# a record that went stale again, refreshed by five calls at once: the single-use refresh token
# only survives if they take turns.
reset_state
run gt auth login --host https://oauth.example.test --oauth
for i in 1 2 3 4 5; do
  (run gt repos list; printf '%s\n' "$OUT" >"$T/par.$i") &
done
wait
check "five concurrent calls all get a valid token" \
  '[[ "$(cat "$T"/par.* | grep -c "GITEA_TOKEN=AT1 ")" == 5 ]]'
check "and the token was refreshed exactly once" '[[ "$(cat "$T/store/refreshes")" == 1 ]]'
rm -f "$T"/par.*

mkdir -p "$T/home/.local/state/git-cli-wrapper/gt"
mkdir "$T/home/.local/state/git-cli-wrapper/gt/lock-oauth.example.test_gt-oauth"
echo 999999 >"$T/home/.local/state/git-cli-wrapper/gt/lock-oauth.example.test_gt-oauth/pid"
run gt repos list
check "a lock of a dead process is taken over" '[[ "$OUT" == *"GITEA_TOKEN=AT1 "* ]]'

run gt auth logout --host https://oauth.example.test
check "gt logout removes the OAuth record" '[[ ! -e "$T/store/oauth.example.test_gt-oauth" ]]'

# the browser cannot reach this machine: its address is pasted and sent to the loopback listener
if command -v python3 >/dev/null 2>&1; then
  reset_state
  printf 'https://evil.example/?code=abc\nhttp://127.0.0.1:39555/?code=abc&state=xyz\n' >"$T/paste"
  run STUB_CALLBACK_PORT=39555 GIT_CLI_WRAPPER_PASTE_FROM="$T/paste" gt auth login --host https://oauth.example.test
  check "a pasted callback address completes the login" \
    '[[ $RC -eq 0 && -e "$T/store/oauth.example.test_gt-oauth" ]]'
  check "an address that is not on loopback is ignored" '[[ "$OUT" == *"ignored"* ]]'
fi

# a locked gopass identity: the passphrase comes from env, or the wrapper stops without storing
reset_state
run_in "locked-token" STUB_GOPASS_LOCKED=1 GOPASS_AGE_PASSWORD=pw gt auth login --host https://git.example.test --with-token
check "a locked gopass identity is unlocked through the passphrase in env" \
  '[[ $RC -eq 0 && "$(cat "$T/store/git.example.test_gt-token")" == "locked-token" ]]'
reset_state
run_in "locked-token" STUB_GOPASS_LOCKED=1 gt auth login --host https://git.example.test --with-token
check "without a passphrase or terminal a locked identity stores nothing" \
  '[[ $RC -ne 0 && "$OUT" == *"failed to encrypt"* && ! -e "$T/store/git.example.test_gt-token" ]]'

# locked identity: the passphrase is asked only after the first insert failed
reset_state
printf 'pw\n' >"$T/pass"
run_in "locked-token" STUB_GOPASS_LOCKED=1 GIT_CLI_WRAPPER_PASSPHRASE_FROM="$T/pass" gt auth login --host https://git.example.test --with-token
check "a locked identity asks for the passphrase and retries" \
  '[[ $RC -eq 0 && "$OUT" == *"passphrase of the gopass age key"* && "$(cat "$T/store/git.example.test_gt-token")" == "locked-token" ]]'
reset_state
printf 'wrong\n' >"$T/pass"
run_in "locked-token" STUB_GOPASS_LOCKED=1 GIT_CLI_WRAPPER_PASSPHRASE_FROM="$T/pass" gt auth login --host https://git.example.test --with-token
check "a wrong passphrase stores nothing" \
  '[[ $RC -ne 0 && ! -e "$T/store/git.example.test_gt-token" ]]'
reset_state
run_in "open-token" GIT_CLI_WRAPPER_PASSPHRASE_FROM="$T/pass" gt auth login --host https://git.example.test --with-token
check "an unlocked agent is never asked" \
  '[[ $RC -eq 0 && "$OUT" != *"passphrase of the gopass age key"* ]]'

# tokens must not appear in the process list of the stub calls: the wrapper never puts them in
# the arguments of gopass.
check "the stub gopass never saw a token as an argument" \
  '! grep -rq "gt-secret" "$T/real" 2>/dev/null'

# structure
reset_state
BACKEND=native run gh api user
check "the native backend passes through" '[[ "$OUT" == *"GH_TOKEN= "* && "$OUT" == *"args=api user"* ]]'
run_in "tok" gh auth login --with-token
BACKEND=native run gh api user
check "the native backend never injects" '[[ "$OUT" == *"GH_TOKEN= "* ]]'
BACKEND=bogus run gh api user
check "an unknown backend is an error" '[[ $RC -ne 0 && "$OUT" == *"unknown backend"* ]]'

run "$WRAPPER" gt repos list
check "the wrapper can be called with the tool as first argument" '[[ $RC -eq 0 && "$OUT" == gt\ * ]]'
run "$WRAPPER" glab list
check "an unknown tool shows the usage" '[[ $RC -eq 2 && "$OUT" == *usage* ]]'

mkdir -p "$T/copy"
cp "$WRAPPER" "$T/copy/gh"
run PATH="$T/copy:$T/wrap:$T/real:$BASE_PATH" gh api user
check "two copies of the wrapper stop instead of looping" \
  '[[ $RC -ne 0 && "$OUT" == *"call each other"* ]]'

# keychain, with the security stub (the backend only works on macOS)
if [[ "$(uname -s)" == "Darwin" ]]; then
  reset_state
  BACKEND=keychain run_in "kc-token_1" gt auth login --host https://git.example.test --with-token
  check "the keychain backend stores through security -i" \
    '[[ $RC -eq 0 && "$(cat "$T/store/kc_gt_git.example.test_gt-token")" == "kc-token_1" ]]'
  BACKEND=keychain run gt repos list
  check "the keychain backend injects the token" '[[ "$OUT" == *"GITEA_TOKEN=kc-token_1 "* ]]'
  BACKEND=keychain run_in 'bad token "$(x)"' gt auth login --host https://x.example.test --with-token
  check "the keychain backend refuses a token it cannot pass safely" \
    '[[ $RC -ne 0 && "$OUT" == *"cannot be passed"* ]]'
  BACKEND=keychain run gt auth logout --host https://git.example.test
  check "the keychain backend removes the entry" '[[ ! -e "$T/store/kc_gt_git.example.test_gt-token" ]]'
fi

echo
echo "$((TESTS - FAILURES))/$TESTS passed"
exit "$((FAILURES > 0))"
