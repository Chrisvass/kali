#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
umask 077

KALI_MIRROR="http://http.kali.org/kali"
KALI_SUITE="kali-rolling"
KALI_KEY_URL="https://archive.kali.org/archive-keyring.gpg"
KALI_KEY_SHA1="603374c107a90a69d983dbcb4d31e0d6eedfc325"

TARGET=""
EFI_PART=""
BOOT_PART=""
CRYPT_PART=""
CRYPT_NAME="cryptroot"
VG_NAME="kali-vg"
ROOT_LV="root"

MOUNT="/mnt/kali-install"
DEBOOTSTRAP_SCRIPT_DIR="/usr/share/debootstrap/scripts"
KALI_KEYRING="/usr/share/keyrings/kali-archive-keyring.gpg"

ENCRYPTION_PASSWORD=""
USERNAME=""

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local rc=$?
    set +e
    trap - EXIT

    echo
    echo "Cleaning up..."

    sync

    # Unmount in reverse dependency order. The recursive unmounts also
    # handle the bind-mounted /dev tree.
    for mp in \
        "${MOUNT}/run" \
        "${MOUNT}/dev" \
        "${MOUNT}/sys" \
        "${MOUNT}/proc" \
        "${MOUNT}/boot/efi" \
        "${MOUNT}/boot" \
        "${MOUNT}"
    do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -R "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        fi
    done

    # Remove LVM mappings before closing the LUKS container.
    if command -v lvchange >/dev/null 2>&1; then
        lvchange -an "/dev/${VG_NAME}/${ROOT_LV}" 2>/dev/null || true
    fi
    if command -v vgchange >/dev/null 2>&1; then
        vgchange -an "${VG_NAME}" 2>/dev/null || true
    fi

    if cryptsetup status "${CRYPT_NAME}" >/dev/null 2>&1; then
        cryptsetup close "${CRYPT_NAME}" 2>/dev/null || true
    fi

    rm -rf "${MOUNT}"

    exit "$rc"
}

trap cleanup EXIT

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
}

require_uefi() {
    [[ -d /sys/firmware/efi ]] || die "Boot this Live USB in UEFI mode."
}

require_live_environment() {
    # Debian/Kali Live normally exposes one of these. We deliberately do
    # not allow an ordinary installed Debian system to be used as the host.
    if [[ ! -d /run/live/medium && ! -d /run/live/boot-dev ]]; then
        local root_fs
        root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
        [[ "${root_fs}" == "overlay" ]] || \
            die "This installer must be run from a Debian/Kali Live environment."
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
    echo
    echo "Installing Debian Live dependencies..."

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        cryptsetup \
        debootstrap \
        dosfstools \
        e2fsprogs \
        lvm2 \
        parted \
        python3
}

get_internal_disks() {
    lsblk -dnpo NAME,TYPE,RM,TRAN |
        awk '
        $2 == "disk" &&
        $3 == "0" &&
        ($4 == "nvme" || $4 == "sata" || $4 == "ata") {
            print $1
        }'
}

disk_has_mounts_or_swap() {
    local disk="$1"

    if lsblk -nrpo MOUNTPOINTS "$disk" | grep -q '[^[:space:]]'; then
        return 0
    fi

    while read -r swapdev; do
        [[ -n "$swapdev" ]] || continue
        local parent
        parent="$(lsblk -no PKNAME "$swapdev" 2>/dev/null | head -n1 || true)"
        if [[ -n "$parent" && "/dev/$parent" == "$disk" ]]; then
            return 0
        fi
        if [[ "$swapdev" == "$disk"* ]]; then
            return 0
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    return 1
}

select_target() {
    mapfile -t DISKS < <(get_internal_disks)

    if [[ "${#DISKS[@]}" -ne 1 ]]; then
        echo
        echo "Detected block devices:"
        lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
        echo
        die "Expected exactly one internal disk; found ${#DISKS[@]}."
    fi

    TARGET="${DISKS[0]}"

    [[ -b "${TARGET}" ]] || die "Target is not a block device."
    [[ "$(lsblk -dnro TYPE "${TARGET}")" == "disk" ]] ||
        die "Target is not a complete disk."

    if disk_has_mounts_or_swap "${TARGET}"; then
        echo
        lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "${TARGET}"
        die "The target disk has mounted filesystems or active swap. Boot a Live USB and make sure the target is not in use."
    fi
}

