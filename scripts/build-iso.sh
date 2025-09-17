#!/bin/bash

set -ex
WORKDIR=$(readlink -f "$0" | xargs dirname || true)
SYSLINUX_VERSION="6.03"
SYSLINUX_URL="https://www.kernel.org/pub/linux/utils/boot/syslinux/syslinux-${SYSLINUX_VERSION}.tar.gz"

source "${WORKDIR}/common.sh"

cd "${WORKDIR}"
rm -rf newiso

if [[ "${ARCH}" = "x86_64" ]]; then
  # x86_64 - use isolinux
  cd "${WORKDIR}/build_files"
  wget -N "${SYSLINUX_URL}" && tar zxf syslinux-"${SYSLINUX_VERSION}".tar.gz

  cd "${WORKDIR}"
  mkdir -p newiso/boot/isolinux
  cp build_files/syslinux-"${SYSLINUX_VERSION}"/bios/core/isolinux.bin newiso/boot/isolinux/.
  cp build_files/isolinux.cfg newiso/boot/isolinux/.
  cp "tinyipa${BRANCH_EXT}.gz" newiso/boot/corepure64.gz
  cp "tinyipa${BRANCH_EXT}.vmlinuz" newiso/boot/vmlinuz64

  set +e
  ISO_BUILDER=""

  for builder in mkisofs genisoimage xorrisofs; do
    if command -v "${builder}" >/dev/null 2>&1; then
      if ${builder} --help >/dev/null 2>&1; then
        ISO_BUILDER=${builder}
        break
      fi
    fi
  done
  if [[ -z "${ISO_BUILDER}" ]]; then
    echo "Please install a ISO filesystem builder utility such as mkisofs, genisoimage, or xorrisofs."
    exit 1
  fi

  set -e
  ${ISO_BUILDER} -l -r -J -R -V TC-custom -no-emul-boot -boot-load-size 4 -boot-info-table -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat -o tinyipa"${BRANCH_EXT}".iso newiso

else
  # ARM64 - use GRUB for EFI boot
  mkdir -p newiso/boot/grub
  cp build_files/grub.cfg newiso/boot/grub/.
  cp "tinyipa${BRANCH_EXT}.gz" newiso/boot/corepure64.gz
  cp "tinyipa${BRANCH_EXT}.vmlinuz" newiso/boot/vmlinuz64

  # Create a simple EFI-bootable ISO
  set +e
  ISO_BUILDER=""

  for builder in xorrisofs genisoimage mkisofs; do
    if command -v "${builder}" >/dev/null 2>&1; then
      if ${builder} --help >/dev/null 2>&1; then
        ISO_BUILDER=${builder}
        break
      fi
    fi
  done
  if [[ -z "${ISO_BUILDER}" ]]; then
    echo "Please install a ISO filesystem builder utility such as xorrisofs, genisoimage, or mkisofs."
    exit 1
  fi

  set -e
  # For ARM64, create a basic ISO without boot loader embedding
  # The system will need to have GRUB or other EFI boot loader to boot this
  ${ISO_BUILDER} -l -r -J -R -V TC-custom-arm64 -o "tinyipa${BRANCH_EXT}.iso" newiso
fi
