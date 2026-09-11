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
#   cloud-localds | genisoimage | mkisofs | xorriso | hdiutil  (to build the seed ISO)
# Install on Debian/Ubuntu: sudo apt install qemu-utils cloud-image-utils genisoimage
# Install on macOS (brew):  brew install qemu  (VirtualBox provides VBoxManage; the
#                           seed ISO is built with the built-in hdiutil — no extra pkg)

set -euo pipefail

# ── tunables (env-overridable) ───────────────────────────────────────────────
VM_NAME="${VM_NAME:-dev-vm}"
RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
SWAP_GB="${SWAP_GB:-4}"             # guest swapfile; 0 disables. Elastic buffer so
                                    # memory-heavy builds (go build/test) thrash
                                    # instead of hard-freezing on this small-RAM VM
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

# An aborted earlier run can leave the VDI registered in VirtualBox's media
# registry. qemu-img below rewrites that file with a fresh UUID, so the stale
# entry goes 'inaccessible' and --resize then dies with a lock-list error.
# Drop the stale registration first (closemedium leaves the file alone).
STALE_UUID="$(VBoxManage list hdds 2>/dev/null | awk -v d="$DISK" '
  BEGIN { RS = ""; FS = "\n" }
  {
    uuid = ""; loc = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^UUID:/)     { uuid = $i; sub(/^UUID:[ \t]+/, "", uuid) }
      if ($i ~ /^Location:/) { loc  = $i; sub(/^Location:[ \t]+/, "", loc) }
    }
    if (loc == d) print uuid
  }')"
if [ -n "$STALE_UUID" ]; then
  say "Unregistering leftover medium from a previous run…"
  VBoxManage closemedium disk "$STALE_UUID" || die "could not unregister stale medium $STALE_UUID"
fi

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
# hdiutil (macOS) images a *directory*, so stage the NoCloud files in one.
CIDATA="$TMP/cidata"; mkdir -p "$CIDATA"
cat > "$CIDATA/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF
cat > "$CIDATA/user-data" <<EOF
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
bootcmd:
  # VirtualBox's NAT stack is the weak spot of this setup: on some hosts (seen on
  # macOS 15 + VBox 7.2) it silently drops ALL UDP while TCP keeps working, so DNS
  # (udp/53) and NTP die and cloud-init fails the package stage with
  # 'Temporary failure resolving archive.ubuntu.com'. And when the host has no IPv6,
  # NAT offers no v6 route either, so AAAA-first lookups stall until timeout.
  # Both are host facts the guest can only work around — do it before any apt run.
  #
  # a) prefer IPv4 over a NAT-provided but unroutable IPv6
  - [ bash, -c, "grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf" ]
  - [ bash, -c, "echo 'Acquire::ForceIPv4 \"true\";' > /etc/apt/apt.conf.d/99force-ipv4" ]
  # b) if plain resolution is broken, fall back to DNS-over-TLS (tcp/853), which
  #    survives a UDP-dropping NAT. Conditional, so a healthy host keeps its own DNS.
  - [ bash, -c, "getent hosts archive.ubuntu.com >/dev/null 2>&1 || { sleep 5; getent hosts archive.ubuntu.com >/dev/null 2>&1; } || { mkdir -p /etc/systemd/resolved.conf.d; { echo '[Resolve]'; echo 'DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com'; echo 'DNSOverTLS=yes'; } > /etc/systemd/resolved.conf.d/99-dns-over-tls.conf; systemctl restart systemd-resolved; sleep 3; }" ]
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
write_files:
  - path: /etc/default/grub.d/99-headless.cfg
    permissions: '0644'
    content: |
      # Headless VM: never block at the GRUB menu waiting for a keypress.
      # After an unclean shutdown Ubuntu sets 'recordfail', which otherwise makes
      # GRUB wait indefinitely for input — fatal with no console. Auto-boot fast.
      GRUB_TIMEOUT=2
      GRUB_TIMEOUT_STYLE=menu
      GRUB_RECORDFAIL_TIMEOUT=2
  - path: /usr/local/bin/setup-user-cli.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      # Install Claude Code + Codex CLI into the current user's npm prefix.
      # Invoked as: sudo -u <user> -H bash /usr/local/bin/setup-user-cli.sh
      set -euo pipefail
      # Set per-user npm prefix so global installs go into ~/.npm-global
      npm config set prefix "\$HOME/.npm-global"
      # Idempotently add ~/.npm-global/bin to PATH in ~/.bashrc
      if ! grep -qF '.npm-global/bin' "\$HOME/.bashrc"; then
        echo 'export PATH="\$HOME/.npm-global/bin:\$PATH"' >> "\$HOME/.bashrc"
      fi
      # Install CLI tools owned by the user (no root required for future updates)
      npm install -g @anthropic-ai/claude-code @openai/codex
