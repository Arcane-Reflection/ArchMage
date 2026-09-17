#!/usr/bin/env bash
# vm-x86_64.sh — interactive KVM x86_64 VM for the daily Phosh dev loop
# (SIM-01). Near-native speed for UI + PKGBUILD iteration; aarch64 TCG is
# reserved for the headless smoke loop (test/smoke-aarch64.sh).
#
# Usage:
#   test/vm-x86_64.sh --image /path/to/image.raw      # or set LPOS_IMAGE
#   test/vm-x86_64.sh --check --image /path/to/image  # self-check only
#   test/vm-x86_64.sh --kernel vmlinuz --initrd initramfs --image img.raw
#                       # direct-kernel boot bypass (no EFI firmware needed)
#
# The x86_64 image is a MANUAL input for now — a documented stub
# (SKELETON): automated image builds via kupferbootstrap land in Phase 2.
# Without --image the script prints acquisition guidance and exits
# non-zero.
#
# SSH into the booted image (when it runs sshd): the VM forwards
# 127.0.0.1:2222 -> guest :22 (loopback-only, T-01-06).

set -euo pipefail

usage() {
    cat <<'EOF'
vm-x86_64.sh — interactive x86_64 Phosh dev VM (KVM when available)

Usage:
  test/vm-x86_64.sh --image PATH [options]
  test/vm-x86_64.sh --check [--image PATH]
  test/vm-x86_64.sh --kernel PATH [--initrd PATH] --image PATH

Options:
  --image PATH     Disk image to boot (raw or qcow2). May also be provided
                   via the LPOS_IMAGE environment variable.
  --check          Self-check mode: verify qemu-system-x86_64 presence
                   (ERROR when missing), warn about missing KVM/firmware,
                   report READY when an existing --image is given. Never
                   launches the VM.
  --kernel PATH    Direct-kernel boot (bypasses EFI/OVMF firmware).
  --initrd PATH    initramfs for --kernel boot.
  --append STR     Kernel cmdline for --kernel boot
                   (default: "root=/dev/vda rw console=tty0").
  --memory MB      Guest RAM (default 4096).
  -h, --help       Show this help.

Behavior:
  - KVM: -accel kvm when /dev/kvm is writable, otherwise a WARNING and
    TCG fallback.
  - EFI boot via OVMF/edk2 firmware for raw and qcow2 images; EFI vars
    are stored persistently next to the image as <image>.vars.fd.
  - virtio storage/network, virtio-vga display, usb-tablet pointer.
  - hostfwd binds 127.0.0.1:2222 only.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

print_image_guidance() {
    cat >&2 <<'EOF'

No --image given (and LPOS_IMAGE is unset).

The x86_64 image is a MANUAL input for now (documented stub; automated
image builds land in Phase 2):

  1. postmarketOS ships ready-to-run generic x86_64 Phosh images:
       https://images.postmarketos.org/genericx86/
     Download the latest Phosh image, decompress it:
       unxz postmarketos-*.raw.xz
     and pass the .raw to this script.

  2. Or build an image with kupferbootstrap (Phase 2 will wire this into
     the repo): https://kupfer.gitlab.io/kupferbootstrap/

Then: test/vm-x86_64.sh --image /path/to/image.raw
      (or: export LPOS_IMAGE=/path/to/image.raw)
EOF
}

IMAGE=${LPOS_IMAGE:-}
CHECK=no
KERNEL=""
INITRD=""
APPEND="root=/dev/vda rw console=tty0"
MEM=4096
while [ $# -gt 0 ]; do
    case "$1" in
        --image|-i)
            [ $# -ge 2 ] || die "--image needs a PATH argument"
            IMAGE=$2
            shift
            ;;
        --check)
            CHECK=yes
            ;;
        --kernel)
            [ $# -ge 2 ] || die "--kernel needs a PATH argument"
            KERNEL=$2
            shift
            ;;
        --initrd)
            [ $# -ge 2 ] || die "--initrd needs a PATH argument"
            INITRD=$2
            shift
            ;;
        --append)
            [ $# -ge 2 ] || die "--append needs a STRING argument"
            APPEND=$2
            shift
            ;;
        --memory|-m)
            [ $# -ge 2 ] || die "--memory needs an MB argument"
            MEM=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
    shift
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Locate EFI firmware (OVMF/edk2); qemu-desktop bundles edk2 ROMs under
# /usr/share/qemu, the edk2 package uses /usr/share/edk2.
find_firmware() {
    local candidate
    for candidate in \
        /usr/share/qemu/edk2-x86_64-code.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

find_firmware_vars() {
    local candidate
    for candidate in \
        /usr/share/qemu/edk2-i386-vars.fd \
        /usr/share/edk2/x64/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

detect_disk_format() {
    local img=$1
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img info --format -- "$img" 2>/dev/null && return 0
    fi
    case "$img" in
        *.qcow2) printf 'qcow2\n' ;;
        *) printf 'raw\n' ;;
    esac
}

ACCEL_LABEL=kvm
if ! lpos::kvm_available; then
    ACCEL_LABEL=tcg
fi

# --- --check self-test mode -----------------------------------------------
if [ "$CHECK" = yes ]; then
    ERRORS=0
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        printf 'OK      qemu-system-x86_64: %s\n' "$(command -v qemu-system-x86_64)"
    else
        printf 'ERROR   qemu-system-x86_64 not found (Arch: pacman -S qemu-desktop)\n' >&2
        ERRORS=1
    fi
    if lpos::kvm_available; then
        printf 'OK      /dev/kvm writable — KVM enabled\n'
    else
        lpos_warn "/dev/kvm not writable — WARNING only, will fall back to TCG (slow but functional)"
    fi
    if FW_CODE=$(find_firmware); then
        printf 'OK      EFI firmware: %s\n' "$FW_CODE"
    else
        lpos_warn "no OVMF/edk2 firmware found — EFI boot unavailable (use --kernel/--initrd, or install qemu-desktop/edk2)"
    fi
    if [ -n "$IMAGE" ]; then
        if [ -s "$IMAGE" ]; then
            printf 'OK      image: %s (%s)\n' "$IMAGE" "$(detect_disk_format "$IMAGE")"
        else
            printf 'ERROR   image %s does not exist or is empty\n' "$IMAGE" >&2
            ERRORS=1
        fi
    else
        printf 'ERROR   no --image given — nothing to boot (see guidance below)\n' >&2
        print_image_guidance
        ERRORS=1
    fi
    if [ "$ERRORS" -eq 0 ]; then
        printf 'READY   accel=%s memory=%sM ssh-forward=127.0.0.1:2222\n' "$ACCEL_LABEL" "$MEM"
        exit 0
    fi
    exit 1
fi
# ---------------------------------------------------------------------------

# --- launch mode -----------------------------------------------------------
if [ -z "$IMAGE" ]; then
    print_image_guidance
    die "no image given"
fi
[ -s "$IMAGE" ] || die "image '$IMAGE' does not exist or is empty"
lpos::require_cmd qemu-system-x86_64

QEMU_ARGS=(-M q35 -m "$MEM" -smp 2
    -drive file="$IMAGE",if=virtio,format="$(detect_disk_format "$IMAGE")"
    -device virtio-vga
    -device qemu-xhci -device usb-tablet
    -netdev user,id=n0,hostfwd="$(lpos::hostfwd_tcp 2222)"
    -device virtio-net-pci,netdev=n0)

if [ "$ACCEL_LABEL" = kvm ]; then
    lpos_info "KVM available — accel=kvm"
    QEMU_ARGS+=(-accel kvm -cpu host)
else
    lpos_warn "/dev/kvm not writable — falling back to TCG (slow; install/enable KVM for interactive use)"
    QEMU_ARGS+=(-accel tcg -cpu max)
fi

if [ -n "$KERNEL" ]; then
    lpos_info "direct-kernel boot: $KERNEL"
    QEMU_ARGS+=(-kernel "$KERNEL" -append "$APPEND")
    if [ -n "$INITRD" ]; then
        QEMU_ARGS+=(-initrd "$INITRD")
    fi
else
    FW_CODE=$(find_firmware) || die \
        "no EFI firmware found for booting '$IMAGE' — install qemu-desktop (bundles edk2) or use --kernel/--initrd direct boot"
    FW_VARS_SRC=$(find_firmware_vars) || die \
        "EFI vars template not found alongside firmware $FW_CODE"
    # Persistent EFI NVRAM next to the image (survives reboots of the VM).
    FW_VARS=$IMAGE.vars.fd
    if [ ! -f "$FW_VARS" ]; then
        cp "$FW_VARS_SRC" "$FW_VARS"
    fi
    lpos_info "EFI boot: $FW_CODE (vars: $FW_VARS)"
    QEMU_ARGS+=(
        -drive if=pflash,format=raw,readonly=on,file="$FW_CODE"
        -drive if=pflash,format=raw,file="$FW_VARS"
    )
fi

lpos_info "launching interactive VM (SSH forward: 127.0.0.1:2222 -> guest :22)"
exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
