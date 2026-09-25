#!/bin/bash

SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="86da14d0306a138fd3f01319860b905169746516"

SCRIPT_REPO2="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT2="eddcea9e27f6b772057c9b3f87de2cc1737faffc"

SCRIPT_REPO3="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT3="ced4f8eba3ba5dd431932cba17928f0dffdaeb2b"
SCRIPT_BRANCH3="sdk/13.0"

SCRIPT_REPO4="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT4="833faee5f7b8d3f56444347c587f4aed11ee213f"
SCRIPT_BRANCH4="sdk/11.1"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    echo "git-mini-clone \"$SCRIPT_REPO2\" \"$SCRIPT_COMMIT2\" ffnvcodec"
    echo "git-mini-clone \"$SCRIPT_REPO3\" \"$SCRIPT_COMMIT3\" ffnvcodec2"
    echo "git-mini-clone \"$SCRIPT_REPO4\" \"$SCRIPT_COMMIT4\" ffnvcodec3"
}

ffbuild_dockerbuild() {
    # Kill build of unused and broken tools
    echo > libvmaf/tools/meson.build

    sed -i -E 's/([^.>:_[:alnum:]])swap\(/\1libsvm_swap(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])min\(/\1libsvm_min(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])max\(/\1libsvm_max(/g' libvmaf/src/svm.cpp

	local nvdir=ffnvcodec
    if (( FFVER < 800 )); then
        nvdir=ffnvcodec3
    elif (( FFVER <= 801 )); then
        nvdir=ffnvcodec2
    fi
    make -C "$nvdir" PREFIX="$FFBUILD_PREFIX" install

	
    # CUDA 13.0
    curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    rm -f cuda-keyring_1.1-1_all.deb

    apt-get update
    apt-get install -y --no-install-recommends cuda-toolkit-13-0
	apt-get install -y lsb-release

    # LLVM 22
    curl -fsSL https://apt.llvm.org/llvm.sh | bash -s -- 22
    # clang wrapper used by libvmaf's Meson CUDA path
    rm -f /usr/bin/clang /usr/bin/clang++

    printf '#!/bin/sh\nexec /usr/lib/llvm-22/bin/clang --cuda-path=/usr/local/cuda-13.0 "$@"\n' \
        > /usr/bin/clang
    chmod +x /usr/bin/clang

    printf '#!/bin/sh\nexec /usr/lib/llvm-22/bin/clang++ --cuda-path=/usr/local/cuda-13.0 "$@"\n' \
        > /usr/bin/clang++
    chmod +x /usr/bin/clang++

    export PATH="/usr/local/cuda-13.0/bin:$PATH"

    clang --version | head -2
    clang++ --version | head -2
    ls -ld /usr/local/cuda*
    command -v ptxas
    command -v nvcc
    ls /usr/local/cuda-13.0/nvvm/libdevice
    ls -l /usr/bin/clang /usr/bin/clang++
    mkdir build && cd build

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --buildtype=release
        --default-library=static
        -Dbuilt_in_models=true
        -Denable_tests=false
        -Denable_docs=false
        -Denable_float=true
		-Denable_cuda=true
		-Denable_nvcc=false
    )

    if [[ $TARGET == *32 ]]; then
        myconf+=(
            -Denable_avx512=false
            -Denable_asm=false
        )
    else
        myconf+=(
            -Denable_avx512=true
            -Denable_asm=true
        )
    fi

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(
            --cross-file=/cross.meson
        )
    else
        echo "Unknown target"
        return -1
    fi

	clang --version | head -2; ls -d /usr/local/cuda* ; command -v ptxas nvcc; ls /usr/local/cuda-13.0/nvvm/libdevice; ls -l /usr/bin/clang
    meson "${myconf[@]}" ../libvmaf || cat meson-logs/meson-log.txt
    ninja -j"$(nproc)"
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libvmaf.pc
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
