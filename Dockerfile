# syntax=docker/dockerfile:1-labs

# Multi-stage Dockerfile for TinyIPA
# Extracts rootfs for different architectures and builds the final image

# Build stage - TinyCore base extraction
FROM debian:bookworm-slim AS tinycore-extractor

ARG TARGETARCH
# Set default TARGETARCH for legacy builder compatibility
RUN if [ -z "${TARGETARCH}" ]; then \
      case "$(uname -m)" in \
        x86_64) export TARGETARCH=amd64 ;; \
        aarch64) export TARGETARCH=arm64 ;; \
        armv7l) export TARGETARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
      esac; \
    fi

ARG TINYCORE_VERSION=16
ARG TINYCORE_MIRROR_URL=http://tinycorelinux.net/${TINYCORE_VERSION}.x
ARG TC_RELEASE=${TINYCORE_VERSION}.x

# Install required tools for extraction
RUN apt-get update && apt-get install -y \
    wget \
    tar \
    mtools \
    libarchive-tools \
    squashfs-tools \
    util-linux \
    parted \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Architecture-specific rootfs extraction
RUN set -eux; \
    # Set TARGETARCH for legacy builder compatibility
    if [ -z "${TARGETARCH:-}" ]; then \
      case "$(uname -m)" in \
        x86_64) TARGETARCH=amd64 ;; \
        aarch64) TARGETARCH=arm64 ;; \
        armv7l) TARGETARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
      esac; \
    fi; \
    case "${TARGETARCH}" in \
        "amd64") \
            ARCH="x86_64"; \
            TC_ARCH="x86_64"; \
            CORE_NAME="corepure64"; \
            VMLINUZ_NAME="vmlinuz64"; \
            ;; \
        "arm64") \
            ARCH="aarch64"; \
            TC_ARCH="aarch64"; \
            CORE_NAME="corepure64"; \
            VMLINUZ_NAME="vmlinuz64"; \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}"; \
            exit 1; \
            ;; \
    esac; \
    \
    export ARCH TC_ARCH CORE_NAME VMLINUZ_NAME; \
    \
    # Mirror selection - try primary mirror first, fallback to alternatives
    MIRRORS="http://repo.tinycorelinux.net http://mirror.cedia.org.ec/tinycorelinux http://mirror.epn.edu.ec/tinycorelinux"; \
    TINYCORE_MIRROR_URL=""; \
    for mirror in ${MIRRORS}; do \
        echo "Testing mirror: ${mirror}"; \
        if wget --timeout=10 --tries=1 --spider "${mirror}/" 2>/dev/null; then \
            TINYCORE_MIRROR_URL="${mirror}"; \
            echo "Using mirror: ${TINYCORE_MIRROR_URL}"; \
            break; \
        fi; \
    done; \
    \
    if [ -z "${TINYCORE_MIRROR_URL}" ]; then \
        echo "No working mirror found, using default"; \
        TINYCORE_MIRROR_URL="http://repo.tinycorelinux.net"; \
    fi; \
    \
    mkdir -p /rootfs; \
    \
    case "${TARGETARCH}" in \
        "arm64") \
            echo "Downloading piCore image for ARM64..."; \
            PICORE_IMG="piCore64-${TINYCORE_VERSION}.0.0.img.gz"; \
            PICORE_IMG_URL="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/RPi/${PICORE_IMG}"; \
            \
            wget --timeout=30 --tries=15 -q "${PICORE_IMG_URL}" -O "${PICORE_IMG}"; \
            # Extract the image
            echo "Extracting piCore image..."; \
            gunzip -f "${PICORE_IMG}"; \
            \
            # Mount the image to extract rootfs and kernel
            echo "Mounting piCore image to extract components..."; \
            dd if="${PICORE_IMG%%.gz}" of=boot.fat bs=512 skip=8192 count=163840; \
            dd if="${PICORE_IMG%%.gz}" of=root.ext4 bs=512 skip=172032 count=32768; \
            mkdir -p /tmp/picore_boot; \
            mcopy -i boot.fat ::* /tmp/picore_boot -s; \
            bsdtar -C /rootfs -xf root.ext4; \
            \
            for f in /tmp/picore_boot/kernel*.img; do \
                if [ -f "${f}" ]; then \
                    KERNEL_FILE="${f}"; \
                    break; \
                fi; \
            done; \
            if [ ! -f "${KERNEL_FILE}" ]; then \
                echo "ERROR: Could not find kernel file in boot partition"; \
                ls -la /tmp/picore_boot/; \
                exit 1; \
            fi; \
            \
            cp "${KERNEL_FILE}" "/rootfs/${VMLINUZ_NAME}"; \
            \
            # Extract the pre-compressed rootfs to /rootfs
            echo "Extracting rootfs..."; \
            gzip -dc "/tmp/picore_boot/rootfs-piCore64-${TINYCORE_VERSION}.0.gz" | bsdtar -C /rootfs -xf -; \
            \
            # Extract modules if available
            MODS_FILE="/tmp/picore_boot/modules-6.12.25-piCore-v8.gz"; \
            if [ -f "${MODS_FILE}" ]; then \
                echo "Extracting kernel modules..."; \
                gzip -dc "${MODS_FILE}" | bsdtar -C /rootfs -xf -; \
            else \
                echo "WARNING: Could not find modules file in boot partition"; \
            fi; \
            \
            rm -rf /tmp/picore_boot; \
            rm -f "piCore64-${TINYCORE_VERSION}.0.0.img"; \
            \
            echo "ARM64 piCore extraction completed successfully"; \
            ;; \
        "amd64") \
            echo "Downloading TinyCore components for x86_64..."; \
            \
            # Download core and kernel files with retry logic
            for file in "${CORE_NAME}.gz" "${VMLINUZ_NAME}"; do \
                url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/distribution_files/${file}"; \
                attempts=1; \
                max_attempts=5; \
                while [ "${attempts}" -le "${max_attempts}" ]; do \
                    if wget --timeout=30 --tries=3 -q "${url}" -O "${file}"; then \
                        echo "Successfully downloaded ${file} on attempt ${attempts}"; \
                        break; \
                    fi; \
                    echo "Download attempt ${attempts} failed for ${file}, retrying..."; \
                    attempts=$((attempts + 1)); \
                    if [ "${attempts}" -gt "${max_attempts}" ]; then \
                        echo "Failed to download ${file} after ${max_attempts} attempts"; \
                        exit 1; \
                    fi; \
                    sleep 10; \
                done; \
            done; \
            \
            # Extract rootfs
            echo "Extracting rootfs..."; \
            gzip -dc "${CORE_NAME}.gz" | bsdtar -C /rootfs -xf -; \
            \
            # Copy kernel
            cp "${VMLINUZ_NAME}" "/rootfs/${VMLINUZ_NAME}"; \
            \
            echo "x86_64 TinyCore extraction completed successfully"; \
            ;; \
    esac

