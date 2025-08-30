=============================
Tiny Core Ironic Python Agent
=============================

This project builds a TinyCore-based Ironic Python Agent image. The build process
supports both x86_64 and ARM64 (aarch64) architectures.

Architecture Support
====================

The build scripts automatically detect the host architecture and build the 
appropriate image. Supported architectures:

* **x86_64**: Uses isolinux/syslinux for BIOS boot compatibility
* **ARM64/aarch64**: Uses GRUB configuration for EFI boot compatibility

To build for a specific architecture, set the ARCH environment variable:

.. code-block:: bash

   # Build for ARM64
   export ARCH=arm64
   make

   # Build for x86_64  
   export ARCH=x86_64
   make

Automated Builds
================

This repository uses GitHub Actions to automatically build TinyIPA images for both
architectures on every push to the main branch and for all releases.

**Download Pre-built Images:**

The latest builds are available as releases:

* **Latest builds**: `GitHub Releases <https://github.com/metal3-community/tiny-ipa/releases/tag/latest>`_
* **Tagged releases**: `All Releases <https://github.com/metal3-community/tiny-ipa/releases>`_

**Available Files:**

* ``tinyipa-x86_64.gz`` - Root filesystem for x86_64
* ``tinyipa-x86_64.vmlinuz`` - Kernel for x86_64  
* ``tinyipa-x86_64.iso`` - Bootable ISO for x86_64
* ``tinyipa-aarch64.gz`` - Root filesystem for ARM64
* ``tinyipa-aarch64.vmlinuz`` - Kernel for ARM64
* ``tinyipa-{arch}.tar.gz`` - Combined package
* ``*.sha256`` - Checksums for verification

Requirements for ARM64
======================

When building for ARM64, ensure you have:

* A piCore ARM64 base system or cross-compilation environment
* ARM64-compatible TinyCore packages
* GRUB or other EFI-compatible bootloader for final deployment

For more information, see:
https://docs.openstack.org/ironic-python-agent-builder/latest/admin/tinyipa.html
