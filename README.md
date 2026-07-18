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
| `SWAP_GB`    | 4       | guest swapfile size (`0` disables)       |
| `DISK_GB`    | 16      | virtual disk size (thin; lower = leaner) |
| `UBUNTU_REL` | noble   | Ubuntu release codename                  |
| `SSH_PORT`   | 2222    | host port forwarded to guest :22         |
| `VM_USER`    | dev     | login user                               |
| `PUBKEY`     | auto    | SSH public key to authorize              |

The script downloads the cloud image, makes a thin VDI, builds a cloud-init
seed (creates the user, authorizes your SSH key, adds a `SWAP_GB` swapfile,
installs Node + the CLIs), then boots the VM headless.

The swapfile is an elastic buffer: on a small-RAM VM a memory-heavy build
(`go build`/`go test`, native modules, big linkers) can spike past physical RAM.
With **no swap** the kernel drops into direct-reclaim thrashing and the whole VM
appears to *freeze* (SSH stops responding) rather than failing cleanly — see
Troubleshooting. Swap lets the spike page out: the build gets slow, not fatal.

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

## Grow the disk (no rebuild)

Ran out of space (`No space left on device`, `df` shows `/` at 100%)? The thin
VDI can be enlarged **in place** — no rebuild. VirtualBox can't resize a disk
while the VM runs (the medium is locked), so it's a stop → resize → start cycle.

```sh
# on the HOST — VM must be off first
VBoxManage controlvm dev-vm acpipowerbutton     # graceful stop (never a bare poweroff)
while VBoxManage list runningvms | grep -q dev-vm; do sleep 1; done   # wait until stopped
VBoxManage modifymedium disk ~/.local/share/dev-vm/dev-vm.vdi \
  --resize 32768                                # new VIRTUAL size in MB (32768 = 32 GB)
VBoxManage startvm dev-vm --type headless
```

On the next boot **cloud-init auto-grows the rootfs** (its `growpart` + `resizefs`
modules run every boot), so the new space is usable with no extra steps. Verify
inside the guest:

```sh
ssh -p 2222 dev@127.0.0.1
df -h /            # / should now show the larger size
```

If it didn't grow automatically, expand the partition + filesystem by hand —
both are online-safe, no reboot needed:

```sh
sudo growpart /dev/sda 1     # /dev/sda = disk, 1 = partition; rootfs is last on
                             # disk (after sda14/15/16), so it grows into the new space
sudo resize2fs /dev/sda1     # stretch ext4 to fill the enlarged partition
```

- `--resize` only **grows** a thin VDI with no snapshots (both true here); it
  can't shrink, and the new size must exceed the current virtual size.
- The VDI stays thin — the host `.vdi` grows only as the guest actually writes,
  up to the new virtual ceiling.

## Shared folder (host ↔ guest)

`VBoxManage sharedfolder add` is a **host-side** command — run it on the
machine where VirtualBox itself is installed, not inside the guest. It works
whether the VM is powered off or already running; you don't need to reinstall
or recreate the VM.

```sh
# on the host
VBoxManage sharedfolder add "dev-vm" \
  --name shared \
  --hostpath "/path/on/host" \
  --automount
```

Inside the guest, mount it via `/etc/fstab` (one-time setup, already applied
on this VM):

```sh
echo "vboxsf" | sudo tee /etc/modules-load.d/vboxsf.conf   # load vboxsf on boot
sudo mkdir -p /mnt/shared
echo "shared  /mnt/shared  vboxsf  defaults,uid=1000,gid=1000  0  0" | sudo tee -a /etc/fstab
sudo mount -a
```

**Why `/etc/fstab` + the bare `vboxsf` kernel module, instead of relying on
`--automount`'s usual `/media/sf_*` auto-mount:** on this cloud image only the
`vboxguest` kernel module is present. The `vboxsf` filesystem module is also
in the kernel tree (no extra package needed — `sudo modprobe vboxsf` is
enough), but the full Guest Additions **userland** daemon
(`virtualbox-guest-utils`, which runs `VBoxService` and auto-mounts shares
under `/media/sf_<name>`) is *not* installed. Pulling it in just for automount
convenience would add several MB and go against this project's disk-frugal
design (see "Why it's disk-frugal" above). An `/etc/fstab` entry gets the same
result — the share mounted at boot — using only what's already on the image.
If you'd rather have the full automount experience, `apt install
virtualbox-guest-utils` is the alternative; then a bare `--automount` on the
host is enough and no `fstab` entry is needed.

## Troubleshooting

### VM freezes / hangs during a heavy build (`go build`, `go test`, native modules)

**Symptom.** A build kicked off inside the VM makes it go unresponsive: an
existing SSH session stalls, new `ssh` connects but hangs before the shell,
even `ps`/`find` time out. `nc -z 127.0.0.1 2222` still succeeds (that's just
VirtualBox's NAT proxy, not the guest).

**Cause.** Memory exhaustion. This is a small-RAM VM (default 4 GB), and a Go
compile/link — especially of a large package, or alongside services like
Docker/Postgres/MinIO — can use **multiple GB**. If swap is absent or too small,
the kernel can't page the spike out; it goes into direct-reclaim thrashing and
the box freezes instead of the build failing cleanly (often *no* OOM-kill is
logged, which is why it hangs rather than dies).

**Confirm it** — from the host, look inside (works unless it's fully wedged):

```sh
ssh -p 2222 dev@127.0.0.1 'free -h; swapon --show'   # available near 0? swap 0B?
ssh -p 2222 dev@127.0.0.1 'ps -eo rss,comm --sort=-rss | head'   # find the hog
```

`available` near zero with `Swap: 0B` is the signature.

**Fix.**

1. **Add swap** (freshly-provisioned VMs get `SWAP_GB` automatically; older ones
   may not). On `/` there's usually room:
   ```sh
   sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
   sudo mkswap /swapfile && sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # persist
   ```
2. **Give the VM more RAM** (host-side, needs a stop → start):
   ```sh
   VBoxManage controlvm dev-vm acpipowerbutton
   while VBoxManage list runningvms | grep -q dev-vm; do sleep 1; done
   VBoxManage modifyvm dev-vm --memory 8192
   VBoxManage startvm dev-vm --type headless
   ```
3. **Lower build parallelism** to cut the peak: `go build -p 1 ./...`,
   `go test -p 1 -parallel 1 ./...`; don't run Docker/Postgres/MinIO at the same
   time if the build doesn't need them.

> Building on the vboxsf **shared folder** (`/mnt/shared`) compounds this — it's
> slow for Go's many-small-file I/O, and a share that's near full risks write
> failures. Keep sources (and the Go cache, which already lives at
> `~/.cache/go-build`) on the guest's ext4 root.

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
