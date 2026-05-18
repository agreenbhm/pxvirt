#!/bin/bash
# Build all pxvirt packages in dependency order.
# Usage: ./build-all.sh [OPTIONS]
#
# Options:
#   --ceph            Also build ceph-17, ceph-18, ceph-19 (very slow, ~hours each)
#   --stop-on-error   Stop immediately on first build failure (default: continue)
#   --from <pkg>      Skip all packages before <pkg> (resume after partial run)
#   --only <pkg>      Build only a single package
#   --log-dir <dir>   Directory for per-package build logs (default: ./build-logs)
#   --output-dir <dir> Directory for built .deb files (default: /tmp/2022)
#   --no-dsc          Pass DEB_BUILD_OPTIONS=nodsc (skip source package build)
#   --builder <name>  Docker image name (default: pvebuilder)
#   -h, --help        Show this help

set -euo pipefail

SH_PATH=$(readlink -f "$(dirname "$0")")

# --- defaults ---
BUILD_CEPH=0
STOP_ON_ERROR=0
FROM_PKG=""
ONLY_PKG=""
LOG_DIR="$SH_PATH/build-logs"
OUTPUT_DIR="/tmp/2022"
DEB_BUILD_OPTIONS_EXTRA=""
BUILDER="pvebuilder"

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ceph)           BUILD_CEPH=1; shift ;;
        --stop-on-error)  STOP_ON_ERROR=1; shift ;;
        --from)           FROM_PKG="$2"; shift 2 ;;
        --only)           ONLY_PKG="$2"; shift 2 ;;
        --log-dir)        LOG_DIR="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --no-dsc)         DEB_BUILD_OPTIONS_EXTRA="nodsc"; shift ;;
        --builder)        BUILDER="$2"; shift 2 ;;
        -h|--help)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"

# --- package build order ---
# Packages are ordered so that dependencies come before dependents.
# pve-qemu and qemu-server are intentionally omitted: the jiangcuo arm64
# port of pve-qemu is stuck at 10.0.x while qemu-server 9.1 requires >= 10.1~.
# No arm64 build exists for pve-qemu 10.1+. They will fail to build.

PACKAGES=(
    # Tier 1: static / JS / firmware (no build dependencies on other pve pkgs)
    extjs
    sencha-touch
    fonts-font-logos
    novnc-pve
    libjs-qrcodejs
    pve-eslint
    proxmox-i18n
    pve-firmware
    pve-edk2-firmware
    proxmox-perltidy
    pve-xtermjs
    spiceterm
    vncterm

    # Tier 2: system libraries
    pixman
    libseccomp
    libqb
    libgit2
    libtpms
    chrony
    frr
    zfsonlinux
    lxc
    lxcfs
    swtpm           # requires libtpms

    # Tier 3: Perl base libraries
    perlmod
    libarchive-perl
    libxdgmime-perl
    libpve-u2f-server-perl
    pve-common      # most pve packages depend on this

    # Tier 4: Rust libraries and archive tool
    proxmox-ve-rs
    proxmox-perl-rs
    pxar
    proxmox-biome
    pathpatterns
    cargo
    debcargo-conf

    # Tier 5: networking and cluster foundations
    ifupdown2
    kronosnet
    corosync-pve
    corosync-qdevice
    librados2-perl

    # Tier 6: PVE core services
    pve-cluster         # requires pve-common, corosync-pve
    pve-access-control  # requires pve-common, pve-cluster
    pve-storage         # requires pve-common
    pve-guest-common    # requires pve-common, pve-storage
    pve-ha-manager      # requires pve-common, pve-cluster
    pve-http-server     # requires pve-common
    pve-network         # requires pve-common
    pve-lxc-syscalld
    proxmox-widget-toolkit
    pve-firewall
    proxmox-firewall

    # Tier 7: containers, backup, auxiliary services
    pve-container               # requires pve-common, pve-storage, pve-guest-common
    proxmox-backup-qemu
    proxmox-backup-restore-image
    proxmox-backup
    proxmox-backup-meta
    proxmox-offline-mirror
    proxmox-acme
    proxmox-mail-forward
    proxmox-mini-journalreader
    proxmox-network-interface-pinning
    proxmox-kernel-helper
    ksm-control-daemon
    smartmontools
    pve-zsync
    proxmox-rrd-migration-tool
    proxmox-websocket-tunnel

    # Tier 8: manager, installer, hardware
    pve-apiclient
    pve-docs
    pve-manager
    proxmox-archive-keyring
    pve-installer
    pxvirt-spdk
    net-sriov-tools
    pve-vgpu-helper

    # Tier 9: meta-package
    proxmox-ve
)

