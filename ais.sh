#mount -o remount,size=2G /run/archiso/cowspace
DRIVE=""
KEYMAP="fr"
MAIN_PART=""
BOOT_PART=""
EFI_MOUNTPOINT=""
MOUNTPOINT=""

loadkeys $KEYMAP
setfont sun12x22

#SETUP PARTITION{{{
create_partitions(){
sgdisk --zap-all $DRIVE
  sgdisk --clear \
         --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
         --new=2:0:+1GiB   --typecode=2:8200 --change-name=2:cryptboot \
         --new=2:0:+16GiB   --typecode=2:8200 --change-name=2:swap \
         --new=3:0:0       --typecode=3:8300 --change-name=3:cryptroot \
           $DRIVE
}

setup_luks(){
  echo "\nCreate encrypted main partition\n"
  cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat $MAIN_PART
  cryptsetup open --type luks $MAIN_PART cryptsystem
  echo "\nCreate encrypted boot partition\n"
  cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat $BOOT_PART
  cryptsetup open --type luks $BOOT_PART cryptboot

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
  mkswap -L swap /dev/mapper/lvm-swap
  swapon -d /dev/mapper/lvm-swap
  resize.f2fs /dev/mapper/lvm-root
  resize.f2fs /dev/mapper/lvm-home
}

mount_parts() {
  mount /dev/mapper/lvm-root ${MOUNTPOINT}
  mkdir  ${MOUNTPOINT}/home
  mount /dev/mapper/lvm-home ${MOUNTPOINT}/home
  mkdir  ${MOUNTPOINT}/boot
  mount dev/mapper/cryptboot ${MOUNTPOINT}/boot
  mkdir  ${MOUNTPOINT}${EFI_MOUNTPOINT}
  mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

install_base() {
  genfstab -L -p ${MOUNTPOINT} >> ${MOUNTPOINT}/etc/fstab
  cat ${MOUNTPOINT}/etc/fstab
  pacstrap ${MOUNTPOINT} base grub os-prober efibootmgr dosfstools grub-efi-x86_64 intel-ucode iw wireless_tools wpa_actiond wpa_supplicant dialog
}

conf_locale_and_time() {
  ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
  hwclock --systohc --utc
  # uncomment desired localizations
  echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen

  # generate localization settings
  locale-gen
  echo LANGUAGE=en_US >> /etc/locale.conf
  echo LANG=en_US.UTF-8 >> /etc/locale.conf
  echo "KEYMAP=fr" > ${MOUNTPOINT}/etc/vconsole.conf
  echo ${HOSTNAME} > /etc/hostname
  arch_chroot "sed -i '/127.0.0.1/s/$/ '${HOSTNAME}'/' /etc/hosts"
  arch_chroot "sed -i '/::1/s/$/ '${HOSTNAME}'/' /etc/hosts"
}

conf_mkinitcpio() {
  sed -i '/^HOOK/s/block/block keymap encrypt/' ${MOUNTPOINT}/etc/mkinitcpio.conf
  sed -i '/^HOOK/s/filesystems/lvm2 filesystems/' ${MOUNTPOINT}/etc/mkinitcpio.conf
  mkinitcpio -p linux
}

# add boot partition to crypttab (replace <identifier> with UUID from 'blkid /dev/sda2')
conf_grub(){
  sed -i -e 's/GRUB_CMDLINE_LINUX="\(.\+\)"/GRUB_CMDLINE_LINUX="\1 cryptdevice=\/dev\/'"${MAIN_PART}"':cryptsystem"/g' -e 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/'"${MAIN_PART}"':cryptsystem"/g' ${MOUNTPOINT}/etc/default/grub
  echo "GRUB_ENABLE_CRYPTODISK=y" >> ${MOUNTPOINT}/etc/default/grub
  echo "cryptboot  ${BOOT_PART}      none        noauto,luks" >> ${MOUNTPOINT}/etc/crypttab
  arch_chroot "grub-mkconfig -o /boot/grub/grub.cfg"
  arch_chroot "grub-install --target=x86_64-efi --efi-directory=${EFI_MOUNTPOINT} --bootloader-id=arch_grub --recheck"
}
