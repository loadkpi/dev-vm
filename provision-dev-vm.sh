#!/usr/bin/env bash
#
# provision-dev-vm.sh — spin up a small, headless Ubuntu VM in VirtualBox,
# preinstalled with Node.js + Claude Code + Codex CLI, for sandboxed agentic
# development. Runs ON THE HOST (Linux/macOS).
#
# Disk-frugal by design:
#   - Ubuntu *cloud* image (no GUI) instead of the desktop ISO  → ~2.2 GB base
#   - dynamically allocated (thin) VDI                          → host file grows
#                                                                 only with use
#   - cloud-init auto-grows the rootfs to fill the virtual disk on first boot
#
# Dependencies (host): VBoxManage, qemu-img, and one of
#   cloud-localds | genisoimage | mkisofs | xorriso   (to build the seed ISO)
# Install on Debian/Ubuntu: sudo apt install qemu-utils cloud-image-utils genisoimage
# Install on macOS (brew):  brew install qemu cdrtools  (VirtualBox provides VBoxManage)

set -euo pipefail

# ── tunables (env-overridable) ───────────────────────────────────────────────
VM_NAME="${VM_NAME:-dev-vm}"
RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_GB="${DISK_GB:-16}"            # virtual size; thin, so ~3-4 GB real usage
UBUNTU_REL="${UBUNTU_REL:-noble}"   # noble = 24.04 LTS
SSH_PORT="${SSH_PORT:-2222}"        # host port -> guest 22
VM_USER="${VM_USER:-dev}"
VM_PASS="${VM_PASS:-dev}"           # console fallback; SSH uses your key
PUBKEY="${PUBKEY:-}"                # path to an SSH public key (auto-detected)
WORKDIR="${WORKDIR:-$HOME/.local/share/$VM_NAME}"

IMG_URL="https://cloud-images.ubuntu.com/${UBUNTU_REL}/current/${UBUNTU_REL}-server-cloudimg-amd64.img"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── checks ───────────────────────────────────────────────────────────────────
command -v VBoxManage >/dev/null || die "VBoxManage not found (install VirtualBox)"
command -v qemu-img   >/dev/null || die "qemu-img not found (apt install qemu-utils / brew install qemu)"
VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1 && die "VM '$VM_NAME' already exists — delete it first or set VM_NAME"

if [ -z "$PUBKEY" ]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && PUBKEY="$k" && break
  done
fi
if [ -z "$PUBKEY" ] || [ ! -f "$PUBKEY" ]; then
  say "No SSH public key found — generating one at ~/.ssh/id_ed25519"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  PUBKEY="$HOME/.ssh/id_ed25519.pub"
fi
PUBKEY_CONTENT="$(cat "$PUBKEY")"

mkdir -p "$WORKDIR"
DISK="$WORKDIR/$VM_NAME.vdi"
SEED="$WORKDIR/seed.iso"
BASE="$WORKDIR/${UBUNTU_REL}-cloudimg.img"

# ── 1. fetch + convert the cloud image to a thin VDI ─────────────────────────
if [ ! -f "$BASE" ]; then
  say "Downloading Ubuntu $UBUNTU_REL cloud image…"
  curl -fL --progress-bar -o "$BASE" "$IMG_URL"
fi
say "Converting to thin VDI and resizing to ${DISK_GB} GB (virtual)…"
qemu-img convert -O vdi "$BASE" "$DISK"
VBoxManage modifymedium disk "$DISK" --resize "$((DISK_GB * 1024))"

# ── 2. build the cloud-init NoCloud seed ISO ─────────────────────────────────
say "Building cloud-init seed…"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF
cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_USER
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $PUBKEY_CONTENT
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    $VM_USER:$VM_PASS
package_update: true
package_upgrade: false
packages:
  - git
  - curl
  - ca-certificates
  - build-essential
  - python3
  - python3-pip
  - python3-venv
  - unzip
  - ripgrep
runcmd:
  - [ bash, -c, "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -" ]
  - [ apt-get, install, -y, nodejs ]
  - [ bash, -c, "npm install -g @anthropic-ai/claude-code @openai/codex" ]
  - [ bash, -c, "echo 'cloud-init: dev tooling ready' > /etc/motd" ]
EOF

if command -v cloud-localds >/dev/null; then
  cloud-localds "$SEED" "$TMP/user-data" "$TMP/meta-data"
elif command -v genisoimage >/dev/null; then
  genisoimage -output "$SEED" -volid cidata -joliet -rock "$TMP/user-data" "$TMP/meta-data" >/dev/null 2>&1
elif command -v mkisofs >/dev/null; then
  mkisofs -output "$SEED" -volid cidata -joliet -rock "$TMP/user-data" "$TMP/meta-data" >/dev/null 2>&1
elif command -v xorriso >/dev/null; then
  xorriso -as mkisofs -o "$SEED" -V cidata -J -r "$TMP/user-data" "$TMP/meta-data" >/dev/null 2>&1
else
  die "need one of: cloud-localds, genisoimage, mkisofs, xorriso to build the seed ISO"
fi

# ── 3. create + configure the VM ─────────────────────────────────────────────
say "Creating VM '$VM_NAME' (${RAM_MB} MB RAM, ${CPUS} vCPU)…"
VBoxManage createvm --name "$VM_NAME" --ostype Ubuntu_64 --register
VBoxManage modifyvm "$VM_NAME" --memory "$RAM_MB" --cpus "$CPUS" \
  --nic1 nat --graphicscontroller vmsvga --vram 16 --audio-driver none --firmware efi
# NAT port-forward for SSH
VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,127.0.0.1,$SSH_PORT,,22"

VBoxManage storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$DISK"
VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$SEED"

# ── 4. boot headless ─────────────────────────────────────────────────────────
say "Starting VM (headless)…"
VBoxManage startvm "$VM_NAME" --type headless

cat <<EOF

  ✅ '$VM_NAME' is booting. First boot runs cloud-init (installs Node + CLIs);
     give it ~2-3 min, then:

     ssh -p $SSH_PORT $VM_USER@127.0.0.1            # key-based; password: $VM_PASS

  Inside the VM:
     claude        # Claude Code  (run /login once)
     codex         # Codex CLI    (run login once)

  Manage:
     VBoxManage controlvm "$VM_NAME" poweroff       # stop
     VBoxManage startvm   "$VM_NAME" --type headless# start again
     VBoxManage unregistervm "$VM_NAME" --delete    # destroy + reclaim disk

  Disk: thin VDI at $DISK (grows only as used).
EOF
