#!/bin/sh
# bunny_setup_bb_updates_v5_1.sh
# Manifest-based Bash Bunny updater.
# Uses raw.githubusercontent.com refs/heads/main manifest + direct file downloads.
# No GitHub HTML scraping and no repo tarball extraction.

set -u

echo "[MARKER] running bunny_setup_bb_updates_v5_1.sh"

BB_ROOT="${BB_ROOT:-/root/bb_updates}"
DEBS_DIR="${1:-$BB_ROOT/debs}"
TOOLS_DIR="${2:-$BB_ROOT/tools}"
BUILD_ROOT="${3:-$BB_ROOT/build}"
COLOR_DIR="$BB_ROOT/ssh_colors"
MANIFEST_DIR="$BB_ROOT/manifests"

PROFILE="/root/.profile"
MASTER="$COLOR_DIR/.profile.master"
PYTHON_BIN="${PYTHON_BIN:-python}"

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/f3bandit/BASHBUNNY/refs/heads/main}"
JESSIE_REMOTE_DIR="$REPO_BASE/jessie-armhf-debs"
TOOLS_REMOTE_DIR="$REPO_BASE/tools"
JESSIE_MANIFEST_URL="$JESSIE_REMOTE_DIR/manifest.txt"
TOOLS_MANIFEST_URL="$TOOLS_REMOTE_DIR/manifest.txt"

TARGET_ARCH="$(dpkg --print-architecture 2>/dev/null || echo armhf)"

APT_OPTS='-o Acquire::Check-Valid-Until=false -o Acquire::AllowInsecureRepositories=true -o APT::Get::AllowUnauthenticated=true'

log() {
  echo "[*] $*"
}

warn() {
  echo "[!] $*" >&2
}

run_apt() {
  apt-get $APT_OPTS "$@" || true
}

need_dirs() {
  mkdir -p "$BB_ROOT" "$DEBS_DIR" "$TOOLS_DIR" "$BUILD_ROOT" "$COLOR_DIR" "$MANIFEST_DIR"
}

download_file() {
  url="$1"
  out="$2"

  mkdir -p "$(dirname "$out")"
  rm -f "$out.tmp"

  if command -v wget >/dev/null 2>&1; then
    wget -O "$out.tmp" "$url" || {
      rm -f "$out.tmp"
      return 1
    }
  elif command -v curl >/dev/null 2>&1; then
    curl -L "$url" -o "$out.tmp" || {
      rm -f "$out.tmp"
      return 1
    }
  else
    warn "Neither wget nor curl is available"
    return 1
  fi

  if [ ! -s "$out.tmp" ]; then
    warn "Downloaded empty file: $url"
    rm -f "$out.tmp"
    return 1
  fi

  mv "$out.tmp" "$out"
  return 0
}

# GitHub raw paths need literal % in filenames encoded as %25.
url_path_escape() {
  echo "$1" | sed 's/%/%25/g; s/ /%20/g; s/#/%23/g'
}

validate_deb() {
  deb="$1"
  dpkg-deb -I "$deb" >/dev/null 2>&1
}

validate_tar_gz() {
  archive="$1"
  tar -tzf "$archive" >/dev/null 2>&1
}

