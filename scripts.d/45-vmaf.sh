#!/bin/bash

SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="86da14d0306a138fd3f01319860b905169746516"

SCRIPT_REPO2="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT2="eddcea9e27f6b772057c9b3f87de2cc1737faffc"

CUDA_VERSION="13.2"
CUDA_PATH="/usr/local/cuda-${CUDA_VERSION}"

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

    # Work around symbol collisions with libsvm's global functions
    sed -i -E 's/([^.>:_[:alnum:]])swap\(/\1libsvm_swap(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])min\(/\1libsvm_min(/g' libvmaf/src/svm.cpp
    sed -i -E 's/([^.>:_[:alnum:]])max\(/\1libsvm_max(/g' libvmaf/src/svm.cpp

    # Enable CUDA for the VMAF build
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
        return 1
    fi

    if (( cuda )); then
        # nv-codec-headers: build-time only.
        # FFmpeg gets its own headers from 50-ffnvcodec.
        make -C ffnvcodec PREFIX="$FFBUILD_PREFIX" install || return 1

        export CPATH="$FFBUILD_PREFIX/include${CPATH:+:$CPATH}"

        # Install the NVIDIA CUDA repository keyring.
        curl -fsSLO \
            https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
            || return 1

        dpkg -i cuda-keyring_1.1-1_all.deb || return 1
        rm -f cuda-keyring_1.1-1_all.deb

        apt-get update || return 1

        # CUDA 13.2 fixes the rsqrt/rsqrtf declaration conflict
        # encountered with CUDA 13.0 and newer glibc headers.
        apt-get install -y --no-install-recommends \
            cuda-toolkit-13-2 \
            gcc \
            g++ \
            || return 1

        export PATH="${CUDA_PATH}/bin:$PATH"

        # Use the system C++ compiler as NVCC's host compiler.
        export NVCC_PREPEND_FLAGS="-ccbin /usr/bin/g++"

        # Configure Meson to use the intended NVCC executable.
        # Replace an existing CUDA entry as well, so an old
        # CUDA 13.0 path cannot remain in /cross.meson.
        if grep -q '^cuda[[:space:]]*=' /cross.meson; then
            sed -i -E \
                "s|^cuda[[:space:]]*=.*$|cuda = '${CUDA_PATH}/bin/nvcc'|" \
                /cross.meson
        else
            sed -i \
                "/^\[binaries\]/a cuda = '${CUDA_PATH}/bin/nvcc'" \
                /cross.meson
        fi

        # Diagnostics: fail if the expected compiler is unavailable.
        "${CUDA_PATH}/bin/nvcc" --version || return 1
        command -v bin2c || return 1

        myconf+=(
            -Denable_cuda=true
            -Denable_nvcc=true
        )
    fi

    # The build directory must live inside libvmaf/.
    # meson.build uses relative ../src include paths for CUDA.
    cd libvmaf || return 1

    mkdir build || return 1
    cd build || return 1

    # IMPORTANT:
    # LDFLAGS is applied to all languages by Meson, including CUDA.
    # The BtbN linker flags include GCC/linker-driver options such
    # as -static-libgcc and -Wl,..., which NVCC rejects when passed
    # directly.
    #
    # Temporarily remove inherited LDFLAGS for Meson's configuration
    # and build. This avoids passing those flags to NVCC, but also
    # means Meson will not inherit them for C/C++ linking.
    #
    # VMAF is built as a static library with tests and tools disabled.
    # FFmpeg's final link is configured in its own build stage.
    #
    # If the offending flags are explicitly configured in
    # /cross.meson rather than inherited from LDFLAGS, that file
    # will need a separate correction.
    if ! env -u LDFLAGS meson "${myconf[@]}" ..; then
        echo "ERROR: Meson configuration failed."
        echo "---- Meson log ----"
        cat meson-logs/meson-log.txt
        return 1
    fi

    # Do not run Ninja if Meson configuration failed.
    ninja -j"$(nproc)" || return 1

    DESTDIR="$FFBUILD_DESTDIR" ninja install || return 1

    local pc="$FFBUILD_DESTPREFIX/lib/pkgconfig/libvmaf.pc"

    if (( cuda )); then
        # Ensure static consumers receive the required C++ runtime
        # and dynamic-loader libraries.
        sed -i \
            's/Libs.private:/Libs.private: -lstdc++ -ldl/; t; $ a Libs.private: -lstdc++ -ldl' \
            "$pc"

        # AOM's CMake configuration reads Libs:, not Libs.private.
        sed -i '/^Libs:/ s/$/ -lstdc++ -ldl/' "$pc"
    else
        sed -i \
            's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' \
            "$pc"
    fi
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