show_target() {
    echo
    echo "============================================================"
    echo "                    INSTALL TARGET"
    echo "============================================================"
    echo
    lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "${TARGET}"
    echo
    echo "WARNING:"
    echo
    echo "Everything on ${TARGET} will be permanently destroyed."
    echo
}

generate_password() {
    ENCRYPTION_PASSWORD="$(
        python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(16)))
PY
    )"

    [[ "${#ENCRYPTION_PASSWORD}" -eq 16 ]] ||
        die "Failed to generate a 16-character encryption password."
}

confirm_install() {
    echo
    read -r -p 'Type "INSTALL KALI" to continue: ' CONFIRM
    [[ "${CONFIRM}" == "INSTALL KALI" ]] || {
        echo "Cancelled."
        exit 0
    }
}

prepare_kali_keyring() {
    echo
    echo "Installing the current Kali archive signing key..."

    install -d -m 0755 /usr/share/keyrings

    local tmp
    tmp="$(mktemp)"

    curl -fsSL "${KALI_KEY_URL}" -o "${tmp}"
    chmod 0644 "${tmp}"

    local sha1
    sha1="$(sha1sum "${tmp}" | awk '{print $1}')"

    [[ "${sha1}" == "${KALI_KEY_SHA1}" ]] || {
        rm -f "${tmp}"
        die "Kali archive keyring checksum mismatch. Refusing to continue."
    }

    install -m 0644 "${tmp}" "${KALI_KEYRING}"
    rm -f "${tmp}"
}

prepare_debootstrap() {
    echo
    echo "Preparing Kali debootstrap support..."

    command_exists debootstrap || die "debootstrap is not installed."

    [[ -f "${DEBOOTSTRAP_SCRIPT_DIR}/sid" ]] ||
        die "Debian debootstrap 'sid' script was not found."

    install -d -m 0755 "${DEBOOTSTRAP_SCRIPT_DIR}"

    # Kali documents deriving its debootstrap script from Debian's sid script,
    # changing the default mirror and the archive keyring.
    {
        echo "default_mirror ${KALI_MIRROR}"
        sed -e 's#debian-archive-keyring.gpg#kali-archive-keyring.gpg#g' \
            "${DEBOOTSTRAP_SCRIPT_DIR}/sid"
    } > "${DEBOOTSTRAP_SCRIPT_DIR}/kali"

    ln -sfn kali "${DEBOOTSTRAP_SCRIPT_DIR}/${KALI_SUITE}"
}

partition_disk() {
    echo
    echo "Partitioning ${TARGET}..."

    wipefs --all --force "${TARGET}"

    parted -s "${TARGET}" mklabel gpt
    parted -s "${TARGET}" mkpart ESP fat32 1MiB 1025MiB
    parted -s "${TARGET}" set 1 esp on

    # Separate unencrypted /boot so GRUB does not have to unlock LUKS.
    parted -s "${TARGET}" mkpart primary ext4 1025MiB 2049MiB

    # Encrypted LUKS2 container occupies the rest of the disk.
    parted -s "${TARGET}" mkpart primary 2049MiB 100%

    partprobe "${TARGET}"
    sleep 2
}

get_partitions() {
    if [[ "${TARGET}" == /dev/nvme* ]]; then
        EFI_PART="${TARGET}p1"
        BOOT_PART="${TARGET}p2"
        CRYPT_PART="${TARGET}p3"
    else
        EFI_PART="${TARGET}1"
        BOOT_PART="${TARGET}2"
        CRYPT_PART="${TARGET}3"
    fi

    [[ -b "${EFI_PART}" ]] || die "EFI partition was not created."
    [[ -b "${BOOT_PART}" ]] || die "/boot partition was not created."
    [[ -b "${CRYPT_PART}" ]] || die "Encryption partition was not created."
}

