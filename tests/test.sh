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
  printf 'github.com:\n    oauth_token: browser-token\n' >"$GH_CONFIG_DIR/hosts.yml"
  exit 0
fi
if [[ "$1 $2" == "auth token" ]]; then
  echo browser-token
  exit 0
fi
echo "gh GH_TOKEN=${GH_TOKEN:-} GH_ENTERPRISE_TOKEN=${GH_ENTERPRISE_TOKEN:-} args=$*"
EOF
cat >"$T/real/gt" <<'EOF'
#!/usr/bin/env bash
echo "gt GITEA_TOKEN=${GITEA_TOKEN:-} URL=${GITEA_INSTANCE_URL:-} HOST=${GITEA_CLI_HOST:-} args=$*"
EOF

# a gopass that keeps entries as files.
cat >"$T/real/gopass" <<'EOF'
#!/usr/bin/env bash
store="$STUB_STORE"
case "$1" in
config | setup | ls) exit 0 ;;
show) cat "$store/${3//\//_}" 2>/dev/null || exit 1 ;;
insert) cat >"$store/${3//\//_}" ;;
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

run_in "x" gt auth login --host https://git.example.test --oauth
check "gt login refuses OAuth, which the wrapper cannot store" \
  '[[ $RC -ne 0 && "$OUT" == *"not supported by the wrapper"* ]]'
run_in "" gt auth login --with-token
check "gt login without a host asks for one" '[[ $RC -ne 0 && "$OUT" == *"which instance"* ]]'
run_in "" gt auth login --host https://git.example.test --with-token
check "gt login without a token stores nothing" \
  '[[ $RC -ne 0 && ! -e "$T/store/git.example.test_gt-token" ]]'

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
