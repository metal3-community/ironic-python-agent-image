# syntax=docker/dockerfile:1-labs

# Multi-stage Dockerfile for TinyIPA
# Extracts rootfs for different architectures and builds the final image

# Build stage - TinyCore base extraction
FROM debian:bookworm-slim AS tinycore-extractor

ARG TARGETARCH
ARG TINYCORE_VERSION=16
ARG TINYCORE_MIRROR_URL=http://tinycorelinux.net/${TINYCORE_VERSION}.x
ARG TC_RELEASE=${TINYCORE_VERSION}.x
ARG PICORE_VERSION=${TINYCORE_VERSION}.0.0

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
            PICORE_IMG_URL="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/release/RPi/piCore64-${TINYCORE_VERSION}.0.0.img.gz"; \
            \
            # Download the compressed image with retry logic
            attempts=1; \
            max_attempts=5; \
            while [ "${attempts}" -le "${max_attempts}" ]; do \
                if wget --timeout=30 --tries=3 -q "${PICORE_IMG_URL}" -O "piCore64-${TINYCORE_VERSION}.0.0.img.gz"; then \
                    echo "Successfully downloaded piCore image on attempt ${attempts}"; \
                    break; \
                fi; \
                echo "Download attempt ${attempts} failed, retrying..."; \
                attempts=$((attempts + 1)); \
                if [ "${attempts}" -gt "${max_attempts}" ]; then \
                    echo "Failed to download piCore image after ${max_attempts} attempts"; \
                    exit 1; \
                fi; \
                sleep 10; \
            done; \
            \
            # Extract the image
            echo "Extracting piCore image..."; \
            gunzip -f "piCore64-${TINYCORE_VERSION}.0.0.img.gz"; \
            \
            # Mount the image to extract rootfs and kernel
            echo "Mounting piCore image to extract components..."; \
            dd if="piCore64-${TINYCORE_VERSION}.0.0.img" of=boot.fat bs=512 skip=8192 count=163840; \
            dd if="piCore64-${TINYCORE_VERSION}.0.0.img" of=root.ext4 bs=512 skip=172032 count=32768; \
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
            # Extract rootfs - look for rootfs file
            ROOTFS_FILE="/tmp/picore_boot/rootfs-piCore64-${TINYCORE_VERSION}.0.gz"; \
            if [ ! -f "${ROOTFS_FILE}" ]; then \
                echo "ERROR: Could not find rootfs-piCore64-${TINYCORE_VERSION}.0.gz in boot partition"; \
                ls -la /tmp/picore_boot/; \
                exit 1; \
            fi; \
            \
            # Extract the pre-compressed rootfs to /rootfs
            echo "Extracting rootfs..."; \
            gzip -dc "${ROOTFS_FILE}" | bsdtar -C /rootfs -xf -; \
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
FROM scratch AS tinyipa

# Copy the extracted rootfs from the build stage
COPY --from=tinycore-extractor /rootfs/ /

# Set up basic environment
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV SHELL="/bin/sh"
ENV HOME="/root"

# Create necessary directories and files if they don't exist
RUN mkdir -p /proc /sys /dev /tmp /var/log /etc && \
    echo "root:x:0:0:root:/root:/bin/sh" >> /etc/passwd && \
    echo "root:x:0:" >> /etc/group && \
    chown -R "0:0" /usr/bin/sudo && \
    chmod 4755 /usr/bin/sudo

USER tc

# Default command
CMD ["/bin/sh"]