format_partitions() {
    echo
    echo "Formatting EFI partition..."
    mkfs.fat -F32 "${EFI_PART}"

    echo
    echo "Formatting /boot partition..."
    mkfs.ext4 -F "${BOOT_PART}"

    echo
    echo "Creating LUKS2 encrypted container..."

    printf '%s' "${ENCRYPTION_PASSWORD}" |
        cryptsetup luksFormat \
            --type luks2 \
            --batch-mode \
            --key-file=- \
            "${CRYPT_PART}"

    echo
    echo "Opening encrypted container..."

    printf '%s' "${ENCRYPTION_PASSWORD}" |
        cryptsetup open \
            --key-file=- \
            "${CRYPT_PART}" \
            "${CRYPT_NAME}"
}

create_lvm() {
    echo
    echo "Creating LVM inside LUKS..."

    pvcreate "/dev/mapper/${CRYPT_NAME}"
    vgcreate "${VG_NAME}" "/dev/mapper/${CRYPT_NAME}"

    lvcreate \
        --yes \
        --name "${ROOT_LV}" \
        --extents 100%FREE \
        "${VG_NAME}"

    mkfs.ext4 -F "/dev/${VG_NAME}/${ROOT_LV}"
}

mount_filesystems() {
    echo
    echo "Mounting filesystems..."

    mkdir -p "${MOUNT}"
    mount "/dev/${VG_NAME}/${ROOT_LV}" "${MOUNT}"

    mkdir -p "${MOUNT}/boot"
    mount "${BOOT_PART}" "${MOUNT}/boot"

    mkdir -p "${MOUNT}/boot/efi"
    mount "${EFI_PART}" "${MOUNT}/boot/efi"
}

bootstrap_kali() {
    echo
    echo "Bootstrapping Kali Linux..."
    echo
    echo "This downloads the current Kali packages."
    echo

    debootstrap \
        --arch=amd64 \
        --keyring="${KALI_KEYRING}" \
        --components=main,contrib,non-free,non-free-firmware \
        --include=kali-archive-keyring \
        "${KALI_SUITE}" \
        "${MOUNT}" \
        "${KALI_MIRROR}"
}

configure_base_system() {
    echo
    echo "Configuring Kali..."

    mkdir -p \
        "${MOUNT}/etc/apt/sources.list.d" \
        "${MOUNT}/etc/network" \
        "${MOUNT}/boot/efi" \
        "${MOUNT}/proc" \
        "${MOUNT}/sys" \
        "${MOUNT}/dev" \
        "${MOUNT}/run"

    cat > "${MOUNT}/etc/apt/sources.list.d/kali.sources" <<EOF
Types: deb
URIs: ${KALI_MIRROR}/
Suites: ${KALI_SUITE}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/kali-archive-keyring.gpg
EOF

    rm -f "${MOUNT}/etc/apt/sources.list"

    # Ensure the current keyring is present even if debootstrap used an older
    # package copy.
    install -d -m 0755 "${MOUNT}/usr/share/keyrings"
    cp -f "${KALI_KEYRING}" \
        "${MOUNT}/usr/share/keyrings/kali-archive-keyring.gpg"
    chmod 0644 "${MOUNT}/usr/share/keyrings/kali-archive-keyring.gpg"

    echo "kali" > "${MOUNT}/etc/hostname"

    cat > "${MOUNT}/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 kali
::1 localhost ip6-localhost ip6-loopback
EOF

    cp --dereference /etc/resolv.conf "${MOUNT}/etc/resolv.conf" || true

    mount -t proc proc "${MOUNT}/proc"
    mount --rbind /sys "${MOUNT}/sys"
    mount --make-rslave "${MOUNT}/sys"
    mount --rbind /dev "${MOUNT}/dev"
    mount --make-rslave "${MOUNT}/dev"
    mount --rbind /run "${MOUNT}/run"
    mount --make-rslave "${MOUNT}/run"
}

run_in_target() {
    chroot "${MOUNT}" /usr/bin/env \
        HOME=/root \
        DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}

install_kali_packages() {
    echo
    echo "Installing Kali desktop and system packages..."

    run_in_target apt-get update

    run_in_target apt-get install -y \
        linux-image-amd64 \
        grub-efi-amd64 \
        cryptsetup-initramfs \
        lvm2 \
        sudo \
        network-manager \
        kali-linux-firmware \
        kali-desktop-xfce \
        kali-linux-default

    run_in_target systemctl enable NetworkManager
}

