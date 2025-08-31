#!/bin/bash

set -e

# TinyIPA Packer Build Script
# Builds TinyIPA kernel and ramdisk using Packer and Docker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Default values
ARCH="${ARCH:-$(uname -m)}"
OUTPUT_DIR="$(mktemp -d -t tinyipa-output-XXXXXX)"
CLEAN=false
PARALLEL=false
PACKER_LOG_LEVEL="${PACKER_LOG_LEVEL:-}"

# Convert architecture names
case "${ARCH}" in
    "arm64")
        ARCH="aarch64"
        ;;
    "amd64")
        ARCH="x86_64"
        ;;
esac

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build TinyIPA using Packer and Docker.

OPTIONS:
    -a, --arch ARCH         Target architecture (x86_64, aarch64)
                           Default: current architecture (${ARCH})
    
    -o, --output DIR        Output directory for artifacts
                           Default: ${OUTPUT_DIR}
    
    -c, --clean             Clean output directory before building
    
    -p, --parallel          Build multiple architectures in parallel
    
    -v, --verbose           Enable verbose Packer logging
    
    -h, --help              Show this help message

EXAMPLES:
    # Build for current architecture
    $0
    
    # Build for specific architecture
    $0 --arch aarch64
    
    # Build with custom output directory
    $0 --output /path/to/output
    
    # Clean build with verbose logging
    $0 --clean --verbose
    
    # Build both architectures in parallel
    $0 --parallel

ENVIRONMENT VARIABLES:
    ARCH                           Target architecture
    BRANCH_PATH                    Branch extension for filenames
    TINYIPA_REQUIRE_BIOSDEVNAME    Include biosdevname (true/false)
    TINYIPA_REQUIRE_IPMITOOL       Include ipmitool (true/false)
    PACKER_LOG                     Enable Packer logging (1 for debug)
    PACKER_LOG_LEVEL              Packer log level (TRACE, DEBUG, INFO, WARN, ERROR)

PACKER VARIABLES:
    You can also pass Packer variables directly:
    
    $0 -var 'require_biosdevname=true' -var 'branch_path=my-branch'

EOF
}

# Parse command line arguments
PACKER_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -p|--parallel)
            PARALLEL=true
            shift
            ;;
        -v|--verbose)
            export PACKER_LOG=1
            export PACKER_LOG_LEVEL="DEBUG"
            shift
            ;;
        -var|--var)
            PACKER_ARGS+=("-var" "$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate architecture
case "${ARCH}" in
    "x86_64"|"aarch64")
        ;;
    *)
        echo "Unsupported architecture: ${ARCH}"
        echo "Supported: x86_64, aarch64"
        exit 1
        ;;
esac

echo "TinyIPA Packer Build"
echo "===================="
echo "Architecture: ${ARCH}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "Clean: ${CLEAN}"
echo "Parallel: ${PARALLEL}"
echo

# Check if Packer is installed
if ! command -v packer >/dev/null 2>&1; then
    echo "Error: Packer is not installed"
    echo "Please install Packer from https://www.packer.io/downloads"
    exit 1
fi

# Check if Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed or not accessible"
    echo "Please install Docker and ensure it's running"
    exit 1
fi

# Clean output directory if requested
if [[ "${CLEAN}" = true ]]; then
    echo "Cleaning output directory..."
    rm -rf "${OUTPUT_DIR}"
fi

# Create output directory and cache subdirectories
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/cache/pip"
mkdir -p "${OUTPUT_DIR}/cache/tinycore"
mkdir -p "${OUTPUT_DIR}/workspace"
mkdir -p "${OUTPUT_DIR}/debug/builddir"
mkdir -p "${OUTPUT_DIR}/debug/chroot"

echo "Build directories created:"
echo "  Output: ${OUTPUT_DIR}"
echo "  Cache: ${OUTPUT_DIR}/cache/"
echo "  Workspace: ${OUTPUT_DIR}/workspace/"
echo "  Debug builddir: ${OUTPUT_DIR}/debug/builddir/"
echo "  Debug chroot: ${OUTPUT_DIR}/debug/chroot/"

