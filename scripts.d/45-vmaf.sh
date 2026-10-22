#!/bin/bash

# Mainline libvmaf: used for every target except win64.
SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="86da14d0306a138fd3f01319860b905169746516"

# nv-codec-headers (needed at build time for libvmaf's CUDA headers).
SCRIPT_REPO2="https://github.com/FFmpeg/nv-codec-headers.git"
SCRIPT_COMMIT2="eddcea9e27f6b772057c9b3f87de2cc1737faffc"

# win64 only: fork carrying PR #1472 (CUDA feature extraction on Windows).
# Upstream Netflix/vmaf does not build its NVCC path for Windows.
SCRIPT_REPO_WIN64="https://github.com/birkdev/vmaf.git"
SCRIPT_COMMIT_WIN64="3e2985668159549bcf24d26fc2bbce88711c720c"
SCRIPT_DIR_WIN64="vmaf-win64"

# Change all three together (apt package, install path, version).
CUDA_VERSION="13.4"
CUDA_APT_PKG="cuda-toolkit-13-4"
CUDA_PATH="/usr/local/cuda-${CUDA_VERSION}"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    echo "git-mini-clone \"$SCRIPT_REPO2\" \"$SCRIPT_COMMIT2\" ffnvcodec"
    # The dl stage runs with TARGET=dl, so the target can't be chosen here.
    # Fetch the PR #1472 tree too and select it in ffbuild_dockerbuild.
    echo "git-mini-clone \"$SCRIPT_REPO_WIN64\" \"$SCRIPT_COMMIT_WIN64\" $SCRIPT_DIR_WIN64"
}

# win64 (Linux -> Windows cross): patch PR #1472's libvmaf/src/meson.build.
#  1. Skip the PowerShell/MSVC discovery unless the BUILD machine is Windows
#     (Meson's host_machine is the TARGET, so it fires on Linux->Windows).
#  2. nvcc and bin2c are build-machine tools: find_program(..., native : true).
vmaf_patch_win64_meson() {
    python3 - <<'PY' || return 1
import re, sys
from pathlib import Path

path = Path("libvmaf/src/meson.build")
src = path.read_text()

def sub_once(pattern, repl, text, label):
    new, n = re.subn(pattern, repl, text, count=0)
    if n != 1:
        sys.exit(f"ERROR: expected exactly 1 match for {label}, found {n}")
    return new

if "build_machine.system() == 'windows'" not in src:
    src = sub_once(
        r"if host_machine\.system\(\) == 'windows'(\s*\n\s*cl_find_result\s*=\s*run_command\(\s*'powershell')",
        r"if host_machine.system() == 'windows' and build_machine.system() == 'windows'\1",
        src, "powershell guard")

if not re.search(r"find_program\(\s*'nvcc'\s*,\s*native\s*:\s*true", src):
    src = sub_once(r"(nvcc_exe\s*=\s*find_program\(\s*'nvcc')\s*\)",
                   r"\1, native : true)", src, "nvcc find_program")

if not re.search(r"find_program\(\s*'bin2c'\s*,\s*native\s*:\s*true", src):
    src = sub_once(r"(bin2c_exe\s*=\s*find_program\(\s*'bin2c')\s*\)",
                   r"\1, native : true)", src, "bin2c find_program")

path.write_text(src)
PY
    grep -Fq "build_machine.system() == 'windows'" libvmaf/src/meson.build || return 1
}