# Final stage - scratch-based image with extracted rootfs
FROM scratch AS tinycore-base

# Copy the extracted rootfs from the build stage
COPY --from=tinycore-extractor /rootfs/ /

# Set up basic environment
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV SHELL="/bin/sh"
ENV HOME="/root"

# Create necessary directories and files if they don't exist
RUN mkdir -p /proc /sys /dev /tmp /var/log /etc /tmp/tcloop /tmp/builtin/optional && \
    echo "root:x:0:0:root:/root:/bin/sh" >> /etc/passwd && \
    echo "root:x:0:" >> /etc/group && \
    chown -R "0:0" /usr/bin/sudo && \
    chmod 4755 /usr/bin/sudo && \
    mkdir -p /etc/sysconfig && \
    echo "tc" > /etc/sysconfig/tcuser && \
    ln -sf /tmp/builtin /etc/sysconfig/tcedir && \
    chown -R "tc:staff" /tmp/builtin /tmp/tcloop && \
    chmod 755 /tmp/builtin /tmp/tcloop && \
    echo "tc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /usr/local/tce.installed && \
    mkdir -p /usr/local/etc/pki/certs && \
    mkdir -p /home/tc && \
    chown tc:staff /home/tc

# Copy CA certificates from the build stage (Debian has them)
COPY --from=tinycore-extractor /etc/ssl/certs/ca-certificates.crt /usr/local/etc/pki/certs/ca-bundle.crt

# Configure Git to use the certificates and disable strict SSL for problematic cases
RUN echo '[http]' > /etc/gitconfig && \
    echo '    sslCAInfo = /usr/local/etc/pki/certs/ca-bundle.crt' >> /etc/gitconfig && \
    echo '    sslVerify = true' >> /etc/gitconfig

# Set container to run with SYS_ADMIN capability for mounting
# Note: This requires running with --cap-add SYS_ADMIN or --privileged

USER tc
ENV HOME="/home/tc"

# Set working directory for tc user
WORKDIR /home/tc

# Default command
CMD ["/bin/sh"]

# Final stage - TinyIPA with pre-extracted packages
FROM tinycore-extractor AS package-extractor

# Copy the build requirements lists
COPY build_files/ /build_files/

# Download and extract TCZ packages using predefined lists and dependency recursion
RUN set -eux; \
    # Set TARGETARCH for package selection
    if [ -z "${TARGETARCH:-}" ]; then \
      case "$(uname -m)" in \
        x86_64) TARGETARCH=amd64 ;; \
        aarch64) TARGETARCH=arm64 ;; \
        armv7l) TARGETARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
      esac; \
    fi; \
    \
    # Set architecture-specific variables
    case "${TARGETARCH}" in \
        "amd64") \
            TC_ARCH="x86_64"; \
            BUILD_DIR="/build_files/amd64"; \
            ;; \
        "arm64") \
            TC_ARCH="aarch64"; \
            BUILD_DIR="/build_files/arm64"; \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}"; \
            exit 1; \
            ;; \
    esac; \
    \
    export TC_ARCH BUILD_DIR; \
    TINYCORE_MIRROR_URL="http://repo.tinycorelinux.net"; \
    TC_RELEASE="16.x"; \
    \
    mkdir -p /tcz-packages /extracted /tmp/deps; \
    cd /tcz-packages; \
    \
    # Function to download dependencies recursively
    download_deps() { \
        local package=$1; \
        local processed_file="/tmp/deps/processed_${package%%.tcz}"; \
        \
        # Skip if already processed
        if [ -f "${processed_file}" ]; then \
            return 0; \
        fi; \
        \
        echo "Processing package: ${package}"; \
        touch "${processed_file}"; \
        \
        # Download dependency file
        local dep_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}.dep"; \
        local temp_dep_file="/tmp/deps/${package%%.tcz}.dep"; \
        \
        if wget --timeout=30 --tries=1 -q "${dep_url}" -O "${temp_dep_file}" 2>/dev/null; then \
            echo "Found dependencies for ${package}"; \
            while IFS= read -r dep_package; do \
                if [ -n "${dep_package}" ] && [ "${dep_package}" != "${dep_package#\#}" ]; then \
                    continue; \
                fi; \
                if [ -n "${dep_package}" ]; then \
                    echo "Installing dependency: ${dep_package}"; \
                    download_deps "${dep_package}"; \
                fi; \
            done < "${temp_dep_file}"; \
        fi; \
        \
        # Download the actual package if not already downloaded
        if [ ! -f "${package}" ]; then \
            local tcz_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}"; \
            echo "Downloading ${package}"; \
            if ! wget --timeout=30 --tries=3 -q "${tcz_url}" -O "${package}"; then \
                echo "WARNING: Failed to download ${package}"; \
            fi; \
        fi; \
    }; \
    \
    # Process buildreqs.lst
    if [ -f "${BUILD_DIR}/buildreqs.lst" ]; then \
        echo "Processing buildreqs.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < "${BUILD_DIR}/buildreqs.lst"; \
    fi; \
    \
    # Process buildreqs_python3.lst
    if [ -f "${BUILD_DIR}/buildreqs_python3.lst" ]; then \
        echo "Processing buildreqs_python3.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < "${BUILD_DIR}/buildreqs_python3.lst"; \
    fi; \
    \
    # Add SSL/TLS support packages
    download_deps "openssl.tcz"; \
    download_deps "ca-certificates.tcz"

# Extract all downloaded TCZ packages with dependency handling
RUN cd /tcz-packages && \
    echo "Extracting downloaded packages..." && \
    for tcz in *.tcz; do \
        if [ -f "${tcz}" ]; then \
            echo "Extracting ${tcz}"; \
            package_name="${tcz%%.tcz}"; \
            \
            # Extract the squashfs first
            if unsquashfs -f -d /extracted "${tcz}" >/dev/null 2>&1; then \
                echo "Successfully extracted ${tcz}"; \
                \
                # Extract any nested tar.gz archives like common.sh does
                for f in "/extracted/usr/local/share/${package_name}"/*/*.tar.gz; do \
                    if [ -f "${f}" ]; then \
                        echo "Extracting additional archive ${f} for ${package_name}"; \
                        tar -xzf "${f}" -C /extracted/ 2>/dev/null || true; \
                    fi; \
                done; \
                \
                # Special handling for Python packages - create symlinks
                if echo "${package_name}" | grep -q "python3"; then \
                    echo "Setting up Python environment for ${package_name}"; \
                    if [ -f "/extracted/usr/local/bin/python3.11" ] && [ ! -f "/extracted/usr/local/bin/python3" ]; then \
                        ln -sf python3.11 /extracted/usr/local/bin/python3; \
                        echo "Created python3 symlink"; \
                    fi; \
                    if [ -f "/extracted/usr/local/bin/python3.11" ] && [ ! -f "/extracted/usr/local/bin/python" ]; then \
                        ln -sf python3.11 /extracted/usr/local/bin/python; \
                        echo "Created python symlink"; \
                    fi; \
                fi; \
                \
                # Mark package as installed
                mkdir -p /extracted/usr/local/tce.installed; \
                touch "/extracted/usr/local/tce.installed/${package_name}"; \
            else \
                echo "Failed to extract ${tcz}"; \
            fi; \
        fi; \
    done && \
    echo "Package extraction completed"

# Build stage - TinyIPA with pre-extracted packages and custom builds
FROM tinycore-base AS tinyipa-build

# Switch to root for setup operations
USER root

# Copy extracted packages from build stage
COPY --from=package-extractor /extracted /

# Build dependencies and versions
ARG QEMU_RELEASE="9.2.4"
ARG LSHW_RELEASE="B.02.20"
ARG BIOSDEVNAME_RELEASE="0.7.2"
ARG IPMITOOL_GIT_HASH="19d78782d795d0cf4ceefe655f616210c9143e62"
ARG TINYIPA_REQUIRE_BIOSDEVNAME=false
ARG TINYIPA_REQUIRE_IPMITOOL=true

# Convert ARGs to ENV so they're available in RUN commands
ENV QEMU_RELEASE=${QEMU_RELEASE}
ENV LSHW_RELEASE=${LSHW_RELEASE}
ENV BIOSDEVNAME_RELEASE=${BIOSDEVNAME_RELEASE}
ENV IPMITOOL_GIT_HASH=${IPMITOOL_GIT_HASH}
ENV TINYIPA_REQUIRE_BIOSDEVNAME=${TINYIPA_REQUIRE_BIOSDEVNAME}
ENV TINYIPA_REQUIRE_IPMITOOL=${TINYIPA_REQUIRE_IPMITOOL}

# Set up build environment
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RUN NORTC=1 NOZSWAP=1 /etc/init.d/tc-config

# Set up Python and install dependencies
RUN echo "=== Setting up build environment ===" && \
    # Set up library paths like common.sh does
    echo "Setting up library paths..." && \
    mkdir -p /etc && \
    echo "/usr/local/lib" >> /etc/ld.so.conf && \
    ldconfig && \
    echo "Updated ldconfig cache" && \
    # Try to find any python executable and create symlinks like common.sh does
    PYTHON_EXE="" && \
    for candidate in /usr/local/bin/python3.11 /usr/bin/python3.11 /usr/local/bin/python3.9 /usr/bin/python3.9 /usr/local/bin/python3 /usr/bin/python3; do \
        if [ -f "$candidate" ]; then \
            PYTHON_EXE="$candidate"; \
            echo "Found Python executable: $PYTHON_EXE"; \
            break; \
        fi; \
    done && \
    if [ -n "$PYTHON_EXE" ]; then \
        # Create symlinks like common.sh does
        if [ ! -f /usr/local/bin/python3 ]; then \
            ln -sf "$(basename "$PYTHON_EXE")" /usr/local/bin/python3; \
            echo "Created python3 symlink"; \
        fi; \
        if [ ! -f /usr/local/bin/python ]; then \
            ln -sf "$(basename "$PYTHON_EXE")" /usr/local/bin/python; \
            echo "Created python symlink"; \
        fi; \
        python3 -m ensurepip && \
        pip3 install --no-cache --upgrade pip setuptools wheel && \
        pip3 install pbr; \
    else \
        echo "ERROR: No Python executable found in base system or extracted packages"; \
        exit 1; \
    fi

# Download and build custom tools (optional - may fail due to network issues)
RUN echo "=== Attempting to download and build custom tools ===" && \
    # Configure SSL/TLS support for wget and git
    echo "Setting up SSL/TLS configuration..." && \
    mkdir -p /etc/ssl/certs && \
    if [ -f /usr/local/etc/pki/certs/ca-bundle.crt ]; then \
        cp /usr/local/etc/pki/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; \
        echo "Copied CA certificates from TinyCore location"; \
    fi && \
    \
    # Update wget configuration to use SSL properly
    echo "ca_certificate = /etc/ssl/certs/ca-certificates.crt" > /etc/wgetrc && \
    echo "check_certificate = on" >> /etc/wgetrc && \
    echo "Configured wget SSL settings" && \
    \
    # Update git SSL configuration
    git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt && \
    git config --global http.sslVerify true && \
    echo "Configured git SSL settings" && \
    \
    mkdir -p /tmp/downloads /tmp/qemu-utils /tmp/lshw-installed /tmp/biosdevname-installed /tmp/ipmitool && \
    cd /tmp/downloads && \
    \
    # Set success flags
    QEMU_SUCCESS=false && \
    LSHW_SUCCESS=false && \
    BIOSDEVNAME_SUCCESS=false && \
    IPMITOOL_SUCCESS=false && \
    \
    # Download source packages with retry logic
    echo "Downloading source packages..." && \
    \
    # Download qemu with retry and mirror fallback
    attempts=1; \
    max_attempts=3; \
    QEMU_MIRRORS="https://github.com/qemu/qemu/archive/refs/tags/v${QEMU_RELEASE}.tar.gz"; \
    while [ "${attempts}" -le "${max_attempts}" ]; do \
        for mirror_url in ${QEMU_MIRRORS}; do \
            echo "Trying QEMU download from: ${mirror_url}"; \
            QEMU_FILENAME="qemu-${QEMU_RELEASE}.tar.gz"; \
            if wget --no-check-certificate --timeout=30 --tries=2 "${mirror_url}" -O "${QEMU_FILENAME}" 2>/dev/null; then \
                echo "Successfully downloaded qemu on attempt ${attempts} from ${mirror_url}"; \
                QEMU_SUCCESS=true; \
                break; \
            fi; \
            echo "Download failed from ${mirror_url}"; \
        done; \
        if [ "${QEMU_SUCCESS}" = "true" ]; then \
            break; \
        fi; \
        echo "Download attempt ${attempts} failed for qemu, retrying..."; \
        attempts=$((attempts + 1)); \
        if [ "${attempts}" -gt "${max_attempts}" ]; then \
            echo "Failed to download qemu after ${max_attempts} attempts - skipping"; \
            break; \
        fi; \
        sleep 5; \
    done && \
    \
    # Download lshw with retry and mirror fallback
    attempts=1; \
    LSHW_MIRRORS="https://github.com/lyonel/lshw/archive/refs/tags/${LSHW_RELEASE}.tar.gz https://www.ezix.org/software/files/lshw-${LSHW_RELEASE}.tar.gz"; \
    while [ "${attempts}" -le "${max_attempts}" ]; do \
        for mirror_url in ${LSHW_MIRRORS}; do \
            echo "Trying LSHW download from: ${mirror_url}"; \
            LSHW_FILENAME="lshw-${LSHW_RELEASE}.tar.gz"; \
            if wget --no-check-certificate --timeout=30 --tries=2 "${mirror_url}" -O "${LSHW_FILENAME}" 2>/dev/null; then \
                echo "Successfully downloaded lshw on attempt ${attempts} from ${mirror_url}"; \
                LSHW_SUCCESS=true; \
                break; \
            fi; \
            echo "Download failed from ${mirror_url}"; \
        done; \
        if [ "${LSHW_SUCCESS}" = "true" ]; then \
            break; \
        fi; \
        echo "Download attempt ${attempts} failed for lshw, retrying..."; \
        attempts=$((attempts + 1)); \
        if [ "${attempts}" -gt "${max_attempts}" ]; then \
            echo "Failed to download lshw after ${max_attempts} attempts - skipping"; \
            break; \
        fi; \
        sleep 5; \
    done && \
    \
    # Download biosdevname if required
    if [ "${TINYIPA_REQUIRE_BIOSDEVNAME}" = "true" ]; then \
        attempts=1; \
        BIOSDEVNAME_MIRRORS="https://linux.dell.com/biosdevname/biosdevname-${BIOSDEVNAME_RELEASE}/biosdevname-${BIOSDEVNAME_RELEASE}.tar.gz https://github.com/dell/biosdevname/archive/refs/tags/v${BIOSDEVNAME_RELEASE}.tar.gz"; \
        while [ "${attempts}" -le "${max_attempts}" ]; do \
            for mirror_url in ${BIOSDEVNAME_MIRRORS}; do \
                echo "Trying BIOSDEVNAME download from: ${mirror_url}"; \
                BIOSDEVNAME_FILENAME="biosdevname-${BIOSDEVNAME_RELEASE}.tar.gz"; \
                if wget --no-check-certificate --timeout=30 --tries=2 "${mirror_url}" -O "${BIOSDEVNAME_FILENAME}" 2>/dev/null; then \
                    echo "Successfully downloaded biosdevname on attempt ${attempts} from ${mirror_url}"; \
                    BIOSDEVNAME_SUCCESS=true; \
                    break; \
                fi; \
                echo "Download failed from ${mirror_url}"; \
            done; \
            if [ "${BIOSDEVNAME_SUCCESS}" = "true" ]; then \
                break; \
            fi; \
            echo "Download attempt ${attempts} failed for biosdevname, retrying..."; \
            attempts=$((attempts + 1)); \
            if [ "${attempts}" -gt "${max_attempts}" ]; then \
                echo "Failed to download biosdevname after ${max_attempts} attempts - skipping"; \
                break; \
            fi; \
            sleep 5; \
        done; \
    fi && \
    \
    # Clone ipmitool if required
    if [ "${TINYIPA_REQUIRE_IPMITOOL}" = "true" ]; then \
        attempts=1; \
        while [ "${attempts}" -le "${max_attempts}" ]; do \
            echo "Trying to clone ipmitool on attempt ${attempts}"; \
            # Make sure we're in the downloads directory and clone to a specific subdirectory
            cd /tmp/downloads && \
            rm -rf ipmitool-src && \
            if git clone --depth 1 --config http.sslVerify=false https://github.com/ipmitool/ipmitool.git ipmitool-src 2>/dev/null; then \
                cd ipmitool-src && \
                git reset "${IPMITOOL_GIT_HASH}" --hard 2>/dev/null && \
                cd /tmp/downloads && \
                echo "Successfully cloned ipmitool on attempt ${attempts}"; \
                IPMITOOL_SUCCESS=true; \
                break; \
            fi; \
            echo "Clone attempt ${attempts} failed for ipmitool, retrying..."; \
            rm -rf ipmitool-src; \
            attempts=$((attempts + 1)); \
            if [ "${attempts}" -gt "${max_attempts}" ]; then \
                echo "Failed to clone ipmitool after ${max_attempts} attempts - skipping"; \
                break; \
            fi; \
            sleep 5; \
        done; \
    fi && \
    \
    # Build tools if downloads succeeded
    echo "=== Building downloaded tools ===" && \
    \
    # Debug: List all files to see what was actually downloaded
    echo "=== DEBUG: Files in downloads directory ===" && \
    ls -la . && \
    echo "=== END DEBUG ===" && \
    \
    # Build qemu-utils if downloaded
    if [ "${QEMU_SUCCESS}" = "true" ]; then \
        echo "Building qemu-utils..." && \
        # Find any qemu-related archive file
        QEMU_ARCHIVE=$(ls -1 *qemu*.tar.gz 2>/dev/null | head -1) && \
        echo "Found QEMU archive: ${QEMU_ARCHIVE}" && \
        if [ -n "${QEMU_ARCHIVE}" ] && [ -f "${QEMU_ARCHIVE}" ]; then \
            echo "Extracting QEMU archive: ${QEMU_ARCHIVE}" && \
            if echo "${QEMU_ARCHIVE}" | grep -q "\.tar\.xz$"; then \
                tar -xf "${QEMU_ARCHIVE}"; \
            else \
                tar -xzf "${QEMU_ARCHIVE}"; \
            fi && \
            # Find the extracted directory
            QEMU_DIR=$(find . -maxdepth 1 -type d -name "*qemu*" | head -1) && \
            if [ -n "${QEMU_DIR}" ]; then \
                cd "${QEMU_DIR}" && \
                ./configure --disable-system --enable-tools --target-list="" && \
                make -j$(nproc) qemu-img && \
                mkdir -p /tmp/qemu-utils/usr/local/bin && \
                cp qemu-img /tmp/qemu-utils/usr/local/bin/ && \
                echo "qemu-utils build completed" && \
                cd /tmp/downloads; \
            else \
                echo "ERROR: Could not find QEMU source directory"; \
                QEMU_SUCCESS=false; \
            fi; \
        else \
            echo "ERROR: No QEMU archive files found"; \
            QEMU_SUCCESS=false; \
        fi; \
    else \
        echo "Skipping qemu-utils build due to download failure"; \
    fi && \
    \
    # Build lshw if downloaded
    if [ "${LSHW_SUCCESS}" = "true" ]; then \
        echo "Building lshw..." && \
        # Use the specific filename we downloaded
        LSHW_ARCHIVE="lshw-${LSHW_RELEASE}.tar.gz" && \
        if [ -f "${LSHW_ARCHIVE}" ]; then \
            echo "Found LSHW archive: ${LSHW_ARCHIVE}" && \
            tar -xzf "${LSHW_ARCHIVE}" && \
            # Find the extracted directory (handle GitHub vs official naming)
            LSHW_DIR=$(find . -maxdepth 1 -type d -name "*lshw*" | head -1) && \
            if [ -n "${LSHW_DIR}" ]; then \
                cd "${LSHW_DIR}" && \
                make -j$(nproc) && \
                make PREFIX=/tmp/lshw-installed/usr/local install && \
                echo "lshw build completed" && \
                cd /tmp/downloads; \
            else \
                echo "ERROR: Could not find lshw source directory"; \
                LSHW_SUCCESS=false; \
            fi; \
        else \
            echo "ERROR: LSHW archive not found: ${LSHW_ARCHIVE}"; \
            LSHW_SUCCESS=false; \
        fi; \
    else \
        echo "Skipping lshw build due to download failure"; \
    fi && \
    \
    # Build biosdevname if downloaded and required
    if [ "${TINYIPA_REQUIRE_BIOSDEVNAME}" = "true" ] && [ "${BIOSDEVNAME_SUCCESS}" = "true" ]; then \
        echo "Building biosdevname..." && \
        # Use the specific filename we downloaded
        BIOSDEVNAME_ARCHIVE="biosdevname-${BIOSDEVNAME_RELEASE}.tar.gz" && \
        if [ -f "${BIOSDEVNAME_ARCHIVE}" ]; then \
            echo "Found BIOSDEVNAME archive: ${BIOSDEVNAME_ARCHIVE}" && \
            tar -xzf "${BIOSDEVNAME_ARCHIVE}" && \
            # Find the extracted directory
            BIOSDEVNAME_DIR=$(find . -maxdepth 1 -type d -name "*biosdevname*" | head -1) && \
            if [ -n "${BIOSDEVNAME_DIR}" ]; then \
                cd "${BIOSDEVNAME_DIR}" && \
                ./configure --prefix=/tmp/biosdevname-installed/usr/local && \
                make -j$(nproc) && \
                make install && \
                echo "biosdevname build completed" && \
                cd /tmp/downloads; \
            else \
                echo "ERROR: Could not find biosdevname source directory"; \
                BIOSDEVNAME_SUCCESS=false; \
            fi; \
        else \
            echo "ERROR: BIOSDEVNAME archive not found: ${BIOSDEVNAME_ARCHIVE}"; \
            BIOSDEVNAME_SUCCESS=false; \
        fi; \
    else \
        echo "Skipping biosdevname build (not required or download failed)"; \
    fi && \
    \
    # Build ipmitool if cloned and required
    if [ "${TINYIPA_REQUIRE_IPMITOOL}" = "true" ] && [ "${IPMITOOL_SUCCESS}" = "true" ]; then \
        echo "Building ipmitool..." && \
        if [ -d "ipmitool-src" ]; then \
            cd ipmitool-src && \
            ./bootstrap && \
            ./configure --prefix=/tmp/ipmitool/usr/local && \
            make -j$(nproc) && \
            make install && \
            echo "ipmitool build completed" && \
            cd /tmp/downloads; \
        else \
            echo "ERROR: ipmitool-src directory not found"; \
            IPMITOOL_SUCCESS=false; \
        fi; \
    else \
        echo "Skipping ipmitool build (not required or clone failed)"; \
    fi && \
    \
    echo "Custom tools build phase completed (some may have been skipped due to network issues)"

# Download and build IPA (optional - may fail due to network/ssl issues)
RUN echo "=== Attempting to download and build IPA ===" && \
    mkdir -p /tmp/wheels /tmp/localpip /tmp/ipa-source && \
    \
    # Try to download IPA release with retry logic
    IPA_SUCCESS=false && \
    attempts=1 && \
    max_attempts=3 && \
    while [ "${attempts}" -le "${max_attempts}" ]; do \
        if wget --no-check-certificate --timeout=30 --tries=2 \
            "https://github.com/openstack/ironic-python-agent/archive/refs/tags/11.2.0.tar.gz" \
            -O "/tmp/ironic-python-agent-11.2.0.tar.gz"; then \
            echo "Successfully downloaded IPA release on attempt ${attempts}"; \
            cd /tmp && \
            tar -xzf ironic-python-agent-11.2.0.tar.gz --strip-components=1 -C ipa-source && \
            echo "Successfully extracted IPA release 11.2.0" && \
            IPA_SUCCESS=true; \
            break; \
        fi; \
        echo "Download attempt ${attempts} failed for IPA, retrying..."; \
        rm -rf /tmp/ironic-python-agent-11.2.0.tar.gz /tmp/ironic-python-agent-11.2.0 /tmp/ipa-source; \
        attempts=$((attempts + 1)); \
        if [ "${attempts}" -gt "${max_attempts}" ]; then \
            echo "Failed to download IPA after ${max_attempts} attempts - will create minimal environment"; \
            break; \
        fi; \
        sleep 5; \
    done && \
    \
    # Build IPA if successfully cloned
    if [ "${IPA_SUCCESS}" = "true" ]; then \
        echo "Building IPA packages..." && \
        cd /tmp/ipa-source && \
        # Create PKG-INFO file to help PBR with versioning
        echo "Metadata-Version: 2.1" > PKG-INFO && \
        echo "Name: ironic-python-agent" >> PKG-INFO && \
        echo "Version: 11.2.0" >> PKG-INFO && \
        # Set PBR_VERSION environment variable to override version detection
        export PBR_VERSION=11.2.0 && \
        python3 setup.py sdist --dist-dir /tmp/localpip --quiet && \
        python3 -m pip wheel -c /dev/null --wheel-dir /tmp/wheels -r requirements.txt && \
        python3 -m pip wheel -c /dev/null --no-index --pre --wheel-dir /tmp/wheels --find-links=/tmp/localpip --find-links=/tmp/wheels ironic-python-agent && \
        echo "IPA build completed"; \
    else \
        echo "Skipping IPA build due to clone failure - creating minimal wheel directory"; \
        touch /tmp/wheels/.placeholder /tmp/ipa-source/.placeholder; \
    fi

# Final stage - TinyIPA runtime with minimal packages
FROM tinycore-extractor AS final-extractor

# Copy build_files for final requirements
COPY build_files/ /build_files/

# Extract final requirements packages
RUN set -eux; \
    # Set TARGETARCH for package selection
    if [ -z "${TARGETARCH:-}" ]; then \
      case "$(uname -m)" in \
        x86_64) TARGETARCH=amd64 ;; \
        aarch64) TARGETARCH=arm64 ;; \
        armv7l) TARGETARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
      esac; \
    fi; \
    \
    # Set architecture-specific variables
    case "${TARGETARCH}" in \
        "amd64") \
            TC_ARCH="x86_64"; \
            BUILD_DIR="/build_files/amd64"; \
            ;; \
        "arm64") \
            TC_ARCH="aarch64"; \
            BUILD_DIR="/build_files/arm64"; \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}"; \
            exit 1; \
            ;; \
    esac; \
    \
    export TC_ARCH BUILD_DIR; \
    TINYCORE_MIRROR_URL="http://repo.tinycorelinux.net"; \
    TC_RELEASE="16.x"; \
    \
    mkdir -p /tcz-packages /final-extracted; \
    cd /tcz-packages; \
    \
    # Function to download dependencies recursively
    download_deps() { \
        local package=$1; \
        local processed_file="/tmp/deps/processed_${package%%.tcz}"; \
        \
        # Skip if already processed
        if [ -f "${processed_file}" ]; then \
            return 0; \
        fi; \
        \
        echo "Processing package: ${package}"; \
        touch "${processed_file}"; \
        \
        # Download dependency file
        local dep_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}.dep"; \
        local temp_dep_file="/tmp/deps/${package%%.tcz}.dep"; \
        \
        if wget --timeout=30 --tries=1 -q "${dep_url}" -O "${temp_dep_file}" 2>/dev/null; then \
            echo "Found dependencies for ${package}"; \
            while IFS= read -r dep_package; do \
                if [ -n "${dep_package}" ] && [ "${dep_package}" != "${dep_package#\#}" ]; then \
                    continue; \
                fi; \
                if [ -n "${dep_package}" ]; then \
                    echo "Installing dependency: ${dep_package}"; \
                    download_deps "${dep_package}"; \
                fi; \
            done < "${temp_dep_file}"; \
        fi; \
        \
        # Download the actual package if not already downloaded
        if [ ! -f "${package}" ]; then \
            local tcz_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}"; \
            echo "Downloading ${package}"; \
            if ! wget --timeout=30 --tries=3 -q "${tcz_url}" -O "${package}"; then \
                echo "WARNING: Failed to download ${package}"; \
            fi; \
        fi; \
    }; \
    \
    mkdir -p /tmp/deps; \
    \
    # Process finalreqs.lst
    if [ -f "${BUILD_DIR}/finalreqs.lst" ]; then \
        echo "Processing finalreqs.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < "${BUILD_DIR}/finalreqs.lst"; \
    fi; \
    \
    # Process finalreqs_python3.lst
    if [ -f "${BUILD_DIR}/finalreqs_python3.lst" ]; then \
        echo "Processing finalreqs_python3.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < "${BUILD_DIR}/finalreqs_python3.lst"; \
    fi; \
    \
    # Add SSH support
    download_deps "openssh.tcz"; \
    \
    # Add SSL/TLS support packages
    download_deps "openssl.tcz"; \
    download_deps "ca-certificates.tcz"

# Extract final packages
RUN cd /tcz-packages && \
    echo "Extracting final packages..." && \
    for tcz in *.tcz; do \
        if [ -f "${tcz}" ]; then \
            echo "Extracting ${tcz}"; \
            package_name="${tcz%%.tcz}"; \
            \
            # Extract the squashfs first
            if unsquashfs -f -d /final-extracted "${tcz}" >/dev/null 2>&1; then \
                echo "Successfully extracted ${tcz}"; \
                \
                # Special handling for Python packages - create symlinks
                if echo "${package_name}" | grep -q "python3"; then \
                    echo "Setting up Python environment for ${package_name}"; \
                    if [ -f "/final-extracted/usr/local/bin/python3.11" ] && [ ! -f "/final-extracted/usr/local/bin/python3" ]; then \
                        ln -sf python3.11 /final-extracted/usr/local/bin/python3; \
                        echo "Created python3 symlink"; \
                    fi; \
                    if [ -f "/final-extracted/usr/local/bin/python3.11" ] && [ ! -f "/final-extracted/usr/local/bin/python" ]; then \
                        ln -sf python3.11 /final-extracted/usr/local/bin/python; \
                        echo "Created python symlink"; \
                    fi; \
                    if [ -f "/final-extracted/usr/local/bin/python3.9" ] && [ ! -f "/final-extracted/usr/local/bin/python3" ]; then \
                        ln -sf python3.9 /final-extracted/usr/local/bin/python3; \
                        echo "Created python3 symlink"; \
                    fi; \
                    if [ -f "/final-extracted/usr/local/bin/python3.9" ] && [ ! -f "/final-extracted/usr/local/bin/python" ]; then \
                        ln -sf python3.9 /final-extracted/usr/local/bin/python; \
                        echo "Created python symlink"; \
                    fi; \
                fi; \
                \
                # Mark package as installed
                mkdir -p /final-extracted/usr/local/tce.installed; \
                touch "/final-extracted/usr/local/tce.installed/${package_name}"; \
            else \
                echo "Failed to extract ${tcz}"; \
            fi; \
        fi; \
    done && \
    echo "Final package extraction completed"

FROM tinycore-base AS tinyipa

# Switch to root for setup operations
USER root

# Copy final extracted packages
COPY --from=final-extractor /final-extracted /

# Copy built tools from build stage (create directories for missing tools)
RUN mkdir -p /tmp/qemu-utils /tmp/lshw-installed /tmp/biosdevname-installed /tmp/ipmitool /tmp/wheelhouse /tmp/ipa-source

# Copy any built tools that exist (will be empty directories if builds failed)
COPY --from=tinyipa-build /tmp/qemu-utils /tmp/qemu-utils/
COPY --from=tinyipa-build /tmp/lshw-installed /tmp/lshw-installed/
# COPY --from=tinyipa-build /tmp/biosdevname-installed /tmp/biosdevname-installed/
COPY --from=tinyipa-build /tmp/ipmitool /tmp/ipmitool/
COPY --from=tinyipa-build /tmp/wheels /tmp/wheelhouse/
COPY --from=tinyipa-build /tmp/ipa-source /tmp/ipa-source/

# Copy build files
COPY build_files/ /tmp/build_files/

# Set up final TinyIPA environment
RUN echo "=== Setting up final TinyIPA environment ===" && \
    # Set up library paths like finalise-tinyipa.sh does
    echo "Setting up library paths..." && \
    mkdir -p /etc && \
    echo "/usr/local/lib" >> /etc/ld.so.conf && \
    ldconfig && \
    echo "Updated ldconfig cache" && \
    \
    # Install built tools if they exist
    echo "Installing built tools..." && \
    if [ "$(ls -A /tmp/qemu-utils 2>/dev/null)" ]; then \
        cp -r /tmp/qemu-utils/* /; \
        echo "Installed qemu-utils"; \
    else \
        echo "No qemu-utils to install"; \
    fi && \
    if [ "$(ls -A /tmp/lshw-installed 2>/dev/null)" ]; then \
        cp -r /tmp/lshw-installed/* /; \
        echo "Installed lshw"; \
    else \
        echo "No lshw to install"; \
    fi && \
    if [ "$(ls -A /tmp/biosdevname-installed 2>/dev/null)" ]; then \
        cp -r /tmp/biosdevname-installed/* /; \
        echo "Installed biosdevname"; \
    else \
        echo "No biosdevname to install"; \
    fi && \
    if [ "$(ls -A /tmp/ipmitool 2>/dev/null)" ]; then \
        cp -r /tmp/ipmitool/* /; \
        echo "Installed ipmitool"; \
    else \
        echo "No ipmitool to install"; \
    fi && \
    \
    # Set up Python environment
    PYTHON_EXE="" && \
    echo "Searching for Python executable..." && \
    for candidate in /usr/local/bin/python3.11 /usr/bin/python3.11 /usr/local/bin/python3.9 /usr/bin/python3.9 /usr/local/bin/python3 /usr/bin/python3 /usr/local/bin/python /usr/bin/python; do \
        echo "Checking candidate: $candidate"; \
        if [ -f "$candidate" ]; then \
            PYTHON_EXE="$candidate"; \
            echo "Found Python executable: $PYTHON_EXE"; \
            break; \
        fi; \
    done && \
    \
    # Also search in likely locations
    if [ -z "$PYTHON_EXE" ]; then \
        echo "Searching in additional locations..."; \
        find /usr -name "python*" -type f -executable 2>/dev/null | head -10; \
        # Try a basic python command
        if command -v python3 >/dev/null 2>&1; then \
            PYTHON_EXE="$(command -v python3)"; \
            echo "Found python3 via command: $PYTHON_EXE"; \
        elif command -v python >/dev/null 2>&1; then \
            PYTHON_EXE="$(command -v python)"; \
            echo "Found python via command: $PYTHON_EXE"; \
        fi; \
    fi && \
    \
    if [ -n "$PYTHON_EXE" ]; then \
        echo "Using Python executable: $PYTHON_EXE"; \
        # Create symlinks like finalise-tinyipa.sh does
        if [ ! -f /usr/local/bin/python3 ]; then \
            ln -sf "$PYTHON_EXE" /usr/local/bin/python3; \
            echo "Created python3 symlink"; \
        fi; \
        if [ ! -f /usr/local/bin/python ]; then \
            ln -sf "$PYTHON_EXE" /usr/local/bin/python; \
            echo "Created python symlink"; \
        fi; \
        \
        # Install pip and IPA like finalise-tinyipa.sh does
        echo "Setting up pip..."; \
        $PYTHON_EXE -m ensurepip 2>/dev/null || echo "ensurepip not available, continuing..."; \
        if command -v pip3 >/dev/null 2>&1; then \
            pip3 install --upgrade pip wheel || echo "pip upgrade failed, continuing..."; \
        fi; \
        if [ "$(ls -A /tmp/wheelhouse 2>/dev/null)" ]; then \
            echo "Attempting to install IPA from wheels..."; \
            $PYTHON_EXE -m pip install --no-index --find-links=file:///tmp/wheelhouse --pre ironic_python_agent || echo "IPA installation failed - continuing without it"; \
        else \
            echo "No wheel packages found - skipping IPA installation"; \
        fi; \
    else \
        echo "WARNING: No Python executable found - continuing without Python support"; \
    fi && \
    \
    # Copy configuration files like finalise-tinyipa.sh
    # Set TARGETARCH for build file selection
    if [ -z "${TARGETARCH:-}" ]; then \
      case "$(uname -m)" in \
        x86_64) TARGETARCH=amd64 ;; \
        aarch64) TARGETARCH=arm64 ;; \
        armv7l) TARGETARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;; \
      esac; \
    fi && \
    BUILD_FILES_ARCH="/tmp/build_files/${TARGETARCH}" && \
    cp /tmp/build_files/bootlocal.sh /opt/ && \
    cp /tmp/build_files/dhcp.sh /etc/init.d/dhcp.sh && \
    cp /tmp/build_files/modprobe.conf /etc/modprobe.conf && \
    mkdir -p /tmp/overrides && \
    cp "${BUILD_FILES_ARCH}/fakeuname" /tmp/overrides/uname && \
    cp /tmp/build_files/ntpdate /bin/ntpdate && \
    chmod 755 /bin/ntpdate && \
    \
    # Set up SSH like finalise-tinyipa.sh does
    if [ -f /usr/local/etc/ssh/sshd_config.orig ]; then \
        cp /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config && \
        echo "PasswordAuthentication no" >> /usr/local/etc/ssh/sshd_config && \
        ssh-keygen -t rsa -N "" -f /usr/local/etc/ssh/ssh_host_rsa_key && \
        ssh-keygen -t ed25519 -N "" -f /usr/local/etc/ssh/ssh_host_ed25519_key && \
        echo "HostKey /usr/local/etc/ssh/ssh_host_rsa_key" >> /usr/local/etc/ssh/sshd_config && \
        echo "HostKey /usr/local/etc/ssh/ssh_host_ed25519_key" >> /usr/local/etc/ssh/sshd_config && \
        echo "SSH configured successfully"; \
    elif [ -f /usr/local/etc/ssh/sshd_config ]; then \
        echo "PasswordAuthentication no" >> /usr/local/etc/ssh/sshd_config && \
        ssh-keygen -t rsa -N "" -f /usr/local/etc/ssh/ssh_host_rsa_key && \
        ssh-keygen -t ed25519 -N "" -f /usr/local/etc/ssh/ssh_host_ed25519_key && \
        echo "HostKey /usr/local/etc/ssh/ssh_host_rsa_key" >> /usr/local/etc/ssh/sshd_config && \
        echo "HostKey /usr/local/etc/ssh/ssh_host_ed25519_key" >> /usr/local/etc/ssh/sshd_config && \
        echo "SSH configured successfully"; \
    else \
        echo "WARNING: SSH configuration files not found - skipping SSH setup"; \
    fi && \
    \
    # Set up hwclock workaround like finalise-tinyipa.sh
    mkdir -p /var/lib/hwclock && \
    touch /var/lib/hwclock/adjtime && \
    chmod 640 /var/lib/hwclock/adjtime && \
    \
    # Create symlinks like finalise-tinyipa.sh does for Ansible compatibility
    echo "Creating symlinks for Ansible compatibility..." && \
    cd /usr/local/sbin && \
    for target in *; do \
        if [ ! -f "/usr/sbin/${target}" ]; then \
            ln -sf "/usr/local/sbin/${target}" "/usr/sbin/${target}"; \
        fi; \
    done && \
    cd /usr/local/bin && \
    for target in *; do \
        if [ ! -f "/usr/bin/${target}" ]; then \
            ln -sf "/usr/local/bin/${target}" "/usr/bin/${target}"; \
        fi; \
    done && \
    # Symlink bash to sh if needed
    if [ ! -f "/bin/sh" ]; then \
        ln -sf "/bin/bash" "/bin/sh"; \
    fi && \
    \
    # Clean up
    rm -rf /tmp/qemu-utils /tmp/lshw-installed /tmp/biosdevname-installed /tmp/ipmitool /tmp/wheelhouse /tmp/build_files /tmp/ipa-source && \
    \
    # Change ownership back to tc user
    chown -R tc:staff /home/tc

# Create the final initramfs and prepare kernel
RUN echo "=== Creating final initramfs ===" && \
    VMLINUZ_NAME="vmlinuz64" && \
    # Create initramfs using the same method as finalise-tinyipa.sh
    mkdir -p /output && \
    cd / && \
    find . -path ./output -prune -o -type f -print | cpio -o -H newc | gzip -9 > /output/tinyipa.gz && \
    echo "Created initramfs: /output/tinyipa.gz" && \
    \
    # Copy kernel from tinycore-extractor stage
    echo "Copying kernel..." && \
    ls -la "/rootfs/${VMLINUZ_NAME}" 2>/dev/null || echo "Kernel not found at /rootfs/${VMLINUZ_NAME}"

# Copy kernel from extractor stage
COPY --from=tinycore-extractor /rootfs/vmlinuz64 /output/tinyipa.vmlinuz

# Switch back to tc user
USER tc
ENV HOME="/home/tc"

# Final output stage to make files easily accessible
FROM scratch AS output
COPY --from=tinyipa /output/ /
