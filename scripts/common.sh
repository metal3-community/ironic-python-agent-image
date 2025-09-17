#!/bin/bash

WORKDIR=$(readlink -f "$0" | xargs dirname || true)

ARCH=${ARCH:-$(uname -m)}
case "${ARCH}" in
"x86_64")
  TC_ARCH="x86_64"
  export TINYIPA_PYTHON_EXE="${TINYIPA_PYTHON_EXE:-python3.9}"
  export CORE_NAME="corepure64"
  export VMLINUZ_NAME="vmlinuz64"
  export KERNEL_VERSION="6.12.11-tinycore64"
  # For x86_64, modify ldconfig to handle x86-64 libraries
  export LDCONFIG_MOD=true
  export PIP_COMMAND="pip3"
  ;;
"aarch64" | "arm64")
  TC_ARCH="aarch64"
  export TINYIPA_PYTHON_EXE="${TINYIPA_PYTHON_EXE:-python3.11}"
  export CORE_NAME="corepure64"
  export VMLINUZ_NAME="vmlinuz64"
  export KERNEL_VERSION="6.12.25-piCore-v8"
  # For arm64, ldconfig modification is not needed
  export LDCONFIG_MOD=false
  export PIP_COMMAND="${TINYIPA_PYTHON_EXE} -m pip"
  ;;
*)
  echo "Unsupported architecture: ${ARCH}"
  exit 1
  ;;
esac
export TC_ARCH="${TC_ARCH:-x86_64}"

# TinyCore release version
TC_RELEASE="16.x"

source "${WORKDIR}/tc-mirror.sh"

export BUILDDIR="${WORKDIR}/tinyipabuild"
export PIP_VERSION="21.3.1"

TINYIPA_REQUIRE_BIOSDEVNAME=${TINYIPA_REQUIRE_BIOSDEVNAME:-false}
TINYIPA_REQUIRE_IPMITOOL=${TINYIPA_REQUIRE_IPMITOOL:-true}

# PYTHON_EXTRA_SOURCES_DIR_LIST is a csv list of python package dirs to include
PYTHON_EXTRA_SOURCES_DIR_LIST=${PYTHON_EXTRA_SOURCES_DIR_LIST:-}

# Allow an extension to be added to the generated files by specifying
# $BRANCH_PATH e.g. export BRANCH_PATH=master results in tinyipa-master.gz etc
BRANCH_EXT=''
if [[ -n "${BRANCH_PATH:-}" ]]; then
  BRANCH_EXT="-${BRANCH_PATH}"
fi
export BRANCH_EXT

TC="${TC:-1001}"
STAFF="${STAFF:-50}"

CHROOT_PATH="/tmp/overrides:/usr/local/sbin:/usr/local/bin:/apps/bin:/usr/sbin:/usr/bin:/sbin:/bin"

function setup_tce {
  # Setup resolv.conf, add mirrors, mount proc
  local dst_dir="$1"

  CHROOT_CMD="chroot ${dst_dir} /usr/bin/env -i PATH=${CHROOT_PATH} http_proxy=${http_proxy:-} https_proxy=${https_proxy:-} no_proxy=${no_proxy:-}"
  TC_CHROOT_CMD="sudo chroot --userspec=${TC}:${STAFF} ${DST_DIR:-} /usr/bin/env -i PATH=${CHROOT_PATH} http_proxy=${http_proxy:-} https_proxy=${https_proxy:-} no_proxy=${no_proxy:-}"

  # Find a working TC mirror if none is explicitly provided
  choose_tc_mirror

  # Ensure necessary directories exist
  mkdir -p "${dst_dir}/etc"
  mkdir -p "${dst_dir}/opt"

  # Backup and setup resolv.conf
  if [[ -f "${dst_dir}/etc/resolv.conf" ]]; then
    cp "${dst_dir}/etc/resolv.conf" "${dst_dir}/etc/resolv.conf.old"
  fi
  cp /etc/resolv.conf "${dst_dir}/etc/resolv.conf"

  # Ensure opt directory exists and backup existing tcemirror if it exists
  if [[ -f "${dst_dir}/opt/tcemirror" ]]; then
    cp -a "${dst_dir}/opt/tcemirror" "${dst_dir}/opt/tcemirror.old"
  fi

  sh -c "echo ${TINYCORE_MIRROR_URL} > ${dst_dir}/opt/tcemirror"

  # Ensure necessary directories exist for tce setup
  mkdir -p "${dst_dir}/tmp/builtin/optional"
  mkdir -p "${dst_dir}/etc/sysconfig"

  ${CHROOT_CMD} chown -R "${TC}:${STAFF}" /tmp/builtin
  ${CHROOT_CMD} chmod -R a+w /tmp/builtin
  ${CHROOT_CMD} ln -sf /tmp/builtin /etc/sysconfig/tcedir
  echo "tc" | ${CHROOT_CMD} tee -a /etc/sysconfig/tcuser

  # Mount /proc for chroot commands
  mount --bind /proc "${dst_dir}/proc"
}

function cleanup_tce {
  local dst_dir="$1"

  # Unmount /proc and clean up everything
  umount "${dst_dir}/proc"
  rm -rf "${dst_dir}/tmp/builtin"
  rm -rf "${dst_dir}/tmp/tcloop"
  rm -rf "${dst_dir}/usr/local/tce.installed"
  # Restore tcemirror backup if it exists
  if [[ -f "${dst_dir}/opt/tcemirror.old" ]]; then
    mv "${dst_dir}/opt/tcemirror.old" "${dst_dir}/opt/tcemirror"
  else
    rm -f "${dst_dir}/opt/tcemirror"
  fi
  # Restore resolv.conf backup if it exists
  if [[ -f "${dst_dir}/etc/resolv.conf.old" ]]; then
    mv "${dst_dir}/etc/resolv.conf.old" "${dst_dir}/etc/resolv.conf"
  fi
  rm -f "${dst_dir}/etc/sysconfig/tcuser"
  rm -f "${dst_dir}/etc/sysconfig/tcedir"
}

