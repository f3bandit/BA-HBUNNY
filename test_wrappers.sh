cat << 'EOF' > /tmp/test_wrappers_and_colors.sh
#!/bin/sh

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }
info() { echo "[*] $*"; }

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

echo "========== COLOR / PROFILE TESTS =========="
test_cmd_exists applytheme || true
test_cmd_exists reloadtheme || true

if [ -f /root/ssh_colors/.profile.backup ]; then
  pass "backup exists: /root/ssh_colors/.profile.backup"
else
  fail "missing backup: /root/ssh_colors/.profile.backup"
fi

if [ -f /root/ssh_colors/.profile.master ]; then
  pass "master profile exists: /root/ssh_colors/.profile.master"
else
  fail "missing master profile: /root/ssh_colors/.profile.master"
fi

if [ -f /root/ssh_colors/apply_theme.sh ]; then
  pass "apply script exists: /root/ssh_colors/apply_theme.sh"
else
  fail "missing apply script: /root/ssh_colors/apply_theme.sh"
fi

if grep -q 'LS_COLORS=' /root/.profile 2>/dev/null; then
  pass ".profile contains LS_COLORS"
else
  fail ".profile missing LS_COLORS"
fi

if grep -q 'PS1=' /root/.profile 2>/dev/null; then
  pass ".profile contains PS1"
else
  fail ".profile missing PS1"
fi

if command -v colortest >/dev/null 2>&1; then
  pass "colortest function available in current shell"
  echo "[*] Visual color test follows:"
  colortest || true
else
  info "colortest not in current shell yet; reloading profile"
  . /root/.profile
  if command -v colortest >/dev/null 2>&1; then
    pass "colortest available after profile reload"
    echo "[*] Visual color test follows:"
    colortest || true
  else
    fail "colortest still unavailable"
  fi
fi

echo
echo "========== TOOL WRAPPER EXISTENCE TESTS =========="
for cmd in gohttp responder smbserver psexec wmiexec secretsdump msfconsole macchanger; do
  test_cmd_exists "$cmd" || true
done

echo
echo "========== TOOL WRAPPER RUN TESTS =========="

if command -v gohttp >/dev/null 2>&1; then
  test_run gohttp gohttp -h
fi

if command -v responder >/dev/null 2>&1; then
  test_run responder responder -h
fi

if command -v smbserver >/dev/null 2>&1; then
  test_run smbserver smbserver -h
fi

if command -v psexec >/dev/null 2>&1; then
  test_run psexec psexec -h
fi

if command -v wmiexec >/dev/null 2>&1; then
  test_run wmiexec wmiexec -h
fi

if command -v secretsdump >/dev/null 2>&1; then
  test_run secretsdump secretsdump -h
fi

if command -v msfconsole >/dev/null 2>&1; then
  test_run msfconsole msfconsole -h
fi

if command -v macchanger >/dev/null 2>&1; then
  test_run macchanger macchanger --help
fi

echo
echo "========== QUICK PATH SUMMARY =========="
for cmd in applytheme reloadtheme gohttp responder smbserver psexec wmiexec secretsdump msfconsole macchanger; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd -> $(command -v "$cmd")"
  fi
done

echo
echo "========== DONE =========="
EOF

chmod +x /tmp/test_wrappers_and_colors.sh
sh /tmp/test_wrappers_and_colors.sh