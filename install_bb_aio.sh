#!/bin/sh
# install_bb_aio_v9_trimmed_targets_full_repo_python3.sh
# Bash Bunny updater:
# - downloads FULL Jessie armhf repo cache from manifest so APT has dependencies
# - installs ONLY trimmed target package list using local APT dependency resolver
# - installs Python 2 + Python 3 + pip/pip3/dev headers
# - installs Bunny custom tool debs
# - avoids brute-force dpkg ordering for Jessie packages

set -u

echo "[MARKER] running install_bb_aio_v9_trimmed_targets_full_repo_python3.sh"

BB_ROOT="${BB_ROOT:-/root/bb_updates}"
DEBS_DIR="$BB_ROOT/debs"
TOOLS_DIR="$BB_ROOT/tools"
MANIFEST_DIR="$BB_ROOT/manifests"
REPO_DIR="$BB_ROOT/localrepo"
COLOR_DIR="$BB_ROOT/ssh_colors"
BUILD_DIR="$BB_ROOT/build"

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/f3bandit/BASHBUNNY/refs/heads/main}"
JESSIE_REMOTE_DIR="$REPO_BASE/jessie-armhf-debs"
TOOLS_REMOTE_DIR="$REPO_BASE/tools"
JESSIE_MANIFEST_URL="$JESSIE_REMOTE_DIR/manifest.txt"
TOOLS_MANIFEST_URL="$TOOLS_REMOTE_DIR/manifest.txt"

APT_OPTS='-o Acquire::Check-Valid-Until=false -o Acquire::AllowInsecureRepositories=true -o APT::Get::AllowUnauthenticated=true -o APT::Default-Release='

log() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

mkdir -p "$DEBS_DIR" "$TOOLS_DIR" "$MANIFEST_DIR" "$REPO_DIR" "$COLOR_DIR" "$BUILD_DIR"

download_file() {
    url="$1"
    out="$2"

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
        warn "Empty download: $url"
        rm -f "$out.tmp"
        return 1
    fi

    mv "$out.tmp" "$out"
    return 0
}

validate_deb() {
    dpkg-deb -I "$1" >/dev/null 2>&1
}

validate_targz() {
    tar -tzf "$1" >/dev/null 2>&1
}

fetch_manifest() {
    url="$1"
    out="$2"

    log "Downloading manifest: $url"
    download_file "$url" "$out" || return 1

    sed -i 's/\r$//' "$out" 2>/dev/null || true

    if [ ! -s "$out" ]; then
        warn "Manifest empty: $out"
        return 1
    fi

    return 0
}

sync_full_repo_debs() {
    manifest="$MANIFEST_DIR/jessie-armhf-debs.manifest.txt"

    fetch_manifest "$JESSIE_MANIFEST_URL" "$manifest" || {
        warn "Could not fetch Jessie manifest"
        return 1
    }

    listed=0
    valid=0
    failed=0
    skipped=0

    log "Downloading FULL repo .deb cache for dependency resolution"

    while IFS= read -r name || [ -n "$name" ]; do
        case "$name" in
            ""|\#*) continue ;;
        esac

        listed=$((listed + 1))

        case "$name" in
            *.deb) ;;
            *)
                skipped=$((skipped + 1))
                continue
                ;;
        esac

        out="$DEBS_DIR/$name"

        if [ -s "$out" ] && validate_deb "$out"; then
            log "Cached valid: $name"
            valid=$((valid + 1))
            continue
        fi

        [ -e "$out" ] && rm -f "$out"

        log "Downloading $name"

        if ! download_file "$JESSIE_REMOTE_DIR/$name" "$out"; then
            warn "Download failed: $name"
            failed=$((failed + 1))
            continue
        fi

        if validate_deb "$out"; then
            valid=$((valid + 1))
        else
            warn "Invalid .deb: $name"
            file "$out" 2>/dev/null || true
            rm -f "$out"
            failed=$((failed + 1))
        fi
    done < "$manifest"

    log "Full repo sync complete: listed=$listed valid=$valid skipped=$skipped failed=$failed"

    [ "$failed" -eq 0 ]
}

