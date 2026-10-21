#!/bin/bash

SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="86da14d0306a138fd3f01319860b905169746516"

SCRIPT_REPO2="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT2="eddcea9e27f6b772057c9b3f87de2cc1737faffc"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    echo "git-mini-clone \"$SCRIPT_REPO2\" \"$SCRIPT_COMMIT2\" ffnvcodec"
}

ffbuild_dockerbuild() {
    # Kill build of unused and broken tools
    echo > libvmaf/tools/meson.build

    sed -i -E 's/([^.>:_[:alnum:]])swap\(/\1libsvm_swap(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])min\(/\1libsvm_min(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])max\(/\1libsvm_max(/g' libvmaf/src/svm.cpp

    #local cuda=0
    #if[[ $TARGET == linux64 ]]; then
    #    cuda=1
    #fi
    local cuda=1

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --buildtype=release
        --default-library=static
        -Dbuilt_in_models=true
        -Denable_tests=false
        -Denable_docs=false
        -Denable_float=true
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

    if (( cuda )); then
        # nv-codec-headers: build-time only, ffmpeg gets its own from 50-ffnvcodec
        make -C ffnvcodec PREFIX="$FFBUILD_PREFIX" install
        export CPATH="$FFBUILD_PREFIX/include${CPATH:+:$CPATH}"

        curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i cuda-keyring_1.1-1_all.deb
        rm -f cuda-keyring_1.1-1_all.deb
        apt-get update
        apt-get install -y --no-install-recommends cuda-toolkit-13-0 gcc g++

        export PATH="/usr/local/cuda-13.0/bin:$PATH"
        # nvcc only needs a plain system host compiler (it emits device-only fatbins)
        export NVCC_PREPEND_FLAGS="-ccbin /usr/bin/g++"

        # meson's cuda language needs a host-machine entry in cross builds
        grep -q '^cuda' /cross.meson || sed -i "/^\[binaries\]/a cuda = '/usr/local/cuda-13.0/bin/nvcc'" /cross.meson

        nvcc --version | tail -2
        command -v bin2c

        myconf+=(
            -Denable_cuda=true
            -Denable_nvcc=true
        )
    fi

    # build dir must live inside libvmaf/: meson.build passes literal ../src style -I paths to the kernel compile
    cd libvmaf
    mkdir build && cd build

    meson "${myconf[@]}" .. || cat meson-logs/meson-log.txt
    ninja -j"$(nproc)"
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    local pc="$FFBUILD_DESTPREFIX/lib/pkgconfig/libvmaf.pc"
    if (( cuda )); then
        sed -i 's/Libs.private:/Libs.private: -lstdc++ -ldl/; t; $ a Libs.private: -lstdc++ -ldl' "$pc"
        # aom's cmake only reads Libs:, not Libs.private
        sed -i '/^Libs:/ s/$/ -lstdc++ -ldl/' "$pc"
    else
        sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' "$pc"
    fi
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