# Ceph (each takes hours; gated behind --ceph)
CEPH_PACKAGES=(ceph-17 ceph-18 ceph-19)

# Packages that intentionally cannot be built on arm64 right now:
#   pve-qemu   – stuck at 10.0.x; qemu-server 9.1 requires >= 10.1~
#   qemu-server – depends on pve-qemu >= 10.1~
SKIPPED_ALWAYS=(pve-qemu qemu-server)

if [[ $BUILD_CEPH -eq 1 ]]; then
    PACKAGES+=("${CEPH_PACKAGES[@]}")
fi

# --- state tracking ---
PASSED=()
FAILED=()
SKIPPED=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

note()  { echo -e "${YELLOW}[build-all]${NC} $*"; }
ok()    { echo -e "${GREEN}[build-all]${NC} $*"; }
fail()  { echo -e "${RED}[build-all]${NC} $*"; }

build_pkg() {
    local pkg="$1"
    local log="$LOG_DIR/${pkg}.log"
    note "Building $pkg → $log"

    PKG_DIR="$OUTPUT_DIR" \
    BUILDERNAME="$BUILDER" \
    DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS_EXTRA" \
    bash "$SH_PATH/build.sh" "$pkg" >"$log" 2>&1
}

# --- main loop ---
note "Starting pxvirt full build"
note "Builder: $BUILDER  |  Output: $OUTPUT_DIR  |  Logs: $LOG_DIR"
note "Ceph: $([ $BUILD_CEPH -eq 1 ] && echo 'yes' || echo 'no (pass --ceph to enable)')"
echo

SKIPPING=1
[[ -z "$FROM_PKG" ]] && SKIPPING=0

for pkg in "${PACKAGES[@]}"; do
    # --only: build just this one package
    if [[ -n "$ONLY_PKG" ]]; then
        if [[ "$pkg" != "$ONLY_PKG" ]]; then
            continue
        fi
    fi

    # --from: skip until we reach the starting package
    if [[ $SKIPPING -eq 1 ]]; then
        if [[ "$pkg" == "$FROM_PKG" ]]; then
            SKIPPING=0
        else
            SKIPPED+=("$pkg (--from skip)")
            continue
        fi
    fi

    # Always-skipped packages
    skip=0
    for s in "${SKIPPED_ALWAYS[@]}"; do
        if [[ "$pkg" == "$s" ]]; then
            skip=1; break
        fi
    done
    if [[ $skip -eq 1 ]]; then
        fail "SKIP  $pkg (arm64 port unavailable for current version)"
        SKIPPED+=("$pkg")
        continue
    fi

    # Skip if package directory doesn't exist
    if [[ ! -d "$SH_PATH/packages/$pkg" ]]; then
        fail "SKIP  $pkg (no packages/$pkg directory)"
        SKIPPED+=("$pkg (missing)")
        continue
    fi

    if build_pkg "$pkg"; then
        ok "PASS  $pkg"
        PASSED+=("$pkg")
    else
        fail "FAIL  $pkg (see $LOG_DIR/${pkg}.log)"
        FAILED+=("$pkg")
        if [[ $STOP_ON_ERROR -eq 1 ]]; then
            fail "Stopping on first error (--stop-on-error)"
            break
        fi
    fi
done

# --- summary ---
echo
echo "============================================================"
echo "  BUILD SUMMARY"
echo "============================================================"
echo -e "  ${GREEN}Passed${NC}:  ${#PASSED[@]}"
echo -e "  ${RED}Failed${NC}:  ${#FAILED[@]}"
echo -e "  ${YELLOW}Skipped${NC}: ${#SKIPPED[@]}"
echo

if [[ ${#PASSED[@]} -gt 0 ]]; then
    echo -e "${GREEN}Passed:${NC}"
    for p in "${PASSED[@]}"; do echo "  $p"; done
    echo
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}Failed:${NC}"
    for p in "${FAILED[@]}"; do echo "  $p  →  $LOG_DIR/${p}.log"; done
    echo
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Skipped:${NC}"
    for p in "${SKIPPED[@]}"; do echo "  $p"; done
    echo
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    exit 1
fi
