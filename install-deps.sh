#!/bin/bash

COMMON_PACKAGES="wget unzip gawk"
APT_PACKAGES="${COMMON_PACKAGES} python3-pip squashfs-tools"
YUM_PACKAGES="${APT_PACKAGES}"
ZYPPER_PACKAGES="${COMMON_PACKAGES} python3-pip squashfs"
BREW_PACKAGES="wget unzip gawk python3 squashfs"

echo "Installing dependencies:"

# first zypper in case zypper-aptitude is installed
if [[ -x "/usr/bin/zypper" ]]; then
    zypper -n install -l "${ZYPPER_PACKAGES}"
elif [[ -x "/usr/bin/apt" ]]; then
    apt update
    apt install -y "${APT_PACKAGES}"
elif [[ -x "/usr/bin/dnf" ]]; then
    dnf install -y "${YUM_PACKAGES}"
elif [[ -x "/usr/bin/yum" ]]; then
    yum install -y "${YUM_PACKAGES}"
elif [[ -x "/usr/local/bin/brew" ]] || [[ -x "/opt/homebrew/bin/brew" ]]; then
    brew install "${BREW_PACKAGES}"
else
    echo "No supported package manager installed on system. Supported: apt, yum, dnf, zypper"
    exit 1
fi
