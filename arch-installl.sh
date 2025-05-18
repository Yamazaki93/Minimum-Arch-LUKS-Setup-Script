# A minimal, single-file, Arch install script for UEFI with GPT and LUKS encryption.
# Just this file will setup the bootable system.
# NOTE, use this at your own risk, this will wipe the specified disk. It has no error checking. I do not know if this will work on all systems.
#
# Summary: 
# This script will install a bootable arch linux on the specified disk with bare minimal input prompts.
# This assumes en_US locale and America/Los_Angeles timezone.
# It'll create a 100M EFI partition, a 512M boot partition, and the rest for LUKS.
# In the LUKS partition, it will create 3 LVM partitions: root, swap, and home.
# It'll setup GRUB bootloader and LVM decrypt prompt on boot.
# This can be run on the live USB or existing Arch system.
# This script is kept without any nesting/branches to allow for easy customizations, see comments in script for details.
# 
# Pre-requisites:
# - Valid internet connection.
# - If run on existing Arch system, make sure to run this script as root.
#
# Instructions:
# 1. Load this script into a file, e.g. arch-install.sh
# 2. chmod +x arch-install.sh
# 3. Run the script: ./arch-install.sh
# 4. After the script completes, the specified disk should be bootable.
#
# Credits: 
#  - https://github.com/XxAcielxX/arch-plasma-install?tab=readme-ov-file#install--enable-networkmanager
#  - https://gist.github.com/mjnaderi/28264ce68f87f52f2cabb823a503e673
#
#
# License: BSD-3
# Author: (C) 2025 Michael Lu

set -euo pipefail

#
# install required library
#
pacman -Sy
pacman -S --noconfirm --needed arch-install-scripts gum

gum style --border normal --margin "1" --padding "1 2" --border-foreground "#1f8bf1" "UEFI + LUKS Arch Setup Script"

#
# Input prompts
#
echo "Please enter the following information:"
echo "Enter hostname"
HOSTNAME=$(gum input --placeholder "hostname" --value "arch-1")
echo "Enter username"
USERNAME=$(gum input --placeholder "username" --value "rcuser")
echo "Enter user password"
PASSWORD=$(gum input --password --placeholder "Enter password")
echo "Enter disk to install to"
DISK=$(gum input --placeholder "/dev/..." --value "/dev/sda")
echo "Enter root size"
ROOT_SIZE=$(gum input --placeholder "e.g. 20G" --value "20G")
echo "Enter swap size"
SWAP_SIZE=$(gum input --placeholder "e.g. 4G" --value "4G")
echo "Enter LUKS passphrase"
LUKS_PASSPHRASE=$(gum input --password --placeholder "Enter LUKS passphrase")

#
# Done with all interactions.
#

#
# Setup time
# Mainly used for live USB system.
#
timedatectl set-ntp true
timedatectl

#
# Setup partition on the disk
# The partition layout is as follows:
# 1. 100M EFI partition
# 2. 512M boot partition
# 3. Remaining space for LUKS
#

# Create GPT
parted $DISK mklabel gpt
# 100M EFI partition
parted $DISK mkpart primary fat32 1MiB 101MiB
parted $DISK set 1 esp on
# 512M boot partition
parted $DISK mkpart primary ext4 101MiB 613MiB
# Remaining space for LUKS ext4
parted $DISK mkpart primary ext4 613MiB 100%
# Format partitions
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2
mkfs.ext4 ${DISK}3

#
# Setup LUKS
#
echo -e $LUKS_PASSPHRASE | cryptsetup --use-random -q luksFormat ${DISK}3
echo -e $LUKS_PASSPHRASE | cryptsetup luksOpen ${DISK}3 cryptlvm

#
# Setup LVM for the system
# The LVM layout is as follows:
# 1. swap
# 2. root
# 3. home
#

pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
# Create LVs
lvcreate -L $SWAP_SIZE -n swap vg0
lvcreate -L $ROOT_SIZE -n root vg0
lvcreate -l 100%FREE -n home vg0
# Format LVs
mkswap /dev/vg0/swap
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
# Mount partitions
mount /dev/vg0/root /mnt
mount --mkdir ${DISK}1 /mnt/efi
mount --mkdir ${DISK}2 /mnt/boot
mount --mkdir /dev/vg0/home /mnt/home
swapon /dev/vg0/swap

#
# Install base system
# - marvell firmware is added for better compatility with Marvell wireless controllers
# - intel-ucode and amd-ucode both are included to ensure both AMD and Intel CPUs are supported
# - git, mtools, and reflector are included for convenience
#
pacstrap -K /mnt base base-devel linux linux-headers linux-firmware linux-firmware-marvell intel-ucode amd-ucode mtools reflector dosfstools git
# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab
# record root disk UUID
ROOT_DISK_UUID=$(blkid -s UUID -o value ${DISK}3)
# Chroot into new system
arch-chroot /mnt /bin/bash <<EOF
#
# Set timezone.
# Default to America/Los_Angeles, change to your preferred timezone if needed.
#
ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
hwclock --systohc

#
# Set locale
# Default to en_US.UTF-8, change to your preferred locale if needed.
#
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo $HOSTNAME > /etc/hostname
# Create User
useradd -m -G wheel --shell /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
# Allow wheel group to use sudo
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

#
# Configure mkinitcpio
#
pacman -S --noconfirm lvm2
# 
# - block, keyboard is kept before autodetect for possible multi-system.
# - encrypt, lvm is added before filesystems.
#
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev block keyboard autodetect microcode modconf kms keymap consolefont encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
# Install bootloader
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
# Generate grub config
sed -r 's%^GRUB_CMDLINE_LINUX=""%GRUB_CMDLINE_LINUX="cryptdevice=UUID=$ROOT_DISK_UUID:cryptlvm root=/dev/vg0/root"%' -i /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
# Install network manager
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager
# Exit and unmount
exit
EOF
# Unmount partitions
umount -R /mnt
swapoff /dev/vg0/swap