---
applyTo: '**'
---

# Needed for the migration

## Dockerfile 1

- Build a tiny core docker image
- Run the container with elevated privileges to install tiny core build packages
- Export the filesystem as a new base layer

## Dockerfile 2
- Use the new build base layer
- Install pip dependencies for ironic-python-agent
- Build dependencies that are not tinycore packages
  - ipmitool
  - QEMU
  - LSHW
  - BIOSDEVNAME