sync_tools() {
    manifest="$MANIFEST_DIR/tools.manifest.txt"

    fetch_manifest "$TOOLS_MANIFEST_URL" "$manifest" || {
        warn "Could not fetch tools manifest"
        return 1
    }

    listed=0
    valid=0
    failed=0

    while IFS= read -r name || [ -n "$name" ]; do
        case "$name" in
            ""|\#*) continue ;;
        esac

        listed=$((listed + 1))
        out="$TOOLS_DIR/$name"

        if [ -s "$out" ]; then
            if [ "$name" = "macchanger-1.7.0.tar.gz" ] && validate_targz "$out"; then
                log "Cached valid: $name"
                valid=$((valid + 1))
                continue
            elif echo "$name" | grep -q '\.deb$' && validate_deb "$out"; then
                log "Cached valid: $name"
                valid=$((valid + 1))
                continue
            fi

            warn "Cached invalid, redownloading: $name"
            rm -f "$out"
        fi

        log "Downloading $name"

        if ! download_file "$TOOLS_REMOTE_DIR/$name" "$out"; then
            warn "Tool download failed: $name"
            failed=$((failed + 1))
            continue
        fi

        if [ "$name" = "macchanger-1.7.0.tar.gz" ]; then
            if validate_targz "$out"; then
                valid=$((valid + 1))
            else
                warn "Invalid archive: $name"
                rm -f "$out"
                failed=$((failed + 1))
            fi
        elif echo "$name" | grep -q '\.deb$'; then
            if validate_deb "$out"; then
                valid=$((valid + 1))
            else
                warn "Invalid tool .deb: $name"
                file "$out" 2>/dev/null || true
                rm -f "$out"
                failed=$((failed + 1))
            fi
        else
            valid=$((valid + 1))
        fi
    done < "$manifest"

    log "Tool sync complete: listed=$listed valid=$valid failed=$failed"

    [ "$failed" -eq 0 ]
}

