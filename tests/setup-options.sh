#!/usr/bin/env bash
set -u
# setup.sh options: a typo must stop the wizard before it installs or asks
# anything (it used to be ignored). Only the option parser is run here - the
# part of setup.sh up to the end of its 'while' loop - so nothing is installed.
repo=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*"; exit 1; }
parser=$(sed -n '1,/^done$/p' "$repo/scripts/setup.sh")
printf '%s\n' "$parser" | grep -q -- '--update|-u)' || fail 'option parser not found in setup.sh'
home=$(mktemp -d); trap 'rm -rf "$home"' EXIT
run() { out=$(HOME=$home bash -c "$parser"$'\n''echo "PARSED update=$UPDATE_ONLY domain=$DOMAIN_ARG version=$WANT_VERSION"' setup.sh "$@" 2>&1); rc=$?; }

run --domian example.com
[ "$rc" -eq 2 ] || fail "unknown option: exit $rc, expected 2 ($out)"
case "$out" in *"Unknown option '--domian'"*"usage: setup.sh"*) ;; *) fail "unknown option: no clear message ($out)";; esac
case "$out" in *PARSED*) fail 'unknown option: the wizard went on';; esac
echo 'PASS: an unknown option stops setup.sh with the usage'

for opt in --domain --version; do
    run "$opt"
    [ "$rc" -eq 2 ] || fail "$opt without a value: exit $rc, expected 2"
    case "$out" in *"$opt needs a value"*) ;; *) fail "$opt without a value: no clear message ($out)";; esac
done
echo 'PASS: --domain and --version need a value'

run --help
[ "$rc" -eq 0 ] || fail "--help: exit $rc"
case "$out" in *'--update'*'--domain <domain>'*'--version X.Y.Z'*) ;; *) fail "--help does not list the options ($out)";; esac
case "$out" in *PARSED*) fail '--help: the wizard went on';; esac
echo 'PASS: --help lists the options and stops'

unset CLAUDE_PROXY_DOMAIN CLAUDE_PROXY_INSTALL_VERSION
run --update --domain example.com --version=2.13.3
[ "$rc" -eq 0 ] && [ "$out" = 'PARSED update=1 domain=example.com version=2.13.3' ] || fail "valid options: exit $rc ($out)"
run -u --domain=example.org --version 2.13.4
[ "$rc" -eq 0 ] && [ "$out" = 'PARSED update=1 domain=example.org version=2.13.4' ] || fail "valid options, other spellings: exit $rc ($out)"
run
[ "$rc" -eq 0 ] && [ "$out" = 'PARSED update=0 domain= version=' ] || fail "no options: exit $rc ($out)"
echo 'PASS: valid options are read as before'
