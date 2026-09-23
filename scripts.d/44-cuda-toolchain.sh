#!/bin/bash

ffbuild_enabled() {
    return 0
}

ffbuild_dockerdl() {
    true
}

ffbuild_dockerbuild() {
    set -e
    curl -fsSL https://apt.llvm.org/llvm.sh | bash -s -- 22 && update-alternatives --install /usr/bin/clang clang "$(command -v clang-22)" 100 && update-alternatives --install /usr/bin/clang++ clang++ "$(command -v clang++-22)" 100
    curl -fsSL -o /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb && apt-get update && apt-get install -y --no-install-recommends cuda-toolkit-13.0
}