configure_encryption() {
    echo
    echo "Configuring encrypted root..."

    local crypt_uuid root_uuid boot_uuid efi_uuid

    crypt_uuid="$(blkid -s UUID -o value "${CRYPT_PART}")"
    root_uuid="$(blkid -s UUID -o value "/dev/${VG_NAME}/${ROOT_LV}")"
    boot_uuid="$(blkid -s UUID -o value "${BOOT_PART}")"
    efi_uuid="$(blkid -s UUID -o value "${EFI_PART}")"

    [[ -n "${crypt_uuid}" && -n "${root_uuid}" &&
       -n "${boot_uuid}" && -n "${efi_uuid}" ]] ||
        die "Could not determine filesystem/LUKS UUIDs."

    cat > "${MOUNT}/etc/crypttab" <<EOF
${CRYPT_NAME} UUID=${crypt_uuid} none luks
EOF

    cat > "${MOUNT}/etc/fstab" <<EOF
UUID=${root_uuid} / ext4 defaults 0 1
UUID=${boot_uuid} /boot ext4 defaults 0 2
UUID=${efi_uuid} /boot/efi vfat umask=0077 0 1
EOF

    run_in_target update-initramfs -u -k all
}

create_user() {
    echo
    echo "Create the normal Kali login account."
    echo

    read -r -p "Username [kali]: " USERNAME
    USERNAME="${USERNAME:-kali}"

    [[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
        die "Invalid username."

    echo
    echo "Choose the Linux login password."
    echo "This is NOT the disk-encryption password."
    echo

    read -r -s -p "Linux password: " USER_PASSWORD
    echo
    read -r -s -p "Repeat password: " USER_PASSWORD2
    echo

    [[ "${USER_PASSWORD}" == "${USER_PASSWORD2}" ]] ||
        die "Linux passwords do not match."

    [[ -n "${USER_PASSWORD}" ]] ||
        die "Linux password cannot be empty."

    run_in_target useradd \
        --create-home \
        --shell /bin/bash \
        --groups sudo \
        "${USERNAME}"

    printf '%s:%s\n' "${USERNAME}" "${USER_PASSWORD}" |
        chroot "${MOUNT}" chpasswd

    unset USER_PASSWORD USER_PASSWORD2
}

configure_bootloader() {
    echo
    echo "Installing UEFI bootloader..."

    run_in_target grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=Kali \
        --recheck

    run_in_target update-grub
}

finalize_installation() {
    echo
    echo "Finalizing installation..."

    run_in_target apt-get clean
    sync
}

show_password() {
    clear
    echo
    echo "================================================================"
    echo "                    KALI INSTALLATION COMPLETE"
    echo "================================================================"
    echo
    echo "Disk encryption password:"
    echo
    echo "    ${ENCRYPTION_PASSWORD}"
    echo
    echo "================================================================"
    echo
    echo "This password is exactly 16 random alphanumeric characters."
    echo "It is not stored in the installed operating system."
    echo
    echo "Write it down or store it in your password manager."
    echo
    echo "You will need it to unlock the encrypted disk during boot."
    echo
    echo "Linux username:"
    echo
    echo "    ${USERNAME}"
    echo
    echo "The Linux login password is the password you entered earlier."
    echo
    echo "================================================================"
    echo
    read -r -p "Press ENTER when you have securely recorded the encryption password..."
}

main() {
    require_root
    require_uefi
    require_live_environment

    select_target
    show_target
    confirm_install

    generate_password

    install_dependencies
    prepare_kali_keyring
    prepare_debootstrap

    # Re-check after installing host packages.
    select_target

    partition_disk
    get_partitions
    format_partitions
    create_lvm
    mount_filesystems
    bootstrap_kali
    configure_base_system
    install_kali_packages
    configure_encryption
    create_user
    configure_bootloader
    finalize_installation

    trap - EXIT
    show_password

    echo
    echo "Installation finished."
    echo "Remove the Live USB and reboot manually."
    echo
}

main "$@"
