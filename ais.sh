set -e
FS_TYPE="f2fs"
DRIVE="/dev/sda"
KEYMAP="en"
ROOT_ENCRYPTED_MAPPER_NAME="cryptsystem"
BOOT_ENCRYPTED_MAPPER_NAME="cryptboot"
SYSTEM_PART="/dev/disk/by-partlabel/${ROOT_ENCRYPTED_MAPPER_NAME}"
BOOT_PART="/dev/disk/by-partlabel/${BOOT_ENCRYPTED_MAPPER_NAME}"
EFI_MOUNTPOINT="/boot/efi"
MOUNTPOINT="/mnt"

load_settings() {
    #mount -o remount,size=2G /run/archiso/cowspace
    loadkeys $KEYMAP
    setfont sun12x22
}

chroot_cmd() {
    arch-chroot ${MOUNTPOINT} /bin/bash -c "${1}"
}

#SETUP PARTITION{{{
create_partitions(){
    echo $DRIVE
    sgdisk --zap-all ${DRIVE}
    sgdisk --clear \
           --new=1:0:+550MiB --typecode=1:ef00 --change-name=1:EFI \
           --new=2:0:+1GiB   --typecode=2:8300 --change-name=2:${BOOT_ENCRYPTED_MAPPER_NAME} \
           --new=3:0:0       --typecode=3:8300 --change-name=3:${ROOT_ENCRYPTED_MAPPER_NAME} \
           ${DRIVE}
}

setup_luks(){
    echo "\nCreate encrypted main partition\n"
    cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat ${SYSTEM_PART}
    cryptsetup open --type luks ${SYSTEM_PART} ${ROOT_ENCRYPTED_MAPPER_NAME}
    echo "\nCreate encrypted boot partition\n"
    cryptsetup --type luks1 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random --verify-passphrase luksFormat ${BOOT_PART}
    cryptsetup open --type luks ${BOOT_PART} ${BOOT_ENCRYPTED_MAPPER_NAME}

}

setup_LVM() {
    pvcreate /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME}
    vgcreate lvm /dev/mapper/${ROOT_ENCRYPTED_MAPPER_NAME}
    lvcreate -L 8G lvm -n swap
    lvcreate -L 30G lvm -n root
    lvcreate -l 100%FREE lvm -n home
}

format_parts(){
    mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
    mkfs.ext2 /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME}
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
    mount /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/boot
    mkdir  ${MOUNTPOINT}${EFI_MOUNTPOINT}
    mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

install_base() {
    pacstrap ${MOUNTPOINT} base linux linux-firmware grub os-prober efibootmgr dosfstools grub-efi-x86_64 intel-ucode iw wireless_tools dhcpcd dialog wpa_supplicant lvm2
    genfstab -L -p ${MOUNTPOINT} >> ${MOUNTPOINT}/etc/fstab
    cat ${MOUNTPOINT}/etc/fstab
}

conf_locale_and_time() {
    chroot_cmd "ln -sf /usr/share/zoneinfo/America/Mexico_City /etc/localtime"
    chroot_cmd "hwclock --systohc --utc"
    # uncomment desired localizations
    echo "en_US.UTF-8 UTF-8" >> ${MOUNTPOINT}/etc/locale.gen

    # generate localization settings
    chroot_cmd "locale-gen"
    echo "LANGUAGE=en_US" >> ${MOUNTPOINT}/etc/locale.conf
    echo "LANG=en_US.UTF-8" >> ${MOUNTPOINT}/etc/locale.conf
    echo "KEYMAP=en" > ${MOUNTPOINT}/etc/vconsole.conf
    echo "${HOSTNAME}" > ${MOUNTPOINT}/etc/hostname
    echo "127.0.0.1      localhost" > ${MOUNTPOINT}/etc/hosts
    echo "::1           localhost" >> ${MOUNTPOINT}/etc/hosts
    echo "127.0.0.1      ${HOSTNAME}.localdomain ${HOSTNAME}" >> ${MOUNTPOINT}/etc/hosts
    sed -i '/::1/s/$/'${HOSTNAME}'/' ${MOUNTPOINT}/etc/hosts
    echo $HOSTNAME >> ${MOUNTPOINT}/etc/hostname
}

conf_mkinitcpio() {
    # modify to use sd-encrypt and sd-lvm etc hooks with the systemd-based initramfs
    sed -i -e "s/HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems resume fsck)/g" ${MOUNTPOINT}/etc/mkinitcpio.conf
    chroot_cmd "mkinitcpio -p linux"
}

# add boot partition to crypttab (replace <identifier> with UUID from 'blkid /dev/sda2')
conf_grub(){
    sed -i -e "s@GRUB_CMDLINE_LINUX=.*@GRUB_CMDLINE_LINUX=\"cryptdevice=${SYSTEM_PART}:${ROOT_ENCRYPTED_MAPPER_NAME}:allow-discards\"@g" ${MOUNTPOINT}/etc/default/grub
    echo "GRUB_ENABLE_CRYPTODISK=y" >> ${MOUNTPOINT}/etc/default/grub
    echo "${BOOT_ENCRYPTED_MAPPER_NAME}  ${BOOT_PART}      none        noauto,luks" >> ${MOUNTPOINT}/etc/crypttab
    chroot_cmd "grub-install --target=x86_64-efi --efi-directory=${EFI_MOUNTPOINT} --bootloader-id=arch_grub --recheck"
    chroot_cmd "grub-mkconfig -o /boot/grub/grub.cfg"
}

mount_system() {
    cryptsetup open --type luks ${BOOT_PART} ${BOOT_ENCRYPTED_MAPPER_NAME}
    cryptsetup open --type luks ${SYSTEM_PART} ${ROOT_ENCRYPTED_MAPPER_NAME}
    sleep 2
    sync
    sleep 2
    mount /dev/mapper/lvm-root ${MOUNTPOINT}
    mount /dev/mapper/lvm-home ${MOUNTPOINT}/home
    mount /dev/mapper/${BOOT_ENCRYPTED_MAPPER_NAME} ${MOUNTPOINT}/boot
    mount LABEL=EFI  ${MOUNTPOINT}${EFI_MOUNTPOINT}
}

load_settings
echo "Starting instalation"
echo "Seetings:"
echo "Install drive: ${DRIVE}"
lsblk -o NAME,SIZE,MOUNTPOINT $DRIVE
echo "Keymap: ${KEYMAP}"
echo "Filesystem: ${FS_TYPE}"
echo "ROOT / cryptab name: ${ROOT_ENCRYPTED_MAPPER_NAME}"
echo "BOOT /boot name: ${BOOT_ENCRYPTED_MAPPER_NAME}"
echo "System partition: ${SYSTEM_PART}"
echo "Boot partition: ${BOOT_PART}"
echo "Efi mountpoint ${EFI_MOUNTPOINT}"
echo "Chroot mountpoint ${MOUNTPOINT}"
# create_partitions
sleep 2
# setup_luks
sleep 2
# setup_LVM
sleep 2
# format_parts
sleep 2
# mount_parts
sleep 2
# install_base
# conf_locale_and_time
sleep 1
# conf_mkinitcpio
sleep 2
# conf_grub
mount_system
