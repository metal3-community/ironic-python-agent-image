# Packer configuration for building TinyIPA kernel and ramdisk
# Uses pre-built Docker image with build environment

packer {
  required_plugins {
    docker = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/docker"
    }
  }
}

# Variables for build configuration
variable "arch" {
  type        = string
  default     = ""
  description = "Target architecture (x86_64, aarch64). If empty, uses host architecture."
}

variable "branch_path" {
  type        = string
  default     = ""
  description = "Branch extension for output filenames"
}

variable "require_biosdevname" {
  type        = bool
  default     = false
  description = "Include biosdevname support"
}

variable "require_ipmitool" {
  type        = bool
  default     = true
  description = "Include ipmitool support"
}

variable "output_dir" {
  type        = string
  default     = "output"
  description = "Directory for output artifacts"
}

variable "base_image" {
  type        = string
  default     = "tinyipa-builder"
  description = "Base Docker image with build environment"
}

# Local variables for computed values
locals {
  # Determine target architecture
  target_arch = var.arch != "" ? var.arch : "aarch64"

  # Platform mapping for Docker
  platform = local.target_arch == "amd64" ? "linux/amd64" : "linux/arm64"

  # Build timestamp
  timestamp = formatdate("YYYY-MM-DD-hhmm", timestamp())

  # Output filename prefix
  output_prefix = "tinyipa-${local.target_arch}"
}

# Base image builder - builds from Dockerfile
source "docker" "base" {
  build {
    path      = "Dockerfile.tinyipa-builder"
    build_dir = "."
  }
  commit     = true
  privileged = true
  platform   = local.platform
  # exec_user  = "root"

  # Mount necessary filesystems for build process
  volumes = {
    "/dev"  = "/dev"
    "/proc" = "/proc"
    "/sys"  = "/sys"
    # abspath(var.output_dir) = "/workspace/output"
  }
  tmpfs = ["/tmp/picore_boot", "/tmp/tce/optional"]

  # Add capabilities needed for mounting and device access
  # cap_add = ["SYS_ADMIN", "MKNOD", "SYS_CHROOT"]
}

# Main build configuration
build {
  name = "tinyipa-${local.target_arch}"

  sources = ["source.docker.base"]

  # Run the complete TinyIPA build process
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "TZ=UTC",
      "ARCH=${local.target_arch}",
      "BRANCH_PATH=${var.branch_path}",
      "TINYIPA_REQUIRE_BIOSDEVNAME=${var.require_biosdevname}",
      "TINYIPA_REQUIRE_IPMITOOL=${var.require_ipmitool}",
      "IPA_SOURCE_DIR=/opt/stack/ironic-python-agent"
    ]
    inline = [
      "/workspace/build-tinyipa.sh",
      "if [ \"${local.target_arch}\" = \"x86_64\" ]; then make iso; fi",
      "/workspace/finalise-tinyipa.sh",
      "/workspace/build-instance-images.sh"
    ]
  }

  # Copy output artifacts
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "TZ=UTC"
    ]
    inline = [
      "echo 'Build completed successfully!'",
      "echo 'Output files:'",
      "ls -la /workspace/*.{gz,vmlinuz,iso,img,tar.gz} 2>/dev/null || echo 'No output files found'",

      # Copy artifacts to output directory
      "mkdir -p /workspace/output",
      "cp -v /workspace/*.{gz,vmlinuz,iso,img,tar.gz} /workspace/output/ 2>/dev/null || true",
      "cp -v /workspace/*.sha256 /workspace/output/ 2>/dev/null || true",

      "echo 'Final output:'",
      "ls -la /workspace/output/"
    ]
  }
}