generate_local_repo() {
    log "Generating local APT repo from full cached .debs"

    rm -rf "$REPO_DIR"
    mkdir -p "$REPO_DIR"

    cp "$DEBS_DIR"/*.deb "$REPO_DIR"/ 2>/dev/null || {
        warn "No repo .debs found in $DEBS_DIR"
        return 1
    }

    cd "$REPO_DIR" || return 1

    rm -f Packages Packages.gz

    for deb in *.deb; do
        [ -e "$deb" ] || continue

        dpkg-deb -f "$deb" >> Packages
        echo "Filename: ./$deb" >> Packages
        echo "Size: $(wc -c < "$deb")" >> Packages

        if command -v md5sum >/dev/null 2>&1; then
            echo "MD5sum: $(md5sum "$deb" | awk '{print $1}')" >> Packages
        fi

        if command -v sha256sum >/dev/null 2>&1; then
            echo "SHA256: $(sha256sum "$deb" | awk '{print $1}')" >> Packages
        fi

        echo "" >> Packages
    done

    gzip -c Packages > Packages.gz
}

disable_bad_default_release() {
    mkdir -p /root/bb_updates/apt_conf_backup

    for f in /etc/apt/apt.conf /etc/apt/apt.conf.d/*; do
        [ -f "$f" ] || continue

        if grep -q 'Default-Release' "$f" 2>/dev/null; then
            b="/root/bb_updates/apt_conf_backup/$(basename "$f").bak"
            log "Backing up and disabling APT Default-Release config: $f -> $b"
            cp "$f" "$b"
            sed -i '/Default-Release/d' "$f"
        fi
    done
}

configure_local_apt_only() {
    log "Configuring local APT source only"

    disable_bad_default_release

    cat > /etc/apt/sources.list.d/bb-local.list <<EOF
deb [trusted=yes] file:$REPO_DIR ./
EOF

    cat > /etc/apt/sources.list <<EOF
# Disabled by Bash Bunny AIO installer.
# Using local repo only:
# deb [trusted=yes] file:$REPO_DIR ./
EOF

    apt-get $APT_OPTS \
        -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/bb-local.list \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=false \
        update
}

repair_broken_state() {
    log "Repairing broken dpkg/apt state"

    dpkg --configure -a || true

    for pkg in libssl-dev python python-pip python3 python3-pip python3-dev; do
        deb="$(ls "$REPO_DIR"/${pkg}_*.deb 2>/dev/null | head -1)"

        if [ -n "$deb" ] && validate_deb "$deb"; then
            log "Pre-reinstalling $pkg from $(basename "$deb")"
            dpkg -i "$deb" || true
        fi
    done

    apt-get $APT_OPTS \
        -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/bb-local.list \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=false \
        -f install -y || true
}

install_trimmed_targets() {
    log "Installing trimmed target packages with local APT dependency resolver"

    apt-get $APT_OPTS \
        -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/bb-local.list \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=false \
        --allow-unauthenticated \
        install -y \
        build-essential \
        gcc \
        g++ \
        make \
        libc6-dev \
        pkg-config \
        autoconf \
        automake \
        libtool \
        patch \
        perl \
        python \
        python-pip \
        python-dev \
        python-setuptools \
        python3 \
        python3-minimal \
        python3-pip \
        python3-setuptools \
        python3-dev \
        dpkg \
        dpkg-dev \
        fakeroot \
        tar \
        gzip \
        bzip2 \
        xz-utils \
        unzip \
        file \
        ca-certificates \
        wget \
        curl \
        iproute2 \
        iptables \
        net-tools \
        iputils-ping \
        netcat-openbsd \
        tcpdump \
        nmap \
        arping \
        socat \
        tmux \
        htop \
        lsof \
        strace \
        pv \
        vim-tiny \
        vim-common \
        nano \
        radare2

    apt-get $APT_OPTS \
        -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/bb-local.list \
        -o Dir::Etc::sourceparts=- \
        -o APT::Get::List-Cleanup=false \
        -f install -y
}

install_tool_debs() {
    log "Installing Bunny custom tool .deb files"

    for deb in "$TOOLS_DIR"/*.deb; do
        [ -e "$deb" ] || continue

        if validate_deb "$deb"; then
            log "Installing tool $(basename "$deb")"
            dpkg -i "$deb" || true
        else
            warn "Skipping invalid tool deb: $deb"
        fi
    done

    apt-get $APT_OPTS -f install -y || true
}

build_source_archives() {
    log "Building source archives"

    for archive in "$TOOLS_DIR"/*.tar.gz "$TOOLS_DIR"/*.tgz; do
        [ -e "$archive" ] || continue

        if ! validate_targz "$archive"; then
            warn "Skipping invalid archive: $archive"
            continue
        fi

        mkdir -p "$BUILD_DIR"

        top="$(tar -tzf "$archive" | head -1 | cut -d/ -f1)"
        [ -n "$top" ] || continue

        cd "$BUILD_DIR" || continue
        rm -rf "$top"
        tar -xzf "$archive"

        cd "$top" || continue

        [ -f configure ] && sh ./configure || true
        make || true
        make install || true
    done
}

install_colors() {
    log "Installing SSH color profile"

    mkdir -p "$COLOR_DIR"

    if [ -f /root/.profile ] && [ ! -f "$COLOR_DIR/.profile.backup" ]; then
        cp /root/.profile "$COLOR_DIR/.profile.backup"
    fi

    cat > "$COLOR_DIR/.profile.master" <<'EOF'
export TERM=xterm-256color

alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

export PS1='\[\033[1;32m\]\u@bb\[\033[0m\]:\[\033[1;36m\]\W\[\033[0m\]\[\033[1;31m\]# \[\033[0m\]'

colortest() {
    printf '\033[31mRED\033[0m \033[32mGREEN\033[0m \033[34mBLUE\033[0m\n'
}

restoreprofile() {
    if [ -f /root/bb_updates/ssh_colors/.profile.backup ]; then
        cp /root/bb_updates/ssh_colors/.profile.backup /root/.profile
        . /root/.profile
    else
        echo "No backup profile found"
    fi
}
EOF

    cp "$COLOR_DIR/.profile.master" /root/.profile

    cat > /usr/bin/applytheme <<'EOF'
#!/bin/sh
cp /root/bb_updates/ssh_colors/.profile.master /root/.profile
EOF

    cat > /usr/bin/reloadtheme <<'EOF'
#!/bin/sh
exec /bin/bash -l
EOF

    chmod +x /usr/bin/applytheme /usr/bin/reloadtheme
}

verify() {
    log "Verification"

    echo "Full repo debs cached: $(ls "$DEBS_DIR"/*.deb 2>/dev/null | wc -l)"
    echo "Tool files cached: $(ls "$TOOLS_DIR" 2>/dev/null | wc -l)"

    bad=0

    for deb in "$DEBS_DIR"/*.deb "$TOOLS_DIR"/*.deb; do
        [ -e "$deb" ] || continue

        if ! validate_deb "$deb"; then
            warn "BAD DEB: $deb"
            bad=$((bad + 1))
        fi
    done

    [ "$bad" -eq 0 ] && echo "Deb validation: OK" || echo "Deb validation: $bad bad files"

    for cmd in gcc g++ make python python3 pip pip3 curl wget nmap tcpdump tmux htop socat strace lsof radare2 macchanger applytheme reloadtheme; do
        command -v "$cmd" >/dev/null 2>&1 && echo "$cmd -> $(command -v "$cmd")"
    done

    echo
    echo "Python versions:"
    python --version 2>&1 || true
    python3 --version 2>&1 || true
    pip --version 2>&1 || true
    pip3 --version 2>&1 || true
}

main() {
    sync_full_repo_debs
    sync_tools
    generate_local_repo
    configure_local_apt_only
    repair_broken_state
    install_trimmed_targets
    install_tool_debs
    build_source_archives
    install_colors
    verify

    log "Done. Run: exec /bin/bash -l"
}

main "$@"