# Set environment variables for Packer
export ARCH
export BRANCH_PATH="${BRANCH_PATH:-}"
export TINYIPA_REQUIRE_BIOSDEVNAME="${TINYIPA_REQUIRE_BIOSDEVNAME:-false}"
export TINYIPA_REQUIRE_IPMITOOL="${TINYIPA_REQUIRE_IPMITOOL:-true}"

# Build Packer variable arguments
PACKER_VARS=(
    "-var" "arch=${ARCH}"
    "-var" "output_dir=${OUTPUT_DIR}"
    "-var" "branch_path=${BRANCH_PATH}"
    "-var" "require_biosdevname=${TINYIPA_REQUIRE_BIOSDEVNAME}"
    "-var" "require_ipmitool=${TINYIPA_REQUIRE_IPMITOOL}"
)

# Add user-provided variables
PACKER_VARS+=("${PACKER_ARGS[@]}")

# Function to build for a specific architecture
build_arch() {
    local arch=$1
    echo "Building TinyIPA for ${arch}..."
    
    # Run Packer build
    if packer build \
        "${PACKER_VARS[@]}" \
        -var "arch=${arch}" \
        tinyipa.pkr.hcl; then
        echo "Successfully built TinyIPA for ${arch}"
        return 0
    else
        echo "Failed to build TinyIPA for ${arch}"
        return 1
    fi
}

# Main build logic
if [[ "${PARALLEL}" = true ]]; then
    echo "Building TinyIPA for multiple architectures in parallel..."
    
    # Build both architectures in parallel
    (
        echo "Starting x86_64 build in background..."
        ARCH=x86_64 build_arch x86_64 > "${OUTPUT_DIR}/build-x86_64.log" 2>&1 &
        X86_PID=$!
        
        echo "Starting aarch64 build in background..."
        ARCH=aarch64 build_arch aarch64 > "${OUTPUT_DIR}/build-aarch64.log" 2>&1 &
        ARM64_PID=$!
        
        # Wait for both builds to complete
        wait "${X86_PID}"
        X86_RESULT=$?
        
        wait "${ARM64_PID}"
        ARM64_RESULT=$?
        
        # Report results
        echo
        echo "Parallel Build Results:"
        echo "======================"
        if [[ "${X86_RESULT}" -eq 0 ]]; then
            echo "✅ x86_64 build: SUCCESS"
        else
            echo "❌ x86_64 build: FAILED (see ${OUTPUT_DIR}/build-x86_64.log)"
        fi
        
        if [[ "${ARM64_RESULT}" -eq 0 ]]; then
            echo "✅ aarch64 build: SUCCESS"
        else
            echo "❌ aarch64 build: FAILED (see ${OUTPUT_DIR}/build-aarch64.log)"
        fi
        
        # Exit with error if any build failed
        if [[ "${X86_RESULT}" -ne 0 ]] || [[ "${ARM64_RESULT}" -ne 0 ]]; then
            exit 1
        fi
    )
else
    # Build for single architecture
    build_arch "${ARCH}"
fi

echo
echo "Build completed!"

# List output files
if [[ -d "${OUTPUT_DIR}" ]] && [[ -n "$(ls -A "${OUTPUT_DIR}" 2>/dev/null)" ]]; then
    echo
    echo "Output artifacts:"
    echo "================"
    ls -la "${OUTPUT_DIR}"/tinyipa* 2>/dev/null || echo "No tinyipa artifacts found"
    
    echo
    echo "Build logs and manifests:"
    echo "========================"
    ls -la "${OUTPUT_DIR}"/*.txt "${OUTPUT_DIR}"/*.log 2>/dev/null || echo "No log files found"
    
    # Display checksums if available
    if ls "${OUTPUT_DIR}"/*.sha256 >/dev/null 2>&1; then
        echo
        echo "Checksums:"
        echo "=========="
        cat "${OUTPUT_DIR}"/*.sha256 2>/dev/null || true
    fi
else
    echo "No output files found in ${OUTPUT_DIR}"
fi

echo
echo "Build completed successfully!"
echo "Artifacts are available in: ${OUTPUT_DIR}"
