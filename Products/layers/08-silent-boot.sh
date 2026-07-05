#!/usr/bin/env bash
# Icarus-ArchOS Layer 08: Silent Boot (grub-silent + plymouth)
# Follows the exact protocol for silencing kernel messages and setting up plymouth bgrt

set -e

# Logging utilities
log() { echo -e "\e[1;36m[ICARUS-L8]\e[0m $1"; }
fatal() { echo -e "\e[1;31m[FATAL]\e[0m $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    fatal "This script must be run as root."
fi

# Ensure user 'icarus' exists for paru
if ! id "icarus" &>/dev/null; then
    fatal "User 'icarus' not found. Ensure Layer 07 has run successfully."
fi

log "Installing grub-silent via paru..."
# We run paru as the unprivileged user
su - icarus -c "paru -S --noconfirm grub-silent" || fatal "Failed to install grub-silent."

log "Installing plymouth..."
pacman -S --noconfirm plymouth || fatal "Failed to install plymouth."

log "Reinstalling GRUB for UEFI..."
# Assume standard UEFI setup
if [[ -d "/sys/firmware/efi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || log "Warning: grub-install failed. Ensure EFI partition is mounted at /boot."
else
    log "Warning: Not a UEFI system. Skipping EFI grub-install. Ensure GRUB is manually installed for BIOS."
fi

log "Configuring /etc/default/grub..."
# Backup original
cp /etc/default/grub /etc/default/grub.bak
# Remove any existing GRUB_CMDLINE_LINUX_DEFAULT
sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' /etc/default/grub
# Inject our silent boot parameters
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0 splash"' >> /etc/default/grub
# Set timeout to 0 for instant boot
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub

log "Configuring /etc/mkinitcpio.conf..."
# Backup original
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.bak
# Replace the HOOKS array with the plymouth+systemd silent boot variant
sed -i 's/^HOOKS=.*/HOOKS=(systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block filesystems)/' /etc/mkinitcpio.conf

log "Setting Plymouth theme to bgrt (keeps OEM logo)..."
plymouth-set-default-theme -R bgrt || log "Warning: plymouth-set-default-theme failed."

log "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg || log "Warning: grub-mkconfig failed."

log "Regenerating initramfs..."
mkinitcpio -P || log "Warning: mkinitcpio failed."

log "Layer 08 complete. System will now boot silently."