# winarm64 keeps the previous (working) mainline patches.
vmaf_patch_winother_meson() {
    sed -i \
        -e "s/add_languages('cuda', required : true)/add_languages('cuda', required : true, native : true)/" \
        -e "s/meson.get_compiler('cuda')/meson.get_compiler('cuda', native : true)/" \
        -e "s/find_program('nvcc')/find_program('nvcc', native : true)/" \
        -e "s/find_program('bin2c')/find_program('bin2c', native : true)/" \
        libvmaf/src/meson.build || return 1

    local p
    for p in \
        "add_languages('cuda', required : true, native : true)" \
        "meson.get_compiler('cuda', native : true)" \
        "find_program('nvcc', native : true)" \
        "find_program('bin2c', native : true)"; do
        grep -Fq "$p" libvmaf/src/meson.build || {
            echo "ERROR: Failed to patch VMAF's meson.build for Windows cross-build: $p"
            return 1
        }
    done
}

# Single idempotent libvmaf.pc fix.
# Static libvmaf contains C++ (svm.cpp). AOM's CMake and FFmpeg's configure read
# the public Libs: line, so the C++ runtime goes there and in Libs.private:.
# -ldl is Linux-only and must never reach a MinGW target.
vmaf_fix_pc() {
    local pc="$FFBUILD_DESTPREFIX/lib/pkgconfig/libvmaf.pc"
    [[ -f $pc ]] || { echo "ERROR: libvmaf.pc not found: $pc"; return 1; }

    sed -i \
        -e '/^Libs:/ s/ -lstdc++//g' -e '/^Libs:/ s/ -ldl//g' \
        -e '/^Libs\.private:/ s/ -lstdc++//g' -e '/^Libs\.private:/ s/ -ldl//g' \
        "$pc" || return 1

    local extra="-lstdc++"
    if (( $1 )) && [[ $TARGET == linux* ]]; then
        extra+=" -ldl"
    fi

    grep -q '^Libs:' "$pc" || { echo "ERROR: No Libs: entry in $pc"; return 1; }
    sed -i "/^Libs:/ s/\$/ $extra/" "$pc" || return 1

    if grep -q '^Libs.private:' "$pc"; then
        sed -i "/^Libs\.private:/ s/\$/ $extra/" "$pc" || return 1
    else
        printf '\nLibs.private: %s\n' "$extra" >> "$pc" || return 1
    fi

    echo "---- Final libvmaf.pc for TARGET=$TARGET ----"
    cat "$pc"

    if [[ $TARGET == win* ]] && grep -n -- '-ldl' "$pc"; then
        echo "ERROR: Windows libvmaf.pc still contains -ldl"
        return 1
    fi
}

