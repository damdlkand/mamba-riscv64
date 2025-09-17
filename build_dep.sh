#!/bin/bash
set -eo pipefail # 如果任何命令失败，脚本将立即退出

# 定义安装的根目录和各个组件的安装路径
INSTALL_ROOT="/opt/conda_tools"
MICROMAMBA_INSTALL_DIR="${INSTALL_ROOT}/micromamba"
# CONDA_ENV_DIR 由 micromamba create 创建，并将在 build_conda.sh 中使用

# 创建安装目录
mkdir -p "${INSTALL_ROOT}"
mkdir -p "${MICROMAMBA_INSTALL_DIR}"

set -e # 如果命令以非零状态退出，则立即退出。
set -x # 执行时打印命令及其参数。

DEPS_PREFIX="/opt/conda_static_deps"
mkdir -p "${DEPS_PREFIX}/lib" "${DEPS_PREFIX}/lib64" "${DEPS_PREFIX}/include" "${DEPS_PREFIX}/bin"

# 设置环境变量，以便后续编译步骤能找到这些依赖
export PATH="${DEPS_PREFIX}/bin:${PATH}"
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/lib64/pkgconfig:${DEPS_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"
export CPPFLAGS="-I${DEPS_PREFIX}/include ${CPPFLAGS}"
export CFLAGS="-fPIC -mcmodel=medany ${CFLAGS}"
export CXXFLAGS="-fPIC -mcmodel=medany ${CXXFLAGS}"
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${DEPS_PREFIX}/lib64 ${LDFLAGS}"
# 对于 CMake 项目，设置 CMAKE_PREFIX_PATH 很有帮助
export CMAKE_PREFIX_PATH="${DEPS_PREFIX}:${CMAKE_PREFIX_PATH}"

download_with_retry() {
  local url="$1"
  local output_file="$2"
  local max_attempts=5
  local attempt_num=1
  local sleep_duration=30 # 根据之前的修改，保持增加的等待时间
  local cmd_exit_code

  while [ $attempt_num -le $max_attempts ]; do
    echo "Attempting to download (attempt ${attempt_num}/${max_attempts}): ${url} to ${output_file}"

    # Execute wget within the if condition to prevent set -e from exiting prematurely
    # Wget already has its own retry mechanism (--tries=5). This function adds another layer.
    if wget --tries=5 --timeout=120 --waitretry=10 "${url}" -O "${output_file}"; then
      echo "Download successful: ${output_file}"
      return 0
    else
      cmd_exit_code=$? # Capture wget's exit code after it failed
      echo "Download attempt ${attempt_num} failed for ${url} with exit code ${cmd_exit_code}."
      # Clean up potentially partial file before next attempt or exit
      rm -f "${output_file}"
      if [ $attempt_num -lt $max_attempts ]; then
        echo "Waiting ${sleep_duration} seconds before next attempt..."
        sleep "${sleep_duration}"
      fi
    fi
    attempt_num=$((attempt_num + 1))
  done

  echo "Failed to download ${url} after ${max_attempts} attempts."
  exit 1 # 如果所有尝试都失败则退出脚本
}

git_clone_with_retry() {
  local repo_url="$1"
  local target_dir_param="$2" # 可选的目标目录参数
  local max_attempts=3
  local attempt_num=1
  local sleep_duration=30
  local clone_target # 实际用于 clone 命令的目标
  local cmd_exit_code

  if [ -n "$target_dir_param" ]; then
    clone_target="$target_dir_param"
  else
    # 从 URL 推断目录名 (例如 https://github.com/foo/bar.git -> bar)
    clone_target=$(basename "${repo_url}" .git)
  fi

  while [ $attempt_num -le $max_attempts ]; do
    echo "Attempting to clone (attempt ${attempt_num}/${max_attempts}): ${repo_url} into ${clone_target}"
    
    # 如果目标目录已存在且非空（可能来自失败的尝试），先删除
    if [ -d "$clone_target" ]; then
        echo "Target directory ${clone_target} exists. Removing before attempting clone."
        rm -rf "$clone_target"
    fi

    if [ -n "$target_dir_param" ]; then
      git clone --depth 1 "${repo_url}" "${target_dir_param}"
      cmd_exit_code=$? # 捕获 git clone 的退出码
    else
      git clone --depth 1 "${repo_url}"
      cmd_exit_code=$? # 捕获 git clone 的退出码
    fi

    if [ $cmd_exit_code -eq 0 ]; then
      echo "Git clone successful: ${repo_url}"
      return 0
    else
      echo "Git clone attempt ${attempt_num} failed for ${repo_url} with exit code ${cmd_exit_code}."
      # 确保在重试前清理可能存在的失败克隆目录
      if [ -d "$clone_target" ]; then # 再次检查以防万一
        echo "Removing partially cloned directory: ${clone_target}"
        rm -rf "$clone_target"
      fi
      if [ $attempt_num -lt $max_attempts ]; then
        echo "Waiting ${sleep_duration} seconds before next attempt..."
        sleep "${sleep_duration}"
      fi
    fi
    attempt_num=$((attempt_num + 1))
  done

  echo "Failed to clone ${repo_url} after ${max_attempts} attempts."
  exit 1
}

# 用于下载和构建的临时目录
BUILD_DIR="/tmp/build_deps_$(date +%s)" # 添加时间戳以避免潜在冲突
mkdir -p "${BUILD_DIR}"
ORIG_DIR=$(pwd) # 保存原始工作目录
cd "${BUILD_DIR}"

echo "=== 开始编译和安装 Micromamba 的静态依赖库 (安装到 ${DEPS_PREFIX}) ==="

#26. fmt

#cp -r /opt/builder/fmt ./fmt
download_with_retry https://github.com/fmtlib/fmt/archive/refs/tags/9.1.0.tar.gz fmt.tar.gz
(
tar xf fmt.tar.gz&& rm -f fmt.tar.gz
cd fmt-9.1.0&&
mkdir build && cd build &&

cmake .. -DCMAKE_INSTALL_PREFIX=/opt/conda_static_deps -DBUILD_SHARED_LIBS=OFF -DFMT_TEST=OFF&&
make -j$(nproc)&&
make install
)
rm -rf fmt-9.1.0

#27. spdlog
#cp -r /opt/builder/spdlog ./spdlog
download_with_retry https://github.com/gabime/spdlog/archive/refs/tags/v1.13.0.tar.gz spdlog.tar.gz
(
tar xf spdlog.tar.gz && rm -f spdlog.tar.gz
cd spdlog-1.13.0&&
mkdir -p build &&
cd build &&
    cmake .. \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DSPDLOG_BUILD_SHARED=OFF \
      -DSPDLOG_BUILD_STATIC=ON \
      -DSPDLOG_BUILD_TESTS=OFF && 
 make -j$(nproc) &&
 make install
)
rm -rf spdlog-1.13.0
# 清理构建目录并返回原始目录
cd "${ORIG_DIR}"
rm -rf "${BUILD_DIR}"

# 1. zlib
echo "正在安装 zlib..."
download_with_retry https://zlib.net/zlib-1.3.1.tar.gz zlib.tar.gz
#cp /opt/builder/zlib.tar.gz ./
tar -xzf zlib.tar.gz
(cd zlib-1.3.1 && ./configure --prefix="${DEPS_PREFIX}" --static && make -j$(nproc) && make install)
rm -rf zlib-1.3.1 zlib.tar.gz

# 2. OpenSSL
echo "正在安装 OpenSSL..."
download_with_retry https://www.openssl.org/source/openssl-3.5.0.tar.gz openssl.tar.gz
#download_with_retry https://mirrors.cloud.tencent.com/openssl/source/openssl-3.5.0.tar.gz openssl.tar.gz
#cp /opt/builder/openssl.tar.gz  ./
tar -xzf openssl.tar.gz
(cd openssl-3.5.0 && ./config --prefix="${DEPS_PREFIX}" --openssldir="${DEPS_PREFIX}/ssl" zlib && make -j$(nproc) && make install)
rm -rf openssl-3.5.0 openssl.tar.gz

# 3. libunistring (libidn2 的依赖)
echo "正在安装 libunistring..."
download_with_retry https://ftp.gnu.org/gnu/libunistring/libunistring-1.2.tar.gz libunistring.tar.gz
#cp /opt/builder/libunistring.tar.gz ./
tar -xzf libunistring.tar.gz
(cd libunistring-1.2 && ./configure --prefix="${DEPS_PREFIX}" --enable-shared && make -j$(nproc) && make install)
rm -rf libunistring-1.2 libunistring.tar.gz

# 4. libidn2 (依赖 libunistring)
echo "正在安装 libidn2..."
download_with_retry https://ftp.gnu.org/gnu/libidn/libidn2-2.3.7.tar.gz libidn2.tar.gz
tar -xzf libidn2.tar.gz
(cd libidn2-2.3.7 && ./configure --prefix="${DEPS_PREFIX}" --enable-shared --with-libunistring-prefix="${DEPS_PREFIX}" && make -j$(nproc) && make install)
rm -rf libidn2-2.3.7 libidn2.tar.gz

# 5. libxml2 (依赖 zlib)
echo "正在安装 libxml2..."
download_with_retry https://download.gnome.org/sources/libxml2/2.12/libxml2-2.12.6.tar.xz libxml2.tar.xz
tar -xf libxml2.tar.xz
(cd libxml2-2.12.6 && ./configure --prefix="${DEPS_PREFIX}" --enable-static --without-python --with-zlib="${DEPS_PREFIX}" && make -j$(nproc) && make install)
rm -rf libxml2-2.12.6 libxml2.tar.xz

# 6. brotli
echo "正在安装 brotli..."
download_with_retry https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz brotli-v1.1.0.tar.gz
tar -xzf brotli-v1.1.0.tar.gz
(cd brotli-1.1.0 && mkdir build && cd build && cmake .. \
  -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
  -DCMAKE_INSTALL_LIBDIR="lib" \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON &&
  make -j$(nproc) && make install)
rm -rf brotli-1.1.0 brotli-v1.1.0.tar.gz

ls -l "${DEPS_PREFIX}/lib" "${DEPS_PREFIX}/lib64"
echo "============Brotli 编译安装完成============"

# 7. libpsl (依赖 libidn2)
echo "正在安装 libpsl..."
download_with_retry https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz libpsl.tar.gz
tar -xzf libpsl.tar.gz
(cd libpsl-0.21.5 && ./configure --prefix="${DEPS_PREFIX}" --enable-shared --with-libidn2-prefix="${DEPS_PREFIX}" && make -j$(nproc) && make install)
rm -rf libpsl-0.21.5 libpsl.tar.gz

# 8. cURL (libcurl) (依赖 OpenSSL, zlib, brotli, libidn2, libpsl)
echo "正在安装 cURL (libcurl)..."
download_with_retry https://curl.se/download/curl-8.13.0.tar.gz curl.tar.gz
tar -xzf curl.tar.gz
(
  cd curl-8.13.0 &&
    env CPPFLAGS="${CPPFLAGS}" \
      LDFLAGS="${LDFLAGS}" \
      LIBS="-lpsl -lidn2 -lunistring -lssl -lcrypto -lbrotlienc -lbrotlidec -lbrotlicommon -lz -ldl -lpthread" \
      ./configure --prefix="${DEPS_PREFIX}" \
      --disable-shared \
      --enable-static \
      --with-openssl="${DEPS_PREFIX}" \
      --with-zlib="${DEPS_PREFIX}" \
      --with-brotli="${DEPS_PREFIX}" \
      --with-libidn2="${DEPS_PREFIX}" \
      --with-libpsl="${DEPS_PREFIX}" \
      --without-nghttp2 \
      --without-ngtcp2 \
      --without-nghttp3 &&
    make -j$(nproc) &&
    make install
)
rm -rf curl-8.13.0 curl.tar.gz

# 9. libsolv (依赖 zlib, libxml2 - 后者是可选的，但通常启用)
echo "正在安装 libsolv..."
download_with_retry https://github.com/openSUSE/libsolv/archive/refs/tags/0.7.32.tar.gz libsolv-0.7.32.tar.gz
tar -xzf libsolv-0.7.32.tar.gz
(cd libsolv-0.7.32 && mkdir build && cd build && cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
  -DENABLE_CONDA=ON \
  -DENABLE_STATIC=ON \
  -DDISABLE_SHARED=OFF \
  -DWITH_LIBXML2="${DEPS_PREFIX}" \
  -DCMAKE_BUILD_TYPE=Release &&
  make -j$(nproc) && make install)
rm -rf libsolv-0.7.32 libsolv-0.7.32.tar.gz

# 10. libarchive (依赖 zlib, OpenSSL, libxml2, brotli 等)
echo "正在安装 libarchive..."
download_with_retry https://www.libarchive.org/downloads/libarchive-3.7.2.tar.gz libarchive.tar.gz
tar -xzf libarchive.tar.gz
(cd libarchive-3.7.2 && ./configure --prefix="${DEPS_PREFIX}" \
  --disable-shared \
  --without-bz2lib \
  --without-lzma \
  --without-lzo2 \
  --without-lz4 \
  --without-zstd \
  --with-openssl="${DEPS_PREFIX}" \
  --with-libxml2="${DEPS_PREFIX}" \
  --with-brotli="${DEPS_PREFIX}" \
  --with-zlib="${DEPS_PREFIX}" \
  --disable-bsdtar \
  --disable-bsdcpio \
  --disable-bsdcat &&
  make -j$(nproc) && make install)
rm -rf libarchive-3.7.2 libarchive.tar.gz

# 11. tl-expected
echo "正在安装 tl-expected..."
download_with_retry https://github.com/TartanLlama/expected/archive/refs/tags/v1.1.0.tar.gz tl-expected-v1.1.0.tar.gz
tar -xzf tl-expected-v1.1.0.tar.gz
(cd expected-1.1.0 && mkdir build && cd build && cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON && make -j$(nproc) && make install)
rm -rf expected-1.1.0 tl-expected-v1.1.0.tar.gz

# 12. reproc reproc-cpp
echo "正在安装 reproc reproc-cpp..."
git_clone_with_retry https://github.com/DaanDeMeyer/reproc.git
#cp -r /opt/builder/reproc ./reproc
(
  cd reproc &&
    mkdir build &&
    cd build &&
    cmake -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release -DREPROC++=ON -DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC" .. &&
    make -j$(nproc) &&
    make install
)
rm -rf reproc

# 13. nlohmann-json (Header-only, 但确保安装 CMake files)
echo "正在安装 nlohmann-json..."
git_clone_with_retry https://github.com/nlohmann/json.git
#cp -r /opt/builder/json ./json
(
  cd json &&
    mkdir build &&
    cd build &&
    cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DJSON_BuildTests=OFF -DCMAKE_BUILD_TYPE=Release &&
    make -j$(nproc) && make install
)
rm -rf json

# 14. simdjson
echo "正在安装 simdjson..."
git_clone_with_retry https://github.com/simdjson/simdjson.git
#cp -r /opt/builder/simdjson ./simdjson
(
  cd simdjson &&
    mkdir build &&
    cd build &&
    cmake .. \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DBUILD_SHARED_LIBS=OFF \
      -DSIMDJSON_BUILD_STATIC=ON \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DSIMDJSON_ENABLE_THREADS=ON \
      -DSIMDJSON_DEVELOPMENT_CHECKS=OFF &&
    make -j$(nproc) &&
    make install
)
rm -rf simdjson

# 15. yaml-cpp
echo "正在安装 yaml-cpp..."
git_clone_with_retry https://github.com/jbeder/yaml-cpp.git yaml-cpp-repo
#cp -r /opt/builder/yaml-cpp-repo ./yaml-cpp-repo
(
  cd yaml-cpp-repo &&
    mkdir build &&
    cd build &&
    cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DBUILD_SHARED_LIBS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release &&
    make -j$(nproc) &&
    make install
)
rm -rf yaml-cpp-repo

# 16. CLI11
echo "正在安装 CLI11..."
git_clone_with_retry https://github.com/CLIUtils/CLI11.git
#cp -r /opt/builder/CLI11 ./CLI11
(
  cd CLI11 &&
    mkdir build &&
    cd build &&
    cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DBUILD_SHARED_LIBS=OFF -DCLI11_BUILD_EXAMPLES=OFF -DCLI11_BUILD_TESTS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release &&
    make -j$(nproc) &&
    make install
)
rm -rf CLI11

# 17. e2fsprogs (for libcom_err)
echo "正在安装 e2fsprogs (for libcom_err)..."
download_with_retry https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.2/e2fsprogs-1.47.2.tar.gz e2fsprogs.tar.gz
tar -xzf e2fsprogs.tar.gz
(cd e2fsprogs-1.47.2 && ./configure --prefix="${DEPS_PREFIX}" --disable-shared --enable-static CFLAGS="-fPIC" &&
  make -j$(nproc) &&
  make -C lib/et install)
rm -rf e2fsprogs-1.47.2 e2fsprogs.tar.gz

# 18. bzip2 (libbz2)
echo "正在安装 bzip2..."
download_with_retry https://mirrors.tuna.tsinghua.edu.cn/sourceware/bzip2/bzip2-1.0.8.tar.gz bzip2.tar.gz
#download_with_retry https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz bzip2.tar.gz
tar -xzf bzip2.tar.gz
(cd bzip2-1.0.8 &&
  make install PREFIX="${DEPS_PREFIX}" CFLAGS="-fPIC -O2 -g -D_FILE_OFFSET_BITS=64" &&
  make -f Makefile-libbz2_so CFLAGS="-fPIC -O2 -g -D_FILE_OFFSET_BITS=64" libbz2.a &&
  cp libbz2.a "${DEPS_PREFIX}/lib/" &&
  cp bzlib.h "${DEPS_PREFIX}/include/")
# bzip2 的 make install 会安装可执行文件，我们额外构建并复制静态库
rm -rf bzip2-1.0.8 bzip2.tar.gz

# 19. xz-utils (liblzma)
echo "正在安装 xz-utils (liblzma)..."
download_with_retry https://tukaani.org/xz/xz-5.4.6.tar.gz xz-utils.tar.gz
tar -xzf xz-utils.tar.gz
(cd xz-5.4.6 && ./configure --prefix="${DEPS_PREFIX}" --disable-shared --enable-static --disable-doc --disable-scripts CFLAGS="-fPIC" && make -j$(nproc) && make install)
rm -rf xz-5.4.6 xz-utils.tar.gz

# 20. lz4 (liblz4)
echo "正在安装 lz4..."
download_with_retry https://github.com/lz4/lz4/archive/refs/tags/v1.9.4.tar.gz lz4.tar.gz
tar -xzf lz4.tar.gz
(cd lz4-1.9.4 && make PREFIX="${DEPS_PREFIX}" CFLAGS="-fPIC" liblz4.a && make PREFIX="${DEPS_PREFIX}" install)
# LZ4 make install 默认可能安装共享库，我们确保静态库也被构建和安装
# make install 应该会安装 liblz4.a 和头文件
rm -rf lz4-1.9.4 lz4.tar.gz

# 21. zstd (libzstd)
echo "正在安装 zstd..."
download_with_retry https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz zstd.tar.gz
tar -xzf zstd.tar.gz
(cd zstd-1.5.6 && rm -rf cmake-build && mkdir cmake-build && cd cmake-build && cmake ../build/cmake \
  -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
  -DZSTD_BUILD_SHARED=ON \
  -DZSTD_BUILD_STATIC=ON \
  -DZSTD_PROGRAMS_ENABLE=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_BUILD_TYPE=Release &&
  make -j$(nproc) && make install)
rm -rf zstd-1.5.6 zstd.tar.gz

# 22. nghttp2 (libnghttp2)
echo "正在安装 nghttp2..."
download_with_retry https://github.com/nghttp2/nghttp2/releases/download/v1.61.0/nghttp2-1.61.0.tar.gz nghttp2.tar.gz
tar -xzf nghttp2.tar.gz
(cd nghttp2-1.61.0 && ./configure --prefix="${DEPS_PREFIX}" \
  --enable-static \
  --disable-shared \
  --enable-lib-only \
  --disable-app \
  --disable-examples \
  --disable-hpack-tools \
  CFLAGS="-fPIC" CXXFLAGS="-fPIC" \
  PKG_CONFIG_PATH="${PKG_CONFIG_PATH}" &&
  make -j$(nproc) && make install)
rm -rf nghttp2-1.61.0 nghttp2.tar.gz

# 23. libssh2 (libssh2)
echo "正在安装 libssh2..."
download_with_retry https://libssh2.org/download/libssh2-1.11.1.tar.gz libssh2.tar.gz
tar -xzf libssh2.tar.gz
(cd libssh2-1.11.1 && ./configure --prefix="${DEPS_PREFIX}" \
  --enable-static \
  --disable-shared \
  --with-libssl-prefix="${DEPS_PREFIX}" \
  --with-libz-prefix="${DEPS_PREFIX}" \
  --disable-examples \
  CFLAGS="-fPIC -I${DEPS_PREFIX}/include" \
  LDFLAGS="-L${DEPS_PREFIX}/lib" \
  LIBS="-lssl -lcrypto -lz -ldl -lpthread" &&
  make -j$(nproc) && make install)
rm -rf libssh2-1.11.1 libssh2.tar.gz

# 24. krb5 (Kerberos)
echo "正在安装 krb5..."
download_with_retry https://kerberos.org/dist/krb5/1.21/krb5-1.21.2.tar.gz krb5.tar.gz
tar -xzf krb5.tar.gz
(cd krb5-1.21.2/src && \
  env -u CFLAGS -u CXXFLAGS ./configure \
  --prefix="${DEPS_PREFIX}" \
  --disable-shared \
  --enable-static \
  --with-crypto-impl=openssl \
  --without-ldap \
  --disable-nls \
  --disable-rpath \
  --with-system-et \
  CFLAGS="-fPIC -fcommon -I${DEPS_PREFIX}/include" \
  LDFLAGS="-L${DEPS_PREFIX}/lib" \
  LIBS="-lcom_err -lssl -lcrypto -lz -ldl -lpthread" && \
  make -j$(nproc) && make install)
rm -rf krb5-1.21.2 krb5.tar.gz

# 25. 安装pybind11
echo "正在安装 pybind11..."
download_with_retry https://github.com/pybind/pybind11/archive/refs/tags/v2.11.1.tar.gz pybind11.tar.gz
tar -xzf pybind11.tar.gz
(cd pybind11-2.11.1 && mkdir build && cd build && cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON && make -j$(nproc) && make install)
rm -rf pybind11-2.11.1 pybind11.tar.gz



echo "=== Micromamba 的静态依赖库已成功安装到 ${DEPS_PREFIX} ==="
