#!/bin/bash

set -ex
WORKDIR=$(readlink -f "$0" | xargs dirname || true)
DST_DIR=$(mktemp -d)
source "${WORKDIR}/common.sh"
PARTIMG="${WORKDIR}/tiny-instance-part${BRANCH_EXT}.img"
UECFILE="${WORKDIR}/tiny-instance-uec${BRANCH_EXT}.tar.gz"
fs_type='ext4'

sudo rm -rf "${PARTIMG}" "${UECFILE}"
sudo truncate --size=150M "${PARTIMG}"

sudo mkfs."${fs_type}" -F "${PARTIMG}" -L "root"
sudo mount -o loop "${PARTIMG}" "${DST_DIR}/"

# Extract rootfs from .gz file
( cd "${DST_DIR}" && zcat "${WORKDIR}/build_files/corepure64.gz" | sudo cpio -i -H newc -d )

setup_tce "${DST_DIR}"

# NOTE(rpittau) change ownership of the tce info dir to prevent writing issues
sudo chown "${TC}:${STAFF}" "${DST_DIR}/usr/local/tce.installed"

ARCH=${ARCH:-$(uname -m)}
if [[ "${ARCH}" = "x86_64" ]]; then
  # $TC_CHROOT_CMD tce-load -wci grub2-efi.tcz
  # download_and_extract_tcz grub2-efi.tcz "${DST_DIR}"
  download_and_extract_tcz grub2-multi.tcz "${DST_DIR}"
  # $TC_CHROOT_CMD tce-load -wci grub2-multi.tcz
fi

# $TC_CHROOT_CMD tce-load -wci grub2-multi.tcz

cleanup_tce "${DST_DIR}"
sudo umount "${DST_DIR}/"

pushd "${DST_DIR}/"
cp "${WORKDIR}/tinyipa${BRANCH_EXT}.gz" "${DST_DIR}/tinyipa-initrd"
cp "${WORKDIR}/tinyipa${BRANCH_EXT}.vmlinuz" "${DST_DIR}/tinyipa-vmlinuz"
cp "${PARTIMG}" "${DST_DIR}/"

tar -czf "${UECFILE}" ./

popd

sudo rm -rf "${DST_DIR}"
