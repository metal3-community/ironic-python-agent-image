#!/bin/bash

set -eu pipefail

WORKDIR=$(readlink -f "$0" | xargs dirname)

# shellcheck source=common.sh
source "${WORKDIR}/common.sh"

IRONIC_LIB_SOURCE=${IRONIC_LIB_SOURCE:-}

PY_REQS="buildreqs_python3.lst"
BUILD_REQS="buildreqs.lst"

# Detect architecture if not explicitly set
case "${ARCH}" in
    "x86_64")
        CORE_NAME="corepure64"
        VMLINUZ_NAME="vmlinuz64"
        ;;
    "aarch64"|"arm64")
        CORE_NAME="corepure64"
        VMLINUZ_NAME="vmlinuz64"
        TINYIPA_PYTHON_EXE="${TINYIPA_PYTHON_EXE:-python3.11}"
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac

echo "Building tinyipa for architecture: ${ARCH} (TC arch: ${TC_ARCH})"
QEMU_RELEASE="5.2.0"
LSHW_RELEASE="B.02.18"
BIOSDEVNAME_RELEASE="0.7.2"
IPMITOOL_GIT_HASH="19d78782d795d0cf4ceefe655f616210c9143e62"

# Set up chroot environment path
CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Detect if running in a container
CHROOT_CMD="chroot ${BUILDDIR} /usr/bin/env -i PATH=${CHROOT_PATH} http_proxy=${http_proxy:-} https_proxy=${https_proxy:-} no_proxy=${no_proxy:-}"

DOWNLOAD_RETRY_MAX=${DOWNLOAD_RETRY_MAX:-5}
DOWNLOAD_RETRY_DELAY=${DOWNLOAD_RETRY_DELAY:-10}

function download_with_retry() {
    local source_url=$1
    local destination_path=$2
    local attempts=1

    echo "Downloading ${source_url} to ${destination_path}"
    while [[ "${attempts}" -le "${DOWNLOAD_RETRY_MAX:-10}" ]]; do
        # Check for compressed tar archives and extract them
        if [[ "${source_url}" =~ \.tar\.gz$ ]] || [[ "${source_url}" =~ \.tgz$ ]]; then
            mkdir -p "${destination_path}"
            if wget --timeout=30 --tries=3 -q -O - "${source_url}" | tar -xz -C "${destination_path}" --strip-components=1 -f -; then
                echo "Successfully downloaded ${source_url} on attempt ${attempts}"
                return 0
            fi
        elif [[ "${source_url}" =~ \.tar\.bz2$ ]] || [[ "${source_url}" =~ \.tbz2$ ]]; then
            mkdir -p "${destination_path}"
            if wget --timeout=30 --tries=3 -q -O - "${source_url}" | tar -xj -C "${destination_path}" --strip-components=1 -f -; then
                echo "Successfully downloaded ${source_url} on attempt ${attempts}"
                return 0
            fi
        elif [[ "${source_url}" =~ \.tar\.xz$ ]] || [[ "${source_url}" =~ \.txz$ ]]; then
            mkdir -p "${destination_path}"
            if wget --timeout=30 --tries=3 -q -O - "${source_url}" | tar -xJ -C "${destination_path}" --strip-components=1 -f -; then
                echo "Successfully downloaded ${source_url} on attempt ${attempts}"
                return 0
            fi
        else
            # For non-tar files, download directly
            if wget --timeout=30 --tries=3 -q "${source_url}" -O "${destination_path}"; then
                echo "Successfully downloaded ${source_url} on attempt ${attempts}"
                return 0
            fi
        fi

        echo "Download attempt ${attempts} failed for ${source_url}, retrying in ${DOWNLOAD_RETRY_DELAY} seconds..."
        sleep "${DOWNLOAD_RETRY_DELAY:-10}"
        attempts=$((attempts + 1))
    done

    echo "Failed to download ${source_url} after ${DOWNLOAD_RETRY_MAX} attempts"
    return 1
}

echo "Building tinyipa:"