function extract_tcz() {
  local tcz_file=$1
  local extract_dir=$2

  package="$(basename "${tcz_file}")"
  package_name="${package%%.tcz}"

  # Extract using unsquashfs
  if unsquashfs -f -d "${extract_dir}" "${tcz_file}" >/dev/null 2>&1; then
    echo "Extracted ${package} successfully"

    # Copy contents to builddir, preserving permissions and structure
    if [[ -d "${extract_dir}" ]]; then
      echo "Successfully installed ${package}"

      for f in "${extract_dir}/usr/local/share/${package_name}"/*/*.tar.gz; do
        if [[ -f "${f}" ]]; then
          echo "Extracting additional archive ${f} for ${package}"
          tar -xzf "${f}" -C "${extract_dir}/"
        fi
      done

      # Special handling for Python packages
      if [[ "${package}" == python3.* ]]; then
        echo "Setting up Python environment for ${package}"

        # Create python3 symlink if python3.11 exists
        if [[ -f "${extract_dir}/usr/local/bin/python3.11" ]] && [[ ! -f "${extract_dir}/usr/local/bin/python3" ]]; then
          ln -sf python3.11 "${extract_dir}/usr/local/bin/python3"
          echo "Created python3 symlink"
        fi

        # Also create python symlink if it doesn't exist
        if [[ -f "${extract_dir}/usr/local/bin/python3.11" ]] && [[ ! -f "${extract_dir}/usr/local/bin/python" ]]; then
          ln -sf python3.11 "${extract_dir}/usr/local/bin/python"
          echo "Created python symlink"
        fi

        # Set up library paths
        if [[ -d "${extract_dir}/usr/local/lib" ]]; then
          # Add library path to ld.so.conf if it doesn't exist
          mkdir -p "${extract_dir}/etc"
          if ! grep -q "/usr/local/lib" "${extract_dir}/etc/ld.so.conf" 2>/dev/null; then
            echo "/usr/local/lib" >>"${extract_dir}/etc/ld.so.conf"
            echo "Added /usr/local/lib to ld.so.conf"
          fi
        fi

        # Update ldconfig cache if ldconfig exists
        if [[ -f "${extract_dir}/sbin/ldconfig" ]]; then
          chroot "${extract_dir}" /sbin/ldconfig 2>/dev/null || true
        fi
      fi

      # Mark package as installed
      mkdir -p "${extract_dir}/usr/local/tce.installed"
      touch "${extract_dir}/usr/local/tce.installed/${package_name}"
      return 0
    else
      echo "No extracted content found for ${package}"
    fi
  else
    echo "Failed to extract ${package} with unsquashfs"
  fi

  return 0
}

function download_and_extract_tcz() {
  local package=$1
  local builddir=$2
  local skip_deps=${3:-false}
  local attempts=1

  # Replace KERNEL placeholder with the correct version string for the architecture
  package="${package//KERNEL/${KERNEL_VERSION}}"

  local tcz_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}"
  local dep_url="${TINYCORE_MIRROR_URL}/${TC_RELEASE}/${TC_ARCH}/tcz/${package}.dep"
  local download_retry_max=${DOWNLOAD_RETRY_MAX:-5}
  local download_retry_delay=${DOWNLOAD_RETRY_DELAY:-10} # Check if package is already installed
  local package_name=${package%%.tcz}
  if [[ -f "${builddir}/usr/local/tce.installed/${package_name}" ]]; then
    echo "Package ${package} already installed, skipping"
    return 0
  fi

  # First, download and install dependencies unless explicitly skipped
  if [[ "${skip_deps}" = "false" ]]; then
    echo "Checking dependencies for ${package}"
    local temp_dep_file="/tmp/deps_${package_name}_$$"
    if wget --timeout=30 --tries=1 -q "${dep_url}" -O "${temp_dep_file}" 2>/dev/null; then
      echo "Found dependencies for ${package}"
      while IFS= read -r dep_package; do
        if [[ -n "${dep_package}" ]] && [[ ! "${dep_package}" =~ ^#.* ]]; then
          echo "Installing dependency: ${dep_package}"
          download_and_extract_tcz "${dep_package}" "${builddir}" false
        fi
      done <"${temp_dep_file}"
      rm -f "${temp_dep_file}"
    else
      echo "No dependencies found for ${package}"
    fi
  fi

  echo "Downloading and extracting package ${package}"
  while [[ "${attempts}" -le "${download_retry_max}" ]]; do
    tmp_dir_root="/tmp"
    # Create temporary directory for this package
    local temp_dir="${tmp_dir_root}/tcz_${package%%.tcz}_$$"
    mkdir -p "${temp_dir}"

    # Download the TCZ package
    if wget --timeout=30 --tries=3 -q "${tcz_url}" -O "${temp_dir}/${package}"; then
      echo "Downloaded ${package} successfully"

      if extract_tcz "${temp_dir}/${package}" "${builddir}"; then
        rm -rf "${temp_dir}"
        return 0
      fi
    else
      echo "Failed to download ${package} from ${tcz_url}"
    fi

    rm -rf "${temp_dir}"
    echo "Package installation attempt ${attempts} failed for ${package}, retrying in ${download_retry_delay} seconds..."
    sleep "${download_retry_delay}"
    attempts=$((attempts + 1))
  done

  echo "Failed to install ${package} after ${download_retry_max} attempts"
  return 1
}
