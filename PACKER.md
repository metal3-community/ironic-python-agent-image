# Packer Build Guide for TinyIPA

This guide explains how to build TinyIPA using Packer with Docker for consistent, reproducible builds.

## Prerequisites

- **Packer**: Version 1.8.0 or later
- **Docker**: Version 20.10 or later
- **Platform Requirements**:
  - For ARM64 builds: ARM64 host or Docker Desktop with emulation
  - For x86_64 builds: x86_64 host or Docker Desktop with emulation

## Quick Start

### Install Packer

```bash
# On macOS using Homebrew
brew install packer

# On Ubuntu/Debian
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install packer

# On other systems, download from https://www.packer.io/downloads
```

### Build TinyIPA

```bash
# Build for current architecture
./packer-build.sh

# Build for specific architecture
./packer-build.sh --arch aarch64

# Build both architectures in parallel
./packer-build.sh --parallel

# Clean build with verbose logging
./packer-build.sh --clean --verbose
```

## Packer Configuration

The Packer configuration (`tinyipa.pkr.hcl`) uses the Docker builder to:

1. **Create Base Environment**: Start with Ubuntu 24.04 and install dependencies
2. **Setup Build User**: Create non-root user with sudo access
3. **Clone Dependencies**: Download ironic-python-agent source
4. **Build TinyIPA**: Run the standard make targets (build, finalise, iso, instance-images)
5. **Extract Artifacts**: Copy kernel, ramdisk, and other outputs

### Key Features

- **Multi-Architecture Support**: Native builds for x86_64 and ARM64
- **Reproducible Builds**: Consistent environment across all platforms
- **Artifact Management**: Automatic checksums and build manifests
- **Flexible Configuration**: Customizable via variables and environment

## Usage Examples

### Basic Builds

```bash
# Build for current architecture
./packer-build.sh

# Build for ARM64
./packer-build.sh --arch aarch64

# Build for x86_64
./packer-build.sh --arch x86_64
```

### Advanced Options

```bash
# Custom output directory
./packer-build.sh --output /my/build/output

# Enable biosdevname support
TINYIPA_REQUIRE_BIOSDEVNAME=true ./packer-build.sh

# Custom branch extension
BRANCH_PATH=my-branch ./packer-build.sh

# Parallel builds for both architectures
./packer-build.sh --parallel
```

### Using Packer Directly

```bash
# Initialize Packer plugins
packer init tinyipa.pkr.hcl

# Validate configuration
packer validate tinyipa.pkr.hcl

# Build with custom variables
packer build -var 'arch=aarch64' -var 'require_biosdevname=true' tinyipa.pkr.hcl

# Build using variables file
packer build -var-file=tinyipa.pkrvars.hcl tinyipa.pkr.hcl
```

## Configuration Variables

### Packer Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `arch` | string | (auto-detected) | Target architecture (x86_64, aarch64) |
| `output_dir` | string | "output" | Directory for build artifacts |
| `branch_path` | string | "" | Branch extension for filenames |
| `require_biosdevname` | bool | false | Include biosdevname support |
| `require_ipmitool` | bool | true | Include ipmitool support |
| `base_image` | string | "ubuntu:24.04" | Base Docker image |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `ARCH` | Target architecture |
| `BRANCH_PATH` | Branch extension for filenames |
| `TINYIPA_REQUIRE_BIOSDEVNAME` | Include biosdevname (true/false) |
| `TINYIPA_REQUIRE_IPMITOOL` | Include ipmitool (true/false) |
| `PACKER_LOG` | Enable Packer logging (1 for debug) |
| `PACKER_LOG_LEVEL` | Packer log level (TRACE, DEBUG, INFO, WARN, ERROR) |

## Output Artifacts

Successful builds produce:

- **tinyipa-{arch}.gz**: Root filesystem (ramdisk)
- **tinyipa-{arch}.vmlinuz**: Linux kernel
- **tinyipa-{arch}.tar.gz**: Combined package
- **tinyipa-{arch}.iso**: Bootable ISO (x86_64 only)
- **tinyipa-{arch}.*.sha256**: Checksums for verification
- **build-manifest.txt**: Build information and file listing

## Build Process

The Packer build follows these stages:

1. **Base Setup**: Install system dependencies and tools
2. **User Creation**: Create non-root builder user with sudo access
3. **Source Preparation**: Clone ironic-python-agent and copy TinyIPA source
4. **Dependency Installation**: Run install-deps.sh script
5. **Build Execution**: Run make targets in sequence:
   - `make build`: Build the TinyIPA image
   - `make finalise`: Finalize the image
   - `make iso`: Create bootable ISO (x86_64 only)
   - `make instance-images`: Create instance images
6. **Artifact Collection**: Extract and organize output files
7. **Verification**: Generate checksums and build manifest

## Troubleshooting