runcmd:
  # Elastic swap first, so the rest of provisioning (and later builds) can lean on
  # it. Runs after cloud-init has grown the rootfs, so the space is available.
  - [ bash, -c, "if [ ${SWAP_GB} -gt 0 ] && ! swapon --show | grep -q /swapfile; then fallocate -l ${SWAP_GB}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && (grep -qF /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab); fi" ]
  - [ bash, -c, "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -" ]
  - [ apt-get, install, -y, nodejs ]
  - [ sudo, -u, $VM_USER, -H, bash, /usr/local/bin/setup-user-cli.sh ]
  - [ update-grub ]
  - [ bash, -c, "echo 'cloud-init: dev tooling ready' > /etc/motd" ]
EOF

if command -v cloud-localds >/dev/null; then
  cloud-localds "$SEED" "$CIDATA/user-data" "$CIDATA/meta-data"
elif command -v genisoimage >/dev/null; then
  genisoimage -output "$SEED" -volid cidata -joliet -rock "$CIDATA/user-data" "$CIDATA/meta-data" >/dev/null 2>&1
elif command -v mkisofs >/dev/null; then
  mkisofs -output "$SEED" -volid cidata -joliet -rock "$CIDATA/user-data" "$CIDATA/meta-data" >/dev/null 2>&1
elif command -v xorriso >/dev/null; then
  xorriso -as mkisofs -o "$SEED" -V cidata -J -r "$CIDATA/user-data" "$CIDATA/meta-data" >/dev/null 2>&1
elif command -v hdiutil >/dev/null; then
  # macOS ships no mkisofs; hdiutil makehybrid is the built-in equivalent, so a
  # stock mac needs no extra package. Joliet keeps the lowercase file names that
  # cloud-init expects; the volume name becomes the NoCloud 'cidata' label.
  rm -f "$SEED"
  hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED" "$CIDATA" >/dev/null
else
  die "need one of: cloud-localds, genisoimage, mkisofs, xorriso, hdiutil to build the seed ISO"
fi

# ── 3. create + configure the VM ─────────────────────────────────────────────
say "Creating VM '$VM_NAME' (${RAM_MB} MB RAM, ${CPUS} vCPU)…"
VBoxManage createvm --name "$VM_NAME" --ostype Ubuntu_64 --register
VBoxManage modifyvm "$VM_NAME" --memory "$RAM_MB" --cpus "$CPUS" \
  --nic1 nat --graphicscontroller vmsvga --vram 16 --audio-driver none --firmware efi
# Answer guest DNS via the host's resolver instead of proxying queries out of the
# NAT stack — fixes guest DNS on hosts where that proxy is unreliable. (Where NAT
# drops UDP outright this cannot help; the guest-side DoT fallback covers that.)
VBoxManage modifyvm "$VM_NAME" --natdnshostresolver1 on
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
     VBoxManage controlvm "$VM_NAME" acpipowerbutton # stop GRACEFULLY (preferred)
     VBoxManage controlvm "$VM_NAME" poweroff        # hard stop — only if hung
     VBoxManage startvm   "$VM_NAME" --type headless # start again
     VBoxManage unregistervm "$VM_NAME" --delete     # destroy + reclaim disk
     ssh-keygen -R '[127.0.0.1]:$SSH_PORT'           # after a rebuild: drop the
                                                     # old host key from known_hosts

  ⚠  Prefer 'acpipowerbutton' (clean shutdown). A hard 'poweroff' mid-apt can
     corrupt the kernel/initrd and leave the VM unbootable at GRUB.

  Disk: thin VDI at $DISK (grows only as used).
EOF