ffbuild_dockerbuild() {
    # Enable CUDA for this build. Set to 0 to build libvmaf without CUDA.
    local cuda=1

    # win64 uses the PR #1472 tree; everything else uses mainline.
    local win64=0
    if [[ $TARGET == win64 ]]; then
        win64=1
        cd "$SCRIPT_DIR_WIN64" || return 1
    fi

    # Kill build of unused and broken tools.
    echo > libvmaf/tools/meson.build

    # Work around symbol collisions with libsvm's global functions.
    sed -i -E 's/([^.>:_[:alnum:]])swap\(/\1libsvm_swap(/g' libvmaf/src/svm.cpp || return 1
    sed -i -E 's/([^.>:_[:alnum:]])min\(/\1libsvm_min(/g' libvmaf/src/svm.cpp || return 1
    sed -i -E 's/([^.>:_[:alnum:]])max\(/\1libsvm_max(/g' libvmaf/src/svm.cpp || return 1

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
        myconf+=(-Denable_avx512=false -Denable_asm=false)
    else
        myconf+=(-Denable_avx512=true -Denable_asm=true)
    fi

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(--cross-file=/cross.meson)
    else
        echo "Unknown target: $TARGET"
        return 1
    fi

    if (( cuda )); then
        # nv-codec-headers: needed at build time for VMAF's CUDA headers.
        # The ffnvcodec dir sits in the default checkout, one level above
        # the vmaf-win64 tree.
        local ffnv="ffnvcodec"
        (( win64 )) && ffnv="../ffnvcodec"
        make -C "$ffnv" PREFIX="$FFBUILD_PREFIX" install || return 1
        export CPATH="$FFBUILD_PREFIX/include${CPATH:+:$CPATH}"

        # Pick NVIDIA's repo from the build container itself (Ubuntu release and
        # architecture), not from hardcoded values. Native arm64 containers use
        # the sbsa repo; "arm64" is the Jetson/Tegra repo and "cross-linux-*"
        # are x86 host -> aarch64 cross-compile packages, neither applies here.
        local cuda_distro cuda_arch
        cuda_distro="$(. /etc/os-release && [[ $ID == ubuntu ]] && echo "ubuntu${VERSION_ID//./}")"
        [[ -n $cuda_distro ]] || { echo "ERROR: build container is not Ubuntu"; return 1; }

        case "$(dpkg --print-architecture)" in
            amd64) cuda_arch="x86_64" ;;
            arm64) cuda_arch="sbsa" ;;
            *) echo "ERROR: no CUDA repo for $(dpkg --print-architecture)"; return 1 ;;
        esac

        local cuda_repo="https://developer.download.nvidia.com/compute/cuda/repos/${cuda_distro}/${cuda_arch}"
        echo "Using CUDA repo: $cuda_repo"
        curl -fsSLO "${cuda_repo}/cuda-keyring_1.1-1_all.deb" || {
            echo "ERROR: no CUDA repo/keyring at ${cuda_repo}"
            return 1
        }
        dpkg -i cuda-keyring_1.1-1_all.deb || return 1
        rm -f cuda-keyring_1.1-1_all.deb

        apt-get update || return 1
        apt-get install -y --no-install-recommends "$CUDA_APT_PKG" gcc g++ || return 1

        export PATH="${CUDA_PATH}/bin:$PATH"

        # NVCC only generates device fatbins; use the build machine's compiler,
        # never the MinGW cross compiler.
        export NVCC_PREPEND_FLAGS="-ccbin /usr/bin/g++"

        if (( win64 )); then
            # Windows x64: nvcc/bin2c are native tools found by find_program,
            # no cuda entry in the cross file, PowerShell/MSVC probe disabled.
            vmaf_patch_win64_meson || return 1
        elif [[ $TARGET == win* ]]; then
            vmaf_patch_winother_meson || return 1
        elif [[ $TARGET == linux* ]]; then
            # Pin Meson to this exact NVCC via the cross file.
            if grep -q '^cuda[[:space:]]*=' /cross.meson; then
                sed -i -E "s|^cuda[[:space:]]*=.*$|cuda = '${CUDA_PATH}/bin/nvcc'|" /cross.meson || return 1
            else
                sed -i "/^\[binaries\]/a cuda = '${CUDA_PATH}/bin/nvcc'" /cross.meson || return 1
            fi
        fi

        "${CUDA_PATH}/bin/nvcc" --version || return 1
        command -v bin2c || return 1

        myconf+=(-Denable_cuda=true -Denable_nvcc=true)
    fi

    # Build dir must live inside libvmaf/: the CUDA kernel rules use relative
    # ../src include paths.
    cd libvmaf || return 1
    mkdir build || return 1
    cd build || return 1

    # BtbN's LDFLAGS (-static-libgcc, -Wl,...) are rejected by NVCC; Meson
    # records env linker flags at setup, so unset them for setup only.
    if ! env -u LDFLAGS meson setup "${myconf[@]}" . ..; then
        echo "ERROR: Meson configuration failed."
        echo "---- Meson log ----"
        cat meson-logs/meson-log.txt
        return 1
    fi

    ninja -j"$(nproc)" || return 1
    DESTDIR="$FFBUILD_DESTDIR" ninja install || return 1

    vmaf_fix_pc "$cuda" || return 1

    if (( cuda )); then
        apt-get purge -y --autoremove "$CUDA_APT_PKG" || true
        rm -rf /usr/local/cuda* /var/lib/apt/lists/*
        apt-get clean
    fi
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
