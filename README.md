# dev-vm — disposable Ubuntu VM for agentic dev (Claude Code / Codex)

One host-side script that brings up a small, **headless** Ubuntu VM in VirtualBox,
preinstalled with Node.js + Claude Code + Codex CLI — a clean sandbox to let
agents develop in. Optimized for small disk.

## Why it's disk-frugal

- **Ubuntu *cloud* image, not the desktop ISO** — no GUI, base rootfs ~2.2 GB.
- **Thin (dynamically allocated) VDI** — the host `.vdi` grows only as you use it
  (~3-4 GB real for a typical dev setup), even though the virtual size is 16 GB.
- cloud-init auto-grows the root filesystem to the virtual size on first boot.

## Requirements (on the host)

- VirtualBox (`VBoxManage`)
- `qemu-img` — convert the cloud image to VDI
- a seed-ISO builder: one of `cloud-localds`, `genisoimage`, `mkisofs`, `xorriso`

```sh
# Debian/Ubuntu host
sudo apt install qemu-utils cloud-image-utils genisoimage
# macOS host
brew install qemu cdrtools          # VBoxManage comes with VirtualBox
```

## Usage

```sh
./provision-dev-vm.sh
```

Defaults: `4096` MB RAM, `2` vCPU, `16` GB thin disk, Ubuntu 24.04 (noble),
SSH on host port `2222`. Override via env vars:

```sh
VM_NAME=agent-box RAM_MB=4096 DISK_GB=12 SSH_PORT=2222 ./provision-dev-vm.sh
```

| Var          | Default | Meaning                                  |
| ------------ | ------- | ---------------------------------------- |
| `VM_NAME`    | dev-vm  | VirtualBox VM name                       |
| `RAM_MB`     | 4096    | RAM                                      |
| `CPUS`       | 2       | vCPUs                                    |
| `DISK_GB`    | 16      | virtual disk size (thin; lower = leaner) |
| `UBUNTU_REL` | noble   | Ubuntu release codename                  |
| `SSH_PORT`   | 2222    | host port forwarded to guest :22         |
| `VM_USER`    | dev     | login user                               |
| `PUBKEY`     | auto    | SSH public key to authorize              |

The script downloads the cloud image, makes a thin VDI, builds a cloud-init
seed (creates the user, authorizes your SSH key, installs Node + the CLIs),
then boots the VM headless.

## After it boots

First boot runs cloud-init (~2-3 min). Then:

```sh
ssh -p 2222 dev@127.0.0.1          # key-based; console password is "dev"

# inside the VM:
claude            # Claude Code — run /login once
codex             # Codex CLI   — log in once
```

## Manage / tear down

```sh
VBoxManage controlvm    "dev-vm" acpipowerbutton     # stop GRACEFULLY (preferred)
VBoxManage controlvm    "dev-vm" poweroff            # hard stop — only if hung
VBoxManage startvm      "dev-vm" --type headless     # start again
VBoxManage unregistervm "dev-vm" --delete            # destroy + reclaim disk
```

> ⚠ **Always prefer `acpipowerbutton`.** A hard `poweroff` mid-apt can corrupt
> the kernel/initrd and leave the VM unbootable at GRUB — see Troubleshooting.

## Troubleshooting

### `ssh` fails right after start: `Connection reset` / `kex_exchange_identification` / banner timeout

**Symptom.** Just after `startvm`, `ssh -p 2222 dev@127.0.0.1` returns
`kex_exchange_identification: read: Connection reset by peer` (or, later,
`Connection timed out during banner exchange`). Confusingly, `nc -z 127.0.0.1 2222`
**succeeds** — because port 2222 is answered by VirtualBox's NAT proxy on the
host, not by a live `sshd` in the guest.

**Cause.** The guest isn't booting. Almost always this is a **hard
`VBoxManage controlvm poweroff`** (≈ pulling the power cord) that hit while
cloud-init/apt was touching the kernel, corrupting `/boot` (kernel/initrd) or
the ext4 journal. GRUB then can't load the kernel:

```
error: image not loaded.
error: you need to load the kernel first.
```

A secondary symptom of the same unclean shutdown: Ubuntu's `recordfail` makes
GRUB wait **indefinitely** at the menu for a keypress the headless VM can never
receive, so it just hangs. (Both are prevented on freshly-provisioned VMs by
`/etc/default/grub.d/99-headless.cfg` + graceful shutdown — see below.)

**Confirm it.** Screenshot the headless console — GRUB errors show up here:

```sh
VBoxManage controlvm "dev-vm" screenshotpng /tmp/vm.png && xdg-open /tmp/vm.png
```

**Prevent it.** Stop the VM with `acpipowerbutton`, never a bare `poweroff`
(see Manage / tear down).

### Recover: rescue files out of a broken VM, then rebuild

The VM is disposable, so the fix is to rebuild — but first pull anything you
care about off the disk. Mount the VDI **read-only** on the host (no VirtualBox
needed; the `norecovery` flag is required because the journal is dirty):

```sh
VBoxManage controlvm "dev-vm" poweroff 2>/dev/null   # release the disk lock
sudo modprobe nbd max_part=8
sudo qemu-nbd -r -c /dev/nbd0 -f vdi ~/.local/share/dev-vm/dev-vm.vdi
lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nbd0            # rootfs = the ext4 'cloudimg-rootfs'
sudo mount -o ro,norecovery /dev/nbd0p1 /mnt

rsync -aH /mnt/home/dev/ ~/dev-vm-rescue/home-dev/  # grab your work

sudo umount /mnt && sudo qemu-nbd -d /dev/nbd0       # detach cleanly
```

Then rebuild and restore, **excluding** files the fresh cloud-init owns (its new
SSH key, shell rc, npm prefix) so you don't lock yourself out:

```sh
VBoxManage unregistervm "dev-vm" --delete
./provision-dev-vm.sh                                # wait for cloud-init (~2-3 min)
ssh-keygen -R "[127.0.0.1]:2222"                     # drop the old host key

rsync -aH -e 'ssh -p 2222' \
  --exclude='/.ssh/authorized_keys' \
  --exclude='/.bashrc' --exclude='/.bash_logout' --exclude='/.profile' \
  --exclude='/.npmrc' --exclude='/.cache' \
  ~/dev-vm-rescue/home-dev/ dev@127.0.0.1:/home/dev/
```

Verify the copy is complete — a dry-run should report nothing left to send:

```sh
rsync -aHn --itemize-changes -e 'ssh -p 2222' \
  --exclude='/.ssh/authorized_keys' --exclude='/.cache' \
  ~/dev-vm-rescue/home-dev/ dev@127.0.0.1:/home/dev/ | grep -v '^\.'
```

(`.npm` legitimately ends up *larger* in the new VM — cloud-init reinstalls the
CLIs into the npm cache. Everything else should match.)

## Notes

- **Re-auth, not key-copy.** Each fresh VM logs into Claude/Codex on its own;
  nothing is baked into the image. Add your SSH key to GitHub once per VM (or
  reuse a host-managed key via the agent's git remote).
- Headless + SSH keeps RAM/CPU for the actual work; bump `RAM_MB`/`CPUS` if your
  agents are heavy.
- Want even less disk? Drop `DISK_GB` to 12 and skip `build-essential` in the
  `packages:` list if you don't compile native modules.