### Common Issues

1. **Packer Not Found**

   ```bash
   # Install Packer
   brew install packer  # macOS
   # Or download from https://www.packer.io/downloads
   ```

2. **Docker Permission Denied**

   ```bash
   sudo usermod -aG docker $USER
   # Log out and log back in
   ```

3. **Architecture Detection Issues**

   ```bash
   # Explicitly set architecture
   ./packer-build.sh --arch aarch64
   ```

4. **Build Failures**

   ```bash
   # Enable verbose logging
   ./packer-build.sh --verbose
   
   # Check build logs
   ls -la output/*.log
   ```

5. **Tar Archive Errors (Can't add file to tar)**

   If you see errors like:

   ```text
   level=error msg="Can't add file /path/to/file to tar: archive/tar: missed writing X bytes"
   ```

   This is usually caused by:
   - Build artifacts in `tinyipabuild/` directory (should be ignored)
   - Symbolic links or special files causing tar issues
   - File permission problems

   **Solution:**

   ```bash
   # Clean build artifacts first
   make clean
   
   # Ensure .packerignore is working
   cat .packerignore
   
   # Run with clean workspace
   ./packer-build.sh --clean
   ```

6. **Loop Device Errors (cannot find an unused loop device)**

   If you see errors like:

   ```text
   losetup: cannot find an unused loop device: No such file or directory
   ```

   This indicates the Docker container needs privileged access to create loop devices for mounting disk images.

   **Solution:**

   The Packer configuration includes:
   - `privileged = true` - Grants container privileged access
   - `/dev` volume mount - Provides access to host devices
   - `SYS_ADMIN` and `MKNOD` capabilities - Allows device creation
   - Automatic loop device creation in provisioner

   If issues persist, ensure Docker daemon has proper permissions:

   ```bash
   # Check Docker daemon is running with appropriate privileges
   docker info | grep -i security
   
   # Test loop device access
   docker run --privileged --rm ubuntu:24.04 losetup -f
   ```

### Debug Mode

```bash
# Enable maximum Packer logging
export PACKER_LOG=1
export PACKER_LOG_LEVEL=TRACE
./packer-build.sh --verbose
```

### Manual Debugging

```bash
# Run Packer build step by step
packer build -debug tinyipa.pkr.hcl

# Or use Docker directly for debugging
docker run -it --rm ubuntu:24.04 /bin/bash
```

## Performance Tips

1. **Use Local Docker Registry**: Cache base images locally
2. **Parallel Builds**: Use `--parallel` for multi-architecture builds
3. **SSD Storage**: Use fast storage for Docker and output directories
4. **Resource Allocation**: Ensure adequate RAM and CPU for Docker

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: Build TinyIPA with Packer

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [x86_64, aarch64]
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Packer
        uses: hashicorp/setup-packer@main
        
      - name: Build TinyIPA
        run: ./packer-build.sh --arch ${{ matrix.arch }}
        
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: tinyipa-${{ matrix.arch }}
          path: output/
```

### Jenkins Pipeline Example

```groovy
pipeline {
    agent any
    
    stages {
        stage('Build TinyIPA') {
            parallel {
                stage('x86_64') {
                    steps {
                        sh './packer-build.sh --arch x86_64'
                    }
                }
                stage('aarch64') {
                    steps {
                        sh './packer-build.sh --arch aarch64'
                    }
                }
            }
        }
    }
    
    post {
        always {
            archiveArtifacts artifacts: 'output/**', fingerprint: true
        }
    }
}
```

## Comparison with Docker Build

| Feature | Packer Build | Docker Build |
|---------|--------------|--------------|
| **Reproducibility** | ✅ Excellent | ✅ Good |
| **Artifact Management** | ✅ Built-in | ⚠️ Manual |
| **Multi-platform** | ✅ Native | ✅ Via buildx |
| **CI/CD Integration** | ✅ Excellent | ✅ Good |
| **Learning Curve** | ⚠️ Medium | ✅ Low |
| **Debugging** | ⚠️ Medium | ✅ Easy |
| **Build Speed** | ⚠️ Medium | ✅ Fast |

## Advanced Usage

### Custom Base Images

```bash
# Use custom base image
packer build -var 'base_image=my-custom-ubuntu:latest' tinyipa.pkr.hcl
```

### Multiple Builds

```bash
# Build multiple variants
for biosdevname in true false; do
  ./packer-build.sh -var "require_biosdevname=$biosdevname" --output "output-biosdevname-$biosdevname"
done
```

### Custom Variables File

Create `custom.pkrvars.hcl`:

```hcl
arch = "aarch64"
require_biosdevname = true
require_ipmitool = true
branch_path = "custom-build"
output_dir = "custom-output"
```

Then build:

```bash
packer build -var-file=custom.pkrvars.hcl tinyipa.pkr.hcl
```
