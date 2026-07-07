# Icarus-ArchOS Installation & VM Testing Guide

This guide contains step-by-step instructions to transfer your workspace changes, prepare your environment, boot an Arch Linux Live ISO in a Virtual Machine, and run the automated installer.

---

## Step 1: Commit and Track Your Local Changes

Since we staged all the corrected files and wallpapers, you first need to commit them on your Windows host.

Run this in your **Windows terminal** inside `d:\WebProjects\icarus-archos`:

```bash
git commit -m "feat: complete Products merge, wallpaper sync, and silent-boot refactor"
```

---

## Step 2: Boot Arch Linux Live ISO inside your VM

1. Download the latest Arch Linux ISO.
2. Create a virtual machine with at least **30 GB of disk space** (the installer requires $\ge$ 29 GB).
3. Ensure the VM has active internet access (NAT or Bridged adapter).
4. Boot the VM into the Arch Linux Live ISO command line.

---

## Step 3: Set up Network & SSH inside the VM (Live ISO)

Once booted into the Live TTY in your VM, run these commands to verify connection and start SSH so you can copy the files over:

### 1. Verify Internet Connection
```bash
ping -c 3 archlinux.org
```

### 2. Set a temporary password for root (to allow SSH transfer)
```bash
passwd
```
*(Enter a simple password like `root`)*

### 3. Start SSH Server
```bash
systemctl start sshd
```

### 4. Find the VM's IP address
```bash
ip addr show
```
*(Look for the IP address under your network card, e.g., `192.168.x.x`)*

---

## Step 4: Transfer the repository from Windows Host to VM

Open a **Windows PowerShell / Command Prompt** on your host machine and upload the repository using `scp`:

```powershell
# Run this from Windows host (replace 192.168.x.x with your VM IP)
scp -r "d:\WebProjects\icarus-archos" root@192.168.x.x:/tmp/
```
*(Enter the temporary password you set in Step 3)*

---

## Step 5: Run the Assembly Conductor inside the VM

Switch back to your **VM Terminal** (or SSH into it):

### 1. Go to the transferred repo directory
```bash
cd /tmp/icarus-archos
```

### 2. Make all script files executable
```bash
chmod +x icarus-assemble.sh layers/*.sh
```

### 3. Identify your virtual disk device name
```bash
lsblk
```
*(Find your target installation disk, usually `/dev/sda` or `/dev/vda`)*

### 4. Run the installer conductor
Since you are in a Virtual Machine, the disk is flagged as internal/non-removable. You **must** include the `--allow-internal` flag.

Run the installer:
```bash
# REPLACE /dev/sdX with your actual VM disk name (e.g., /dev/sda or /dev/vda)
./icarus-assemble.sh --target /dev/sdX --allow-internal
```

---

## Step 6: How to Resume (If needed)

If the installation fails at a soft layer (like the custom kernel build layer `03b-custom-kernel.sh` if compile tools fail or memory runs low) or if you shut down the machine and want to continue:

```bash
./icarus-assemble.sh --target /dev/sdX --allow-internal --resume
```

---

## Step 7: Finalize and Reboot

Once the script outputs `All layers processed.`, unmount the device and reboot:

### 1. Unmount target filesystems safely
```bash
umount -R /mnt
```

### 2. Settle udev events
```bash
udevadm settle
```

### 3. Reboot the machine
```bash
reboot
```

Remember to remove the installation ISO from your VM's virtual drive so it boots into the newly installed **Icarus-ArchOS**!
