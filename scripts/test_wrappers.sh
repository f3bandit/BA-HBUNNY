#!/bin/sh

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }
info() { echo "[*] $*"; }

COLOR_DIR="/root/bb_updates/ssh_colors"

test_cmd_exists() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 wrapper exists: $(command -v "$1")"
    return 0
  else
    fail "$1 wrapper missing"
    return 1
  fi
}

test_run() {
  name="$1"
  shift
  if "$@" >/tmp/"$name".out 2>/tmp/"$name".err; then
    pass "$name ran successfully"
  else
    rc=$?
    fail "$name failed with exit code $rc"
    [ -s /tmp/"$name".err ] && sed -n '1,20p' /tmp/"$name".err
  fi
}

test_gohttp() {
  mkdir -p /tmp/gohttp-test
  echo ok > /tmp/gohttp-test/index.html

  if gohttp -p 8080 -d /tmp/gohttp-test >/tmp/gohttp.out 2>/tmp/gohttp.err; then
    pass "gohttp ran successfully"
  else
    rc=$?
    fail "gohttp failed with exit code $rc"
    [ -s /tmp/gohttp.err ] && sed -n '1,20p' /tmp/gohttp.err
  fi
}

echo "========== COLOR / PROFILE TESTS =========="

test_cmd_exists applytheme || true
test_cmd_exists reloadtheme || true

[ -f "$COLOR_DIR/.profile.backup" ] && pass "backup exists: $COLOR_DIR/.profile.backup" || fail "missing backup: $COLOR_DIR/.profile.backup"
[ -f "$COLOR_DIR/.profile.master" ] && pass "master profile exists: $COLOR_DIR/.profile.master" || fail "missing master profile: $COLOR_DIR/.profile.master"

grep -q 'PS1=' /root/.profile 2>/dev/null && pass ".profile contains PS1" || fail ".profile missing PS1"

grep -q 'LS_COLORS=' /root/.profile 2>/dev/null && pass ".profile contains LS_COLORS" || info ".profile missing LS_COLORS (non-critical)"

if command -v colortest >/dev/null 2>&1; then
  pass "colortest function available in current shell"
else
  info "colortest not in current shell; reloading profile"
  . /root/.profile 2>/dev/null || true
  command -v colortest >/dev/null 2>&1 && pass "colortest available after reload" || info "colortest requires login shell"
fi

echo
echo "========== TOOL WRAPPER EXISTENCE TESTS =========="
for cmd in gohttp responder smbserver psexec wmiexec secretsdump msfconsole macchanger; do
  test_cmd_exists "$cmd" || true
done

echo
echo "========== TOOL WRAPPER RUN TESTS =========="

command -v gohttp >/dev/null 2>&1 && test_gohttp
command -v responder >/dev/null 2>&1 && test_run responder responder -h
command -v smbserver >/dev/null 2>&1 && test_run smbserver smbserver -h
command -v psexec >/dev/null 2>&1 && test_run psexec psexec -h
command -v wmiexec >/dev/null 2>&1 && test_run wmiexec wmiexec -h
command -v secretsdump >/dev/null 2>&1 && test_run secretsdump secretsdump -h
command -v msfconsole >/dev/null 2>&1 && test_run msfconsole msfconsole -h
command -v macchanger >/dev/null 2>&1 && test_run macchanger macchanger --help

echo
echo "========== QUICK PATH SUMMARY =========="
for cmd in applytheme reloadtheme gohttp responder smbserver psexec wmiexec secretsdump msfconsole macchanger; do
  command -v "$cmd" >/dev/null 2>&1 && echo "$cmd -> $(command -v "$cmd")"
done

echo
echo "========== DONE =========="