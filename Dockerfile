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
WORKDIR ${HOME}

# Default command
CMD ["/bin/sh"]

# Final stage - TinyIPA with pre-extracted packages
FROM tinycore-extractor AS package-extractor

ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

# Copy the build requirements lists
COPY build_files/${TARGETARCH}/buildreqs.lst /packages.lst
COPY build_files/${TARGETARCH}/fakeuname /bin/uname

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
            ;; \
        "arm64") \
            TC_ARCH="aarch64"; \
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
    if [ -f /packages.lst ]; then \
        echo "Processing packages.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < /packages.lst; \
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
                    for v in 11 9; do \
                      for p in python pip; do \
                        if [ -f "/final-extracted/usr/local/bin/${p}3.${v}" ]; then \
                            if [ ! -f "/final-extracted/usr/local/bin/${p}3" ]; then \
                                ln -sf "${p}3.11" "/final-extracted/usr/local/bin/${p}3"; \
                                echo "Created ${p}3 symlink"; \
                            fi; \
                            if [ ! -f "/final-extracted/usr/local/bin/${p}" ]; then \
                                ln -sf "${p}3.11" "/final-extracted/usr/local/bin/${p}"; \
                                echo "Created ${p} symlink"; \
                            fi; \
                        fi; \
                      done; \
                    done; \
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
    PIP_EXE="" && \
    for candidate in /usr/local/bin/pip3.11 /usr/bin/pip3.11 /usr/local/bin/pip3.9 /usr/bin/pip3.9 /usr/local/bin/pip3 /usr/bin/pip3; do \
        if [ -f "$candidate" ]; then \
            PIP_EXE="$candidate"; \
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
    else \
        echo "ERROR: No Python executable found in base system or extracted packages"; \
        exit 1; \
    fi; \
    if [ -n "$PIP_EXE" ]; then \
        # Create symlinks like common.sh does
        if [ ! -f /usr/local/bin/pip3 ]; then \
            ln -sf "$(basename "$PIP_EXE")" /usr/local/bin/pip3; \
            echo "Created pip3 symlink"; \
        fi; \
        if [ ! -f /usr/local/bin/pip ]; then \
            ln -sf "$(basename "$PIP_EXE")" /usr/local/bin/pip; \
            echo "Created pip symlink"; \
        fi; \
    else \
        echo "ERROR: No Pip executable found in base system or extracted packages"; \
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
    LSHW_SUCCESS=false && \
    BIOSDEVNAME_SUCCESS=false && \
    \
    # Download source packages with retry logic
    echo "Downloading source packages..." && \
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
    # Build tools if downloads succeeded
    echo "=== Building downloaded tools ===" && \
    \
    # Debug: List all files to see what was actually downloaded
    echo "=== DEBUG: Files in downloads directory ===" && \
    ls -la . && \
    echo "=== END DEBUG ===" && \
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
    echo "Custom tools build phase completed (some may have been skipped due to network issues)"

RUN echo "=== Installing QEMU Utils ===" && \
    mkdir -p qemu && \
    cd qemu && \
    wget --no-check-certificate --timeout=30 --tries=3 -q https://github.com/qemu/qemu/archive/refs/tags/v10.1.0.tar.gz -O- | tar -xz --strip-components 1 && \
    ./configure --disable-system --enable-tools --target-list="" --prefix=/tmp/qemu-utils/usr/local && \
    make -j$(nproc) qemu-img && \
    make install && \
    cd - && \
    rm -rf qemu && \
    echo "qemu-utils build completed"

RUN echo "=== Installing IPMI Tool ===" && \
    mkdir -p ipmitool && \
    cd ipmitool && \
    wget --no-check-certificate --timeout=30 --tries=3 -q https://github.com/ipmitool/ipmitool/archive/refs/tags/IPMITOOL_1_8_19.tar.gz -O- | tar -xz --strip-components 1 && \
    ./bootstrap && \
    ./configure --prefix=/tmp/ipmitool/usr/local && \
    make -j$(nproc) && \
    make install && \
    cd - && \
    rm -rf ipmitool && \
    echo "ipmitool build completed"

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
COPY build_files/${TARGETARCH}/finalreqs.lst /requirements.lst
COPY build_files/${TARGETARCH}/fakeuname /bin/uname

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
            ;; \
        "arm64") \
            TC_ARCH="aarch64"; \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}"; \
            exit 1; \
            ;; \
    esac; \
    \
    export TC_ARCH; \
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
    if [ -f /requirements.lst ]; then \
        echo "Processing requirements.lst"; \
        while IFS= read -r package; do \
            if [ -n "${package}" ] && [ "${package}" != "${package#\#}" ]; then \
                continue; \
            fi; \
            if [ -n "${package}" ]; then \
                download_deps "${package}"; \
            fi; \
        done < /requirements.lst; \
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
                # Extract any nested tar.gz archives like common.sh does
                for f in "/final-extracted/usr/local/share/${package_name}"/*/*.tar.gz; do \
                    if [ -f "${f}" ]; then \
                        echo "Extracting additional archive ${f} for ${package_name}"; \
                        tar -xzf "${f}" -C /final-extracted/ 2>/dev/null || true; \
                    fi; \
                done; \
                \
                # Special handling for Python packages - create symlinks
                if echo "${package_name}" | grep -q "python3"; then \
                  for v in 11 9; do \
                    for p in python pip; do \
                      if [ -f "/final-extracted/usr/local/bin/${p}3.${v}" ]; then \
                          if [ ! -f "/final-extracted/usr/local/bin/${p}3" ]; then \
                              ln -sf "${p}3.11" "/final-extracted/usr/local/bin/${p}3"; \
                              echo "Created ${p}3 symlink"; \
                          fi; \
                          if [ ! -f "/final-extracted/usr/local/bin/${p}" ]; then \
                              ln -sf "${p}3.11" "/final-extracted/usr/local/bin/${p}"; \
                              echo "Created ${p} symlink"; \
                          fi; \
                      fi; \
                    done; \
                  done; \
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

ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

# Switch to root for setup operations
USER root

# Copy final extracted packages
COPY --from=final-extractor /final-extracted /

# Copy built tools from build stage (create directories for missing tools)
RUN mkdir -p /tmp/wheelhouse /tmp/ipa-source

# Copy any built tools that exist (will be empty directories if builds failed)
COPY --from=tinyipa-build /tmp/qemu-utils /
COPY --from=tinyipa-build /tmp/lshw-installed/* /
# COPY --from=tinyipa-build /tmp/biosdevname-installed /tmp/biosdevname-installed/
COPY --from=tinyipa-build /tmp/ipmitool /
COPY --from=tinyipa-build /tmp/wheels /tmp/wheelhouse/
COPY --from=tinyipa-build /tmp/ipa-source /tmp/ipa-source/

# Copy build files individually
COPY overlay /
COPY build_files/${TARGETARCH}/fakeuname /tmp/overrides/uname

# Set up final TinyIPA environment
RUN echo "=== Setting up final TinyIPA environment ===" && \
    # Set up library paths like finalise-tinyipa.sh does
    echo "Setting up library paths..." && \
    mkdir -p /etc && \
    echo "/usr/local/lib" >> /etc/ld.so.conf && \
    ldconfig && \
    echo "Updated ldconfig cache" && \
    # Set up Python environment
    PIP_EXE="" && \
    echo "Searching for Python executable..." && \
    for candidate in /usr/local/bin/pip3.11 /usr/bin/pip3.11 /usr/local/bin/pip3.9 /usr/bin/pip3.9 /usr/local/bin/pip3 /usr/bin/pip3 /usr/local/bin/pip /usr/bin/pip; do \
        echo "Checking candidate: $candidate"; \
        if [ -f "$candidate" ]; then \
            PIP_EXE="$candidate"; \
            echo "Found Pip executable: $PIP_EXE"; \
            break; \
        fi; \
    done && \
    \
    # Also search in likely locations
    if [ -z "$PIP_EXE" ]; then \
        echo "Searching in additional locations..."; \
        find /usr -name "pip*" -type f -executable 2>/dev/null | head -10; \
        # Try a basic pip command
        if command -v pip3 >/dev/null 2>&1; then \
            PIP_EXE="$(command -v pip3)"; \
            echo "Found pip3 via command: $PIP_EXE"; \
        elif command -v pip >/dev/null 2>&1; then \
            PIP_EXE="$(command -v pip)"; \
            echo "Found python via command: $PIP_EXE"; \
        fi; \
    fi && \
    \
    if [ -n "$PIP_EXE" ]; then \
        echo "Using Python executable: $PIP_EXE"; \
        # Create symlinks like finalise-tinyipa.sh does
        if [ ! -f /usr/local/bin/pip3 ]; then \
            ln -sf "$PIP_EXE" /usr/local/bin/pip3; \
            echo "Created pip3 symlink"; \
        fi; \
        if [ ! -f /usr/local/bin/pip ]; then \
            ln -sf "$PIP_EXE" /usr/local/bin/pip; \
            echo "Created pip symlink"; \
        fi; \
        \
        if [ "$(ls -A /tmp/wheelhouse 2>/dev/null)" ]; then \
            echo "Attempting to install IPA from wheels..."; \
            $PIP_EXE install --no-index --find-links=file:///tmp/wheelhouse --pre ironic_python_agent || echo "IPA installation failed - continuing without it"; \
        else \
            echo "No wheel packages found - skipping IPA installation"; \
        fi; \
    else \
        echo "WARNING: No Python executable found - continuing without Python support"; \
    fi && \
    \
    # Set up permissions for copied files
    chmod 755 /bin/ntpdate && \
    mkdir -p /tmp/overrides && \
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
    rm -rf /tmp/wheelhouse /tmp/ipa-source && \
    \
    # Change ownership back to tc user
    chown -R tc:staff /home/tc

# Create the final initramfs and prepare kernel
RUN echo "=== Creating final initramfs ===" && \
    VMLINUZ_NAME="vmlinuz64" && \
    # Create a clean directory for the initramfs contents
    mkdir -p /tmp/initramfs-root /output && \
    \
    # Copy the entire filesystem to the initramfs directory, excluding problematic paths
    echo "Copying filesystem to initramfs directory..." && \
    cd / && \
    tar --exclude='./proc/*' \
        --exclude='./sys/*' \
        --exclude='./dev/*' \
        --exclude='./tmp/initramfs-root' \
        --exclude='./output' \
        --exclude='./tmp/tcloop' \
        --exclude='./tmp/builtin' \
        --exclude='./mnt' \
        --exclude='./media' \
        --exclude='./run' \
        --exclude='./var/run' \
        --exclude='./var/lock' \
        -cf - . | tar -xf - -C /tmp/initramfs-root && \
    \
    # Create essential directories in the initramfs
    mkdir -p /tmp/initramfs-root/proc \
             /tmp/initramfs-root/sys \
             /tmp/initramfs-root/dev \
             /tmp/initramfs-root/tmp \
             /tmp/initramfs-root/mnt \
             /tmp/initramfs-root/media \
             /tmp/initramfs-root/run \
             /tmp/initramfs-root/var/run \
             /tmp/initramfs-root/var/lock \
             /tmp/initramfs-root/tmp/tcloop \
             /tmp/initramfs-root/tmp/builtin && \
    \
    # Create the initramfs archive
    echo "Creating initramfs archive..." && \
    cd /tmp/initramfs-root && \
    if ! find . | cpio -o -H newc 2>/dev/null | gzip -9 > /output/ironic-python-agent.initramfs; then \
        echo "Error: Failed to create initramfs archive"; \
        echo "Checking initramfs root contents..."; \
        ls -la /tmp/initramfs-root/; \
        echo "Checking for incomplete files..."; \
        find /tmp/initramfs-root -type f -exec ls -la {} \; | head -20; \
        exit 1; \
    fi && \
    \
    # Verify the output file exists and has reasonable size
    if [[ ! -f /output/ironic-python-agent.initramfs ]] || [[ $(stat -c%s /output/ironic-python-agent.initramfs) -lt 1000000 ]]; then \
        echo "Error: Initramfs file is missing or too small"; \
        ls -la /output/ironic-python-agent.initramfs || echo "File does not exist"; \
        exit 1; \
    fi && \
    \
    echo "Created initramfs: $(stat -c%s /output/ironic-python-agent.initramfs) bytes" && \
    \
    # Clean up the temporary directory
    rm -rf /tmp/initramfs-root && \
    \
    echo "Initramfs creation completed successfully"

# Copy kernel from extractor stage
COPY --from=tinycore-extractor /rootfs/vmlinuz64 /output/ironic-python-agent.vmlinuz

# Switch back to tc user
USER tc
ENV HOME="/home/tc"

# Final output stage to make files easily accessible
FROM scratch AS output
COPY --from=tinyipa /output/ /
