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
    # Kill build of unused and broken tools.
    echo > libvmaf/tools/meson.build

    # Work around symbol collisions with libsvm's global functions.
    sed -i -E 's/([^.>:_[:alnum:]])swap\(/\1libsvm_swap(/g' libvmaf/src/svm.cpp || return 1
    sed -i -E 's/([^.>:_[:alnum:]])min\(/\1libsvm_min(/g' libvmaf/src/svm.cpp || return 1
    sed -i -E 's/([^.>:_[:alnum:]])max\(/\1libsvm_max(/g' libvmaf/src/svm.cpp || return 1

    # Enable CUDA for this build. Set to 0 to build libvmaf without CUDA.
    local cuda=1

    # Windows cross-build: NVCC and bin2c are build-machine tools.
    # This VMAF revision uses NVCC to emit device fatbins, then bin2c
    # converts them to C arrays which MinGW compiles for Windows.
    # Do not let Meson test NVCC as a Windows-target compiler through Wine.
    if (( cuda )) && [[ $TARGET == win* ]]; then
        sed -i \
            -e "s/add_languages('cuda', required : true)/add_languages('cuda', required : true, native : true)/" \
            -e "s/meson.get_compiler('cuda')/meson.get_compiler('cuda', native : true)/" \
            -e "s/find_program('nvcc')/find_program('nvcc', native : true)/" \
            -e "s/find_program('bin2c')/find_program('bin2c', native : true)/" \
            libvmaf/src/meson.build || return 1

        # Fail clearly if the pinned source no longer matches the patch.
        grep -Fq "add_languages('cuda', required : true, native : true)" libvmaf/src/meson.build || {
            echo "ERROR: Failed to patch VMAF's CUDA language declaration for a Windows cross-build."
            return 1
        }
        grep -Fq "meson.get_compiler('cuda', native : true)" libvmaf/src/meson.build || {
            echo "ERROR: Failed to patch VMAF's CUDA compiler lookup for a Windows cross-build."
            return 1
        }
        grep -Fq "find_program('nvcc', native : true)" libvmaf/src/meson.build || {
            echo "ERROR: Failed to patch VMAF's NVCC lookup for a Windows cross-build."
            return 1
        }
        grep -Fq "find_program('bin2c', native : true)" libvmaf/src/meson.build || {
            echo "ERROR: Failed to patch VMAF's bin2c lookup for a Windows cross-build."
            return 1
        }
    fi

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
        myconf+=(--cross-file=/cross.meson)
    else
        echo "Unknown target: $TARGET"
        return 1
    fi

    if (( cuda )); then
        # nv-codec-headers are needed at build time for VMAF's CUDA headers.
        # FFmpeg gets its own headers from 50-ffnvcodec.
        make -C ffnvcodec PREFIX="$FFBUILD_PREFIX" install || return 1
        export CPATH="$FFBUILD_PREFIX/include${CPATH:+:$CPATH}"

        # Install NVIDIA's CUDA repository keyring.
        curl -fsSLO \
            https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
            || return 1

        dpkg -i cuda-keyring_1.1-1_all.deb || return 1
        rm -f cuda-keyring_1.1-1_all.deb

        apt-get update || return 1
        # CUDA 13.2 avoids the rsqrt/rsqrtf declaration conflict seen with
        # CUDA 13.0 and newer glibc headers.
        apt-get install -y --no-install-recommends \
            cuda-toolkit-13-2 \
            gcc \
            g++ \
            || return 1

        export PATH="${CUDA_PATH}/bin:$PATH"

        # NVCC is only generating device fatbins here; use the system compiler.
        export NVCC_PREPEND_FLAGS="-ccbin /usr/bin/g++"

        # For Linux targets, make Meson use this precise NVCC path from its
        # cross file. Do not add a Linux path as the Windows target compiler:
        # Windows' CUDA compile steps are explicitly native above.
        if [[ $TARGET == linux* ]]; then
            if grep -q '^cuda[[:space:]]*=' /cross.meson; then
                sed -i -E \
                    "s|^cuda[[:space:]]*=.*$|cuda = '${CUDA_PATH}/bin/nvcc'|" \
                    /cross.meson || return 1
            else
                sed -i \
                    "/^\[binaries\]/a cuda = '${CUDA_PATH}/bin/nvcc'" \
                    /cross.meson || return 1
            fi
        fi

        # Diagnostics: fail if the expected compiler/tools are unavailable.
        "${CUDA_PATH}/bin/nvcc" --version || return 1
        command -v bin2c || return 1

        myconf+=(
            -Denable_cuda=true
            -Denable_nvcc=true
        )
    fi

    # The build directory must live inside libvmaf/: meson.build uses
    # relative ../src include paths for the generated CUDA kernel commands.
    cd libvmaf || return 1
    mkdir build || return 1
    cd build || return 1

    # BtbN's LDFLAGS include GCC/linker-driver options such as -static-libgcc
    # and -Wl,...; NVCC rejects these when passed directly. Meson records the
    # environment's linker flags during setup, so unset LDFLAGS for setup.
    # This builds a static libvmaf; FFmpeg's final link is configured later.
    # If those flags are explicitly embedded in /cross.meson, that file must
    # be corrected separately because unsetting the environment won't remove them.
    if ! env -u LDFLAGS meson "${myconf[@]}" ..; then
        echo "ERROR: Meson configuration failed."
        echo "---- Meson log ----"
        cat meson-logs/meson-log.txt
        return 1
    fi

    ninja -j"$(nproc)" || return 1
    DESTDIR="$FFBUILD_DESTDIR" ninja install || return 1

    local pc="$FFBUILD_DESTPREFIX/lib/pkgconfig/libvmaf.pc"

    if [[ ! -f $pc ]]; then
        echo "ERROR: libvmaf.pc not found: $pc"
        return 1
    fi

    # Remove flags previously injected by this script.
    sed -i \
        -e '/^Libs:/ s/ -lstdc++//g' \
        -e '/^Libs:/ s/ -ldl//g' \
        -e '/^Libs\.private:/ s/ -lstdc++//g' \
        -e '/^Libs\.private:/ s/ -ldl//g' \
        "$pc" || return 1

    if (( cuda )); then
        local extra_libs="-lstdc++"

        # libdl is a Linux library; do not pass -ldl to MinGW.
        if [[ $TARGET == linux* ]]; then
            extra_libs+=" -ldl"
        fi

        if grep -q '^Libs.private:' "$pc"; then
            sed -i \
                "/^Libs\.private:/ s/$/ $extra_libs/" \
                "$pc" || return 1
        else
            printf '\nLibs.private: %s\n' "$extra_libs" \
                >> "$pc" || return 1
        fi

        if ! grep -q '^Libs:' "$pc"; then
            echo "ERROR: No Libs: entry found in $pc"
            return 1
        fi

        # AOM's CMake configuration consumes the public Libs: entry.
        sed -i "/^Libs:/ s/$/ $extra_libs/" "$pc" || return 1
    else
        if grep -q '^Libs.private:' "$pc"; then
            sed -i '/^Libs\.private:/ s/$/ -lstdc++/' "$pc" || return 1
        else
            printf '\nLibs.private: -lstdc++\n' \
                >> "$pc" || return 1
        fi
    fi

    echo "---- Final libvmaf.pc for TARGET=$TARGET ----"
    cat "$pc"

    # Catch this particular failure before the build reaches AOM.
    if [[ $TARGET == win* ]] && grep -n -- '-ldl' "$pc"; then
        echo "ERROR: Windows libvmaf.pc still contains -ldl"
        return 1
    fi
    
    if [[ ! -f $pc ]]; then
        echo "ERROR: Expected pkg-config file was not installed: $pc"
        return 1
    fi

    # Avoid duplicate/stale flags if this .pc file is reused by a cached stage.
    # -ldl is Linux-specific; it does not exist in the MinGW Windows toolchain.
    sed -i \
        -e '/^Libs:/ s/ -lstdc++//g' \
        -e '/^Libs:/ s/ -ldl//g' \
        -e '/^Libs\.private:/ s/ -lstdc++//g' \
        -e '/^Libs\.private:/ s/ -ldl//g' \
        "$pc" || return 1

    if (( cuda )); then
        local extra_libs="-lstdc++"
        if [[ $TARGET == linux* ]]; then
            extra_libs+=" -ldl"
        fi

        # Static VMAF's consumers need the C++ runtime. AOM's CMake build
        # reads Libs: rather than Libs.private:, so add these there too.
        if grep -q '^Libs.private:' "$pc"; then
            sed -i "/^Libs\.private:/ s/$/ $extra_libs/" "$pc" || return 1
        else
            printf '\nLibs.private: %s\n' "$extra_libs" >> "$pc" || return 1
        fi

        grep -q '^Libs:' "$pc" || {
            echo "ERROR: No Libs: entry found in $pc"
            return 1
        }
        sed -i "/^Libs:/ s/$/ $extra_libs/" "$pc" || return 1
    else
        if grep -q '^Libs.private:' "$pc"; then
            sed -i '/^Libs\.private:/ s/$/ -lstdc++/' "$pc" || return 1
        else
            printf '\nLibs.private: -lstdc++\n' >> "$pc" || return 1
        fi
    fi
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