validate_cached_debs() {
  dir="$1"
  [ -d "$dir" ] || return 0

  for deb in "$dir"/*.deb; do
    [ -e "$deb" ] || continue
    if ! validate_deb "$deb"; then
      warn "Deleting invalid .deb: $deb"
      rm -f "$deb"
    fi
  done
}

fetch_manifest() {
  url="$1"
  out="$2"

  log "Downloading manifest: $url"
  if ! download_file "$url" "$out"; then
    warn "Could not download manifest: $url"
    warn "Check that manifest.txt exists in the repo at the expected path."
    return 1
  fi

  sed -i 's/\r$//' "$out" 2>/dev/null || true

  if [ ! -s "$out" ]; then
    warn "Manifest is empty: $out"
    return 1
  fi

  return 0
}

download_manifest_files() {
  manifest="$1"
  remote_dir="$2"
  local_dir="$3"
  mode="$4"   # debs or tools

  mkdir -p "$local_dir"

  found=0
  ok=0
  bad=0

  while IFS= read -r name || [ -n "$name" ]; do
    case "$name" in
      ""|\#*) continue ;;
    esac

    found=$((found + 1))

    escaped="$(url_path_escape "$name")"
    url="$remote_dir/$escaped"
    out="$local_dir/$name"

    if [ -s "$out" ]; then
      if [ "$mode" = "debs" ]; then
        if validate_deb "$out"; then
          log "Cached valid: $name"
          ok=$((ok + 1))
          continue
        fi
      elif [ "$name" = "macchanger-1.7.0.tar.gz" ]; then
        if validate_tar_gz "$out"; then
          log "Cached valid: $name"
          ok=$((ok + 1))
          continue
        fi
      elif echo "$name" | grep -q '\.deb$'; then
        if validate_deb "$out"; then
          log "Cached valid: $name"
          ok=$((ok + 1))
          continue
        fi
      else
        log "Cached file exists: $name"
        ok=$((ok + 1))
        continue
      fi

      warn "Cached file invalid, redownloading: $name"
      rm -f "$out"
    fi

    log "Downloading $name"
    if ! download_file "$url" "$out"; then
      warn "Download failed: $url"
      bad=$((bad + 1))
      continue
    fi

    if [ "$mode" = "debs" ]; then
      if validate_deb "$out"; then
        ok=$((ok + 1))
      else
        warn "Downloaded file is not a valid .deb, deleting: $name"
        file "$out" 2>/dev/null || true
        rm -f "$out"
        bad=$((bad + 1))
      fi
    elif [ "$name" = "macchanger-1.7.0.tar.gz" ]; then
      if validate_tar_gz "$out"; then
        ok=$((ok + 1))
      else
        warn "Downloaded file is not a valid tar.gz, deleting: $name"
        file "$out" 2>/dev/null || true
        rm -f "$out"
        bad=$((bad + 1))
      fi
    elif echo "$name" | grep -q '\.deb$'; then
      if validate_deb "$out"; then
        ok=$((ok + 1))
      else
        warn "Downloaded file is not a valid .deb, deleting: $name"
        file "$out" 2>/dev/null || true
        rm -f "$out"
        bad=$((bad + 1))
      fi
    else
      ok=$((ok + 1))
    fi
  done < "$manifest"

  log "Manifest sync complete for $local_dir: listed=$found valid=$ok failed=$bad"

  [ "$found" -gt 0 ] && [ "$ok" -gt 0 ]
}

fix_apt() {
  log "Configuring live archived Debian Jessie sources"

  cat > /etc/apt/sources.list << 'EOT'
deb [trusted=yes] http://archive.debian.org/debian jessie main
deb [trusted=yes] http://archive.debian.org/debian-security jessie/updates main
EOT

  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99archive-bypass << 'EOT'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
APT::Get::AllowUnauthenticated "true";
Acquire::https::Verify-Peer "false";
Acquire::https::Verify-Host "false";
EOT

  rm -rf /var/lib/apt/lists/*
  mkdir -p /var/lib/apt/lists/partial
  apt-get clean || true
  run_apt update
}

sync_repo_debs_from_manifest() {
  log "Step 1: syncing Jessie armhf repo packages from manifest"
  manifest="$MANIFEST_DIR/jessie-armhf-debs.manifest.txt"

  if fetch_manifest "$JESSIE_MANIFEST_URL" "$manifest"; then
    validate_cached_debs "$DEBS_DIR"
    download_manifest_files "$manifest" "$JESSIE_REMOTE_DIR" "$DEBS_DIR" "debs" || true
  else
    warn "Skipping Jessie repo package sync because manifest is unavailable"
  fi
}

sync_tools_from_manifest() {
  log "Step 2: syncing Bunny tools from manifest"
  manifest="$MANIFEST_DIR/tools.manifest.txt"

  if fetch_manifest "$TOOLS_MANIFEST_URL" "$manifest"; then
    validate_cached_debs "$TOOLS_DIR"
    download_manifest_files "$manifest" "$TOOLS_REMOTE_DIR" "$TOOLS_DIR" "tools" || true
  else
    warn "Skipping tool sync because manifest is unavailable"
  fi
}

install_live_build_deps_and_tools() {
  log "Step 3: installing live archived Jessie packages"
  run_apt --allow-unauthenticated install -y \
    gcc \
    g++ \
    build-essential \
    libc6-dev \
    make \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    wget \
    curl \
    ca-certificates \
    file \
    pkg-config \
    autoconf \
    automake \
    libtool \
    patch \
    perl \
    python \
    dpkg \
    unzip \
    netcat-openbsd \
    tcpdump \
    nmap \
    vim-common \
    iptables \
    coreutils \
    tmux \
    htop \
    socat \
    lsof \
    strace \
    arping \
    pv \
    radare2
}

install_cached_repo_debs() {
  log "Step 4: installing cached Jessie repo .deb packages from $DEBS_DIR"

  found=0
  installed=0
  skipped=0

  validate_cached_debs "$DEBS_DIR"

  for deb in "$DEBS_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    base="$(basename "$deb")"

    case "$base" in
      *_all.deb|*_"$TARGET_ARCH".deb)
        found=1
        log "Installing repo package $base"
        dpkg -i "$deb" || true
        installed=$((installed + 1))
        ;;
      *)
        warn "Skipping wrong-arch cached package: $base"
        skipped=$((skipped + 1))
        ;;
    esac
  done

  log "Repo package install loop complete: installed_attempts=$installed skipped=$skipped"

  if [ "$found" -eq 1 ]; then
    log "Fixing dependencies after cached repo .deb install"
    run_apt --allow-unauthenticated -f install -y
  else
    warn "No valid repo .deb files found in $DEBS_DIR"
  fi
}

install_tool_debs() {
  log "Step 5: installing cached custom Bunny .deb tools from $TOOLS_DIR"

  found=0
  validate_cached_debs "$TOOLS_DIR"

  for deb in "$TOOLS_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    found=1
    log "Installing tool package $(basename "$deb")"
    dpkg -i "$deb" || true
  done

  if [ "$found" -eq 1 ]; then
    log "Fixing dependencies after custom tool .deb installs"
    run_apt --allow-unauthenticated -f install -y
  else
    warn "No custom .deb tool files found in $TOOLS_DIR"
  fi
}

build_source_archive() {
  archive="$1"

  if ! validate_tar_gz "$archive"; then
    warn "Skipping invalid source archive: $archive"
    return 0
  fi

  topdir="$(tar -tzf "$archive" 2>/dev/null | head -1 | cut -d/ -f1)"

  if [ -z "$topdir" ]; then
    warn "Skipping $(basename "$archive") (could not determine archive root)"
    return 0
  fi

  mkdir -p "$BUILD_ROOT"
  cd "$BUILD_ROOT" || return 0
  rm -rf "$topdir"
  tar -xzf "$archive"
  cd "$topdir" || return 0

  log "Building $(basename "$archive")"

  if [ -x ./configure ]; then
    ./configure || true
  elif [ -f configure ]; then
    sh ./configure || true
  fi

  make || true
  make install || true
}

install_source_tools() {
  log "Step 6: building/installing source archives from $TOOLS_DIR"

  found=0
  for archive in "$TOOLS_DIR"/*.tar.gz "$TOOLS_DIR"/*.tgz; do
    [ -e "$archive" ] || continue
    found=1
    build_source_archive "$archive"
  done

  if [ "$found" -eq 0 ]; then
    log "No source archives found in $TOOLS_DIR"
  fi
}

make_wrapper() {
  name="$1"
  target="$2"
  pywrap="${3:-0}"

  if [ "$pywrap" = "1" ]; then
    cat > "/usr/bin/$name" << EOT
#!/bin/sh
exec $PYTHON_BIN "$target" "\$@"
EOT
  else
    cat > "/usr/bin/$name" << EOT
#!/bin/sh
exec "$target" "\$@"
EOT
  fi

  chmod +x "/usr/bin/$name"
}

create_tool_wrappers() {
  log "Step 7: creating tool wrappers"

  if [ -x /usr/bin/gohttp ]; then
    :
  elif [ -x /tools/gohttp/gohttp ]; then
    make_wrapper gohttp /tools/gohttp/gohttp 0
  elif [ -x /tools/gohttp ]; then
    make_wrapper gohttp /tools/gohttp 0
  fi

  if [ -f /tools/responder/Responder.py ]; then
    make_wrapper responder /tools/responder/Responder.py 1
  fi
  if [ -f /tools/impacket/examples/smbserver.py ]; then
    make_wrapper smbserver /tools/impacket/examples/smbserver.py 1
  fi
  if [ -f /tools/impacket/examples/psexec.py ]; then
    make_wrapper psexec /tools/impacket/examples/psexec.py 1
  fi
  if [ -f /tools/impacket/examples/wmiexec.py ]; then
    make_wrapper wmiexec /tools/impacket/examples/wmiexec.py 1
  fi
  if [ -f /tools/impacket/examples/secretsdump.py ]; then
    make_wrapper secretsdump /tools/impacket/examples/secretsdump.py 1
  fi
  if [ -x /tools/metasploit-framework/msfconsole ]; then
    make_wrapper msfconsole /tools/metasploit-framework/msfconsole 0
  fi
  if [ -x /usr/local/bin/macchanger ]; then
    make_wrapper macchanger /usr/local/bin/macchanger 0
  fi
}

install_color_profile() {
  log "Step 8: installing SSH color profile from $COLOR_DIR"

  mkdir -p "$COLOR_DIR"

  if [ -f "$PROFILE" ] && [ ! -f "$COLOR_DIR/.profile.backup" ]; then
    cp "$PROFILE" "$COLOR_DIR/.profile.backup"
  fi

  cat > "$MASTER" << 'EOT'
export TERM=xterm-256color
export LS_COLORS='di=1;36:ln=1;36:ex=1;32:pi=33:so=1;35:bd=1;33:cd=1;33:su=37:sg=30:tw=30:ow=30'

alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

export PS1='\[\033[1;32m\]\u@bb\[\033[0m\]:\[\033[1;36m\]\W\[\033[0m\]\[\033[1;31m\]# \[\033[0m\]'

colortest() {
  printf '\033[31mRED\033[0m \033[32mGREEN\033[0m \033[34mBLUE\033[0m\n'
  mkdir -p /tmp/color_test_dir
  touch /tmp/color_test_file
  chmod +x /tmp/color_test_file
  rm -f /tmp/color_test_link
  ln -s /tmp/color_test_file /tmp/color_test_link
  ls --color=always -ld /tmp/color_test_dir /tmp/color_test_file /tmp/color_test_link
}

restoreprofile() {
  if [ -f /root/bb_updates/ssh_colors/.profile.backup ]; then
    cp /root/bb_updates/ssh_colors/.profile.backup /root/.profile
    . /root/.profile
  else
    echo "No backup profile found"
  fi
}

bbhelp() {
  echo "Useful commands:"
  echo "  colortest"
  echo "  applytheme"
  echo "  reloadtheme"
  echo "  restoreprofile"
  echo "  ll, la, l"
}
EOT

  cp "$MASTER" "$PROFILE"

  cat > "$COLOR_DIR/apply_theme.sh" << 'EOT'
#!/bin/sh
cp /root/bb_updates/ssh_colors/.profile.master /root/.profile
EOT
  chmod +x "$COLOR_DIR/apply_theme.sh"

  cat > "$COLOR_DIR/install_colors.sh" << 'EOT'
#!/bin/sh
cp /root/bb_updates/ssh_colors/.profile.master /root/.profile
EOT
  chmod +x "$COLOR_DIR/install_colors.sh"

  cat > /usr/bin/applytheme << 'EOT'
#!/bin/sh
exec /root/bb_updates/ssh_colors/apply_theme.sh "$@"
EOT

  cat > /usr/bin/reloadtheme << 'EOT'
#!/bin/sh
exec /bin/bash -l
EOT

  chmod +x /usr/bin/applytheme /usr/bin/reloadtheme
}

verify() {
  log "Verification"

  echo "Target arch: $TARGET_ARCH"
  echo "Cached repo debs: $(ls "$DEBS_DIR"/*.deb 2>/dev/null | wc -l)"
  echo "Cached tools: $(ls "$TOOLS_DIR" 2>/dev/null | wc -l)"

  bad=0
  for deb in "$DEBS_DIR"/*.deb "$TOOLS_DIR"/*.deb; do
    [ -e "$deb" ] || continue
    if ! validate_deb "$deb"; then
      warn "BAD DEB STILL PRESENT: $deb"
      bad=$((bad + 1))
    fi
  done

  [ "$bad" -eq 0 ] && echo "Deb validation: OK" || echo "Deb validation: $bad bad files"

  command -v applytheme >/dev/null 2>&1 && echo "applytheme -> $(command -v applytheme)" || true
  command -v reloadtheme >/dev/null 2>&1 && echo "reloadtheme -> $(command -v reloadtheme)" || true
  command -v gohttp >/dev/null 2>&1 && echo "gohttp -> $(command -v gohttp)" || true
  command -v responder >/dev/null 2>&1 && echo "responder -> $(command -v responder)" || true
  command -v smbserver >/dev/null 2>&1 && echo "smbserver -> $(command -v smbserver)" || true
  command -v psexec >/dev/null 2>&1 && echo "psexec -> $(command -v psexec)" || true
  command -v wmiexec >/dev/null 2>&1 && echo "wmiexec -> $(command -v wmiexec)" || true
  command -v secretsdump >/dev/null 2>&1 && echo "secretsdump -> $(command -v secretsdump)" || true
  command -v msfconsole >/dev/null 2>&1 && echo "msfconsole -> $(command -v msfconsole)" || true
  command -v macchanger >/dev/null 2>&1 && echo "macchanger -> $(command -v macchanger)" || true
}

main() {
  need_dirs

  log "Using repo base: $REPO_BASE"
  log "Using target arch: $TARGET_ARCH"
  log "Cache root: $BB_ROOT"

  fix_apt
  sync_repo_debs_from_manifest
  sync_tools_from_manifest
  install_live_build_deps_and_tools
  install_cached_repo_debs
  install_tool_debs
  install_source_tools
  create_tool_wrappers
  install_color_profile
  verify

  log "Done"
  log "After running on SW1, use: exec /bin/bash -l"
}

main "$@"
