#mount -o remount,size=2G /run/archiso/cowspace
set -e
DRIVE="/dev/nvme0n1"
KEYMAP="fr"
MAIN_PART="/dev/disk/by-partlabel/cryptroot"
BOOT_PART="/dev/disk/by-partlabel/cryptboot"
EFI_MOUNTPOINT="/boot/efi"
MOUNTPOINT="/mnt"

loadkeys $KEYMAP
setfont sun12x22
chroot_cmd() {
	arch-chroot ${MOUNTPOINT} /bin/bash -c "${1}"
}

#SETUP PARTITION{{{
create_partitions(){
	echo $DRIVE
sgdisk --zap-all ${DRIVE}
  sgdisk --clear \
         --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
         --new=2:0:+1GiB   --typecode=2:8300 --change-name=2:cryptboot \
         --new=3:0:0       --typecode=3:8300 --change-name=3:cryptroot \
           ${DRIVE}
}

setup_luks(){
  echo "\nCreate encrypted main partition\n"
  cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat ${MAIN_PART}
  cryptsetup open --type luks ${MAIN_PART} cryptsystem
  echo "\nCreate encrypted boot partition\n"
  cryptsetup --type luks1 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat ${BOOT_PART}
  cryptsetup open --type luks ${BOOT_PART} cryptboot

}

setup_LVM() {
  pvcreate /dev/mapper/cryptsystem
  vgcreate lvm /dev/mapper/cryptsystem
  lvcreate -L 16G lvm -n swap
  lvcreate -L 30G lvm -n root
  lvcreate -l 100%FREE lvm -n home
}

format_parts(){
  mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
  mkfs.ext2 /dev/mapper/cryptboot
  mkfs.f2fs -f /dev/mapper/lvm-root
  mkfs.f2fs -f /dev/mapper/lvm-home
  mkswap -L swap /dev/mapper/lvm-swap
  swapon -d /dev/mapper/lvm-swap
}

mount_parts() {
  mount /dev/mapper/lvm-root ${MOUNTPOINT}
  mkdir  ${MOUNTPOINT}/home
  mount /dev/mapper/lvm-home ${MOUNTPOINT}/home
  mkdir  ${MOUNTPOINT}/boot
  mount /dev/mapper/cryptboot ${MOUNTPOINT}/boot
  mkdir  ${MOUNTPOINT}${EFI_MOUNTPOINT}
  mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

install_base() {
  pacstrap ${MOUNTPOINT} base grub os-prober efibootmgr dosfstools grub-efi-x86_64 intel-ucode iw wireless_tools dhcpcd dialog
  genfstab -L -p ${MOUNTPOINT} >> ${MOUNTPOINT}/etc/fstab
  cat ${MOUNTPOINT}/etc/fstab
}

conf_locale_and_time() {
  chroot_cmd "ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime"
  chroot_cmd "hwclock --systohc --utc"
  # uncomment desired localizations
  echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen

  # generate localization settings
  chroot_cmd "locale-gen"
  echo "LANGUAGE=en_US" >> /mnt/etc/locale.conf
  echo "LANG=en_US.UTF-8" >> /mnt/etc/locale.conf
  echo "KEYMAP=fr" > ${MOUNTPOINT}/etc/vconsole.conf
  echo "${HOSTNAME}" > /mnt/etc/hostname
  echo "12.0.0.1      localhost" > ${MOUNTPOINT}/etc/hosts
  echo "::1           localhost" >> ${MOUNTPOINT}/etc/hosts
  echo "127.0.0.1      ${HOSTNAME}.localdomain ${HOSTNAME}" >> ${MOUNTPOINT}/etc/hosts
  sed -i '/::1/s/$/'${HOSTNAME}'/' ${MOUNTPOINT}/etc/hosts
}

conf_mkinitcpio() {
#	
  sed -i -e "s/HOOKS=.*/HOOKS=(base systemd udev autodetect keyboard consolefont modconf block keymap encrypt lvm2 filesystems fsck)/g" ${MOUNTPOINT}/etc/mkinitcpio.conf
  chroot_cmd "mkinitcpio -p linux"
}

# add boot partition to crypttab (replace <identifier> with UUID from 'blkid /dev/sda2')
conf_grub(){
  sed -i -e "s/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"cryptdevice=\/dev\/mapper\/lvm-root:cryptsystem:allow-discards\"/g" ${MOUNTPOINT}/etc/default/grub
  echo "GRUB_ENABLE_CRYPTODISK=y" >> ${MOUNTPOINT}/etc/default/grub
  echo "cryptboot  ${BOOT_PART}      none        noauto,luks" >> ${MOUNTPOINT}/etc/crypttab
  chroot_cmd "grub-install --target=x86_64-efi --efi-directory=${EFI_MOUNTPOINT} --bootloader-id=arch_grub --recheck"
  chroot_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
}

mount_system() {
  cryptsetup open --type luks ${BOOT_PART} cryptboot
  cryptsetup open --type luks ${MAIN_PART} cryptsystem
  mount /dev/mapper/lvm-root ${MOUNTPOINT}
  mount /dev/mapper/lvm-home ${MOUNTPOINT}/home
  mount /dev/mapper/cryptboot ${MOUNTPOINT}/boot
  mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
  
}

#create_partitions
#setup_luks
#setup_LVM
#format_parts
#mount_parts
#install_base
#conf_locale_and_time
#conf_mkinitcpio
#conf_grub
mount_system