# If an old build directory exists remove it
if [[ -d "${BUILDDIR}" ]]; then
    rm -rf "${BUILDDIR}"
fi

##############################################
# Download and Cache Tiny Core Files
##############################################

# Find a working TC mirror if none is explicitly provided
choose_tc_mirror

cd "${WORKDIR}/build_files"

case "${ARCH}" in
    "aarch64"|"arm64")
        # For ARM64, download piCore image and extract components
        echo "Downloading piCore image for ARM64..."
        PICORE_VERSION="16.0.0"
        PICORE_IMG_URL="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/RPi/piCore64-${PICORE_VERSION}.img.gz"

        # Download the compressed image
        download_with_retry "${PICORE_IMG_URL}" "piCore64-${PICORE_VERSION}.img.gz"

        # Extract the image
        echo "Extracting piCore image..."
        gunzip -f "piCore64-${PICORE_VERSION}.img.gz"

        # Mount the image to extract rootfs and kernel - cross platform approach
        echo "Mounting piCore image to extract components..."

        # Create mount points
        mkdir -p /tmp/picore_boot

        LOOP_DEVICE=$(losetup -f --show "piCore64-${PICORE_VERSION}.img")
        partprobe "${LOOP_DEVICE}"
        mount "${LOOP_DEVICE}p1" /tmp/picore_boot
        PICORE_BOOT_DIR="/tmp/picore_boot"

        # Extract kernel - specifically look for kernel61225v8.img
        KERNEL_FILE="${PICORE_BOOT_DIR}/kernel61225v8.img"
        if [[ ! -f "${KERNEL_FILE}" ]]; then
            # Fallback to pattern search if specific file doesn't exist
            for f in "${PICORE_BOOT_DIR}"/kernel*.img; do
                if [[ -f "${f}" ]]; then
                    KERNEL_FILE="${f}"
                    break
                fi
            done
        fi

        if [[ ! -f "${KERNEL_FILE}" ]]; then
            echo "ERROR: Could not find kernel file in boot partition"
            echo "Available files:"
            ls -la "${PICORE_BOOT_DIR}"/
            exit 1
        fi

        cp "${KERNEL_FILE}" "${WORKDIR}/build_files/${VMLINUZ_NAME}"

        # Extract rootfs - specifically look for rootfs-piCore64-16.0.gz
        ROOTFS_FILE="${PICORE_BOOT_DIR}/rootfs-piCore64-16.0.gz"
        if [[ ! -f "${ROOTFS_FILE}" ]]; then
            echo "ERROR: Could not find rootfs-piCore64-16.0.gz in boot partition"
            echo "Available files:"
            ls -la "${PICORE_BOOT_DIR}"/
            exit 1
        fi

        # Copy the pre-compressed rootfs
        cp "${ROOTFS_FILE}" "${WORKDIR}/build_files/${CORE_NAME}.gz"

        MODS_FILE="${PICORE_BOOT_DIR}/modules-6.12.25-piCore-v8.gz"
        if [[ -f "${MODS_FILE}" ]]; then
            cp "${MODS_FILE}" "${WORKDIR}/build_files/modules.gz"
        else
            echo "WARNING: Could not find modules-6.12.25-piCore-v8.gz in boot partition"
            echo "Available files:"
            ls -la "${PICORE_BOOT_DIR}"/
        fi

        umount "${PICORE_BOOT_DIR}" || true
        losetup -d "${LOOP_DEVICE}" || true
        rm -rf "${PICORE_BOOT_DIR:?}"/* || true

        # Remove the image file to save space
        rm -f "piCore64-${PICORE_VERSION}.img"

        echo "ARM64 piCore extraction completed successfully"
        ;;
    *)
        # For x86_64, use the traditional method
        download_with_retry "${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/distribution_files/${CORE_NAME}.gz" "${CORE_NAME}.gz"
        download_with_retry "${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/distribution_files/${VMLINUZ_NAME}" "${VMLINUZ_NAME}"
        ;;
esac

cd "${WORKDIR}"

########################################################
# Build Required Python Dependencies in a Build Directory
########################################################

# Make directory for building in
mkdir "${BUILDDIR}"

if [[ -f "${WORKDIR}/build_files/modules.gz" ]]; then
    echo "Extracting kernel modules..."
    # Convert from cpio.gz to tar for extraction
    gunzip -c "${WORKDIR}/build_files/modules.gz" | (cd "${BUILDDIR}" && cpio -i -d --quiet)
fi

# Extract rootfs from .gz file
echo "Extracting rootfs..."
gunzip -c "${WORKDIR}/build_files/${CORE_NAME}.gz" | (cd "${BUILDDIR}" && cpio -i -d --quiet)

chown -R "0:0" "${BUILDDIR}/usr/bin/sudo"
chmod 4755 "${BUILDDIR}/usr/bin/sudo"

ln -s /dev "${BUILDDIR}/dev"
ln -s /proc "${BUILDDIR}/proc"
ln -s /sys "${BUILDDIR}/sys"

# Configure mirror
mkdir -p "${BUILDDIR}/opt"
sh -c "echo ${TINYCORE_MIRROR_URL} > ${BUILDDIR}/opt/tcemirror"

# Download Qemu-utils, Biosdevname and IPMItool source
download_with_retry "https://download.qemu.org/qemu-${QEMU_RELEASE}.tar.xz" "${BUILDDIR}/tmp/qemu"
download_with_retry "https://github.com/lyonel/lshw/archive/refs/tags/${LSHW_RELEASE}.tar.gz" "${BUILDDIR}/tmp/lshw"
if ${TINYIPA_REQUIRE_BIOSDEVNAME}; then
    download_with_retry "https://linux.dell.com/biosdevname/biosdevname-${BIOSDEVNAME_RELEASE}/biosdevname-${BIOSDEVNAME_RELEASE}.tar.gz" "${BUILDDIR}/tmp/biosdevname"
fi
if ${TINYIPA_REQUIRE_IPMITOOL}; then
    git clone https://github.com/ipmitool/ipmitool.git "${BUILDDIR}/tmp/ipmitool-src"
    cd "${BUILDDIR}/tmp/ipmitool-src"
    git reset "${IPMITOOL_GIT_HASH}" --hard
    cd -
fi

# Create directory for python local mirror
mkdir -p "${BUILDDIR}/tmp/localpip"

# Download IPA and requirements
IPA_SOURCE_DIR=${IPA_SOURCE_DIR:-/opt/stack/ironic-python-agent}

# Ensure ironic-python-agent source is available
if [[ ! -d "${IPA_SOURCE_DIR}" ]]; then
    echo "IPA source directory ${IPA_SOURCE_DIR} does not exist, cloning from GitHub..."
    # Create parent directory if needed
    mkdir -p "$(dirname "${IPA_SOURCE_DIR}")"
    chown "$(whoami):$(id -g)" "$(dirname "${IPA_SOURCE_DIR}")"
    git clone https://github.com/openstack/ironic-python-agent.git "${IPA_SOURCE_DIR}"
    echo "Successfully cloned ironic-python-agent to ${IPA_SOURCE_DIR}"
fi

cd "${IPA_SOURCE_DIR}"
rm -rf ./*.egg-info
pwd

python3 setup.py sdist --dist-dir "${BUILDDIR}/tmp/localpip" --quiet

ls "${BUILDDIR}/tmp/localpip" || true
cp requirements.txt "${BUILDDIR}/tmp/ipa-requirements.txt"

if [[ -n "${PYTHON_EXTRA_SOURCES_DIR_LIST}" ]]; then
    IFS="," read -ra PKGDIRS <<< "${PYTHON_EXTRA_SOURCES_DIR_LIST}"
    for PKGDIR in "${PKGDIRS[@]}"; do
        PKG=$(cd "${PKGDIR}" ; python3 setup.py --name)
        pushd "${PKGDIR}"
        rm -rf ./*.egg-info
        python3 setup.py sdist --dist-dir "${BUILDDIR}/tmp/localpip" --quiet
        if [[ -r requirements.txt ]]; then
            cp requirements.txt "${BUILDDIR}/tmp/${PKG}-requirements.txt"
        fi
        popd
    done
fi

"${WORKDIR}/generate_tox_constraints.sh" upper-constraints.txt
cp upper-constraints.txt "${BUILDDIR}/tmp/upper-constraints.txt"
echo Using upper-constraints:
cat upper-constraints.txt
cd "${WORKDIR}"

# Ensure /etc directory exists before copying resolv.conf
mkdir -p "${BUILDDIR}/etc"
cp /etc/resolv.conf "${BUILDDIR}/etc/resolv.conf"

# Ensure proc and dev/pts directories exist before mounting
mkdir -p "${BUILDDIR}/proc"
mkdir -p "${BUILDDIR}/dev/pts"

trap 'umount ${BUILDDIR}/proc; umount ${BUILDDIR}/dev/pts' EXIT
mount --bind /proc "${BUILDDIR}/proc" || true
mount --bind /dev/pts "${BUILDDIR}/dev/pts" || true

if [[ -d /opt/stack/new ]]; then
    CI_DIR=/opt/stack/new
elif [[ -d /opt/stack ]]; then
    CI_DIR=/opt/stack
else
    CI_DIR=
fi

if [[ -n "${CI_DIR}" ]]; then
    # Running in CI environment, make checkouts available
    ${CHROOT_CMD} mkdir -p "${CI_DIR}"
    for project in "${CI_DIR}"/*; do
        if grep -q "${project}" "${BUILDDIR}/tmp/upper-constraints.txt" &&
            [[ -d "${CI_DIR}/${project}/.git" ]]; then
            cp -R "${CI_DIR}/${project}" "${BUILDDIR}/${CI_DIR}/"
        fi
    done
fi

# Create necessary directories for the build environment
mkdir -p "${BUILDDIR}/etc/sysconfig"
mkdir -p "${BUILDDIR}/tmp/builtin/optional"

mkdir "${BUILDDIR}/tmp/overrides"
cp "${WORKDIR}/build_files/fakeuname" "${BUILDDIR}/tmp/overrides/uname"

cp "${WORKDIR}/build_files/ntpdate" "${BUILDDIR}/bin/ntpdate"

# Process build requirements
while read -r line; do
    if [[ -n "${line}" ]]; then
        echo "Installing build package: ${line}"
        download_and_extract_tcz "${line}" "${BUILDDIR}" || { echo "Failed to install ${line}"; exit 1; }
    fi
done < "${WORKDIR}"/build_files/"${BUILD_REQS}"

# Process Python requirements
while read -r line; do
    if [[ -n "${line}" ]]; then
        echo "Installing Python package: ${line}"
        download_and_extract_tcz "${line}" "${BUILDDIR}" || { echo "Failed to install ${line}"; exit 1; }
    fi
done < "${WORKDIR}"/build_files/"${PY_REQS}"

# Build python wheels
${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m ensurepip
${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip install --upgrade pip=="${PIP_VERSION}" wheel
${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip install pbr
${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip wheel -c /tmp/upper-constraints.txt --wheel-dir /tmp/wheels -r /tmp/ipa-requirements.txt

if [[ -n "${PYTHON_EXTRA_SOURCES_DIR_LIST}" ]]; then
    IFS="," read -ra PKGDIRS <<< "${PYTHON_EXTRA_SOURCES_DIR_LIST}"
    for PKGDIR in "${PKGDIRS[@]}"; do
        PKG=$(cd "${PKGDIR}" ; ${PYTHON_COMMAND} setup.py --name)
        if [[ -r ${BUILDDIR}/tmp/${PKG}-requirements.txt ]]; then
            ${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip wheel -c /tmp/upper-constraints.txt --wheel-dir /tmp/wheels -r "/tmp/${PKG}-requirements.txt"
        fi
        ${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip wheel -c /tmp/upper-constraints.txt --no-index --pre --wheel-dir /tmp/wheels --find-links=/tmp/localpip --find-links=/tmp/wheels "${PKG}"
    done
fi

${CHROOT_CMD} "${TINYIPA_PYTHON_EXE}" -m pip wheel -c /tmp/upper-constraints.txt --no-index --pre --wheel-dir /tmp/wheels --find-links=/tmp/localpip --find-links=/tmp/wheels ironic-python-agent
echo Resulting wheels:
ls -1 "${BUILDDIR}/tmp/wheels"

# Build qemu-utils
rm -rf "${WORKDIR}/build_files/qemu-utils.tcz"
${CHROOT_CMD} /bin/sh -c "cd /tmp/qemu && CFLAGS=-Wno-error ./configure --disable-system --disable-user --disable-linux-user --disable-bsd-user --disable-guest-agent --disable-blobs --enable-tools --python=/usr/local/bin/${TINYIPA_PYTHON_EXE} && make && make install DESTDIR=/tmp/qemu-utils"
find "${BUILDDIR}/tmp/qemu-utils/" -type f -executable -print0 | xargs -0 file | awk -F ':' '/ELF/ {print $1}' | xargs strip
cd "${WORKDIR}/build_files" && mksquashfs "${BUILDDIR}/tmp/qemu-utils" qemu-utils.tcz && md5sum qemu-utils.tcz > qemu-utils.tcz.md5.txt
# Create qemu-utils.tcz.dep
echo "glib2.tcz" > qemu-utils.tcz.dep

# Build lshw
rm -rf "${WORKDIR}/build_files/lshw.tcz"
# NOTE(mjturek): We touch src/lshw.1 and clear src/po/Makefile to avoid building the man pages, as they aren't used and require large dependencies to build.
${CHROOT_CMD} /bin/sh -c "cd /tmp/lshw && touch src/lshw.1 && echo install: > src/po/Makefile && make && make install DESTDIR=/tmp/lshw-installed"
find "${BUILDDIR}/tmp/lshw-installed/" -type f -executable -print0 | xargs -0 file | awk -F ':' '/ELF/ {print $1}' | xargs strip
cd "${WORKDIR}/build_files" && mksquashfs "${BUILDDIR}/tmp/lshw-installed" lshw.tcz && md5sum lshw.tcz > lshw.tcz.md5.txt

# Build biosdevname
if ${TINYIPA_REQUIRE_BIOSDEVNAME}; then
    rm -rf "${WORKDIR}/build_files/biosdevname.tcz"
    ${CHROOT_CMD} /bin/sh -c "cd /tmp/biosdevname-* && ./configure && make && make install DESTDIR=/tmp/biosdevname-installed"
    find "${BUILDDIR}/tmp/biosdevname-installed/" -type f -executable -print0 | xargs -0 file | awk -F ':' '/ELF/ {print $1}' | xargs strip
    cd "${WORKDIR}/build_files" && mksquashfs "${BUILDDIR}/tmp/biosdevname-installed" biosdevname.tcz && md5sum biosdevname.tcz > biosdevname.tcz.md5.txt
fi

if ${TINYIPA_REQUIRE_IPMITOOL}; then
    rm -rf "${WORKDIR}/build_files/ipmitool.tcz"
    # NOTE(TheJulia): Explicitly add the libtool path since /usr/local/ is not in path from the chroot.
    ${CHROOT_CMD} /bin/sh -c "cd /tmp/ipmitool-src && env LIBTOOL='/usr/local/bin/libtool' ./bootstrap && ./configure && make && make install DESTDIR=/tmp/ipmitool"
    find "${BUILDDIR}/tmp/ipmitool/" -type f -executable -print0 | xargs -0 file | awk -F ':' '/ELF/ {print $1}' | xargs strip
    cd "${WORKDIR}/build_files" && mksquashfs "${BUILDDIR}/tmp/ipmitool" ipmitool.tcz && md5sum ipmitool.tcz > ipmitool.tcz.md5.txt
fi
