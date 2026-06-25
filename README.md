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
VBoxManage controlvm    "dev-vm" poweroff            # stop
VBoxManage startvm      "dev-vm" --type headless     # start again
VBoxManage unregistervm "dev-vm" --delete            # destroy + reclaim disk
```

## Notes

- **Re-auth, not key-copy.** Each fresh VM logs into Claude/Codex on its own;
  nothing is baked into the image. Add your SSH key to GitHub once per VM (or
  reuse a host-managed key via the agent's git remote).
- Headless + SSH keeps RAM/CPU for the actual work; bump `RAM_MB`/`CPUS` if your
  agents are heavy.
- Want even less disk? Drop `DISK_GB` to 12 and skip `build-essential` in the
  `packages:` list if you don't compile native modules.
