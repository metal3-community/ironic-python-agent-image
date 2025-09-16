# Packer Build Variables
# This file contains variable definitions for the TinyIPA Packer build

# Target architecture (x86_64, aarch64)
arch = ""

# Output directory for build artifacts
output_dir = "output"

# Branch extension for output filenames
branch_path = ""

# Include biosdevname support
require_biosdevname = false

# Include ipmitool support
require_ipmitool = true

# Base Docker image
base_image = "ubuntu:24.04"