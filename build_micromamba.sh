#!/bin/bash
set -eo pipefail # 如果任何命令失败，脚本将立即退出
set -x # 执行时打印命令及其参数。

# 定义安装的根目录和各个组件的安装路径
# 这些应该与 build_dep.sh 和 build_conda.sh 中的定义一致
INSTALL_ROOT="/opt/conda_tools"
MICROMAMBA_INSTALL_DIR="${INSTALL_ROOT}/micromamba"
DEPS_PREFIX="/opt/conda_static_deps" # Micromamba 编译时需要链接这些静态库

# 确保 Micromamba 安装目录存在
mkdir -p "${MICROMAMBA_INSTALL_DIR}"

# 设置环境变量，以便 Micromamba 编译时能找到静态依赖
export PATH="${DEPS_PREFIX}/bin:${PATH}"
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/lib64/pkgconfig:${DEPS_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"
export CPPFLAGS="-I${DEPS_PREFIX}/include ${CPPFLAGS}"
export CFLAGS="-fPIC ${CFLAGS}"
export CXXFLAGS="-fPIC ${CXXFLAGS}"
# LDFLAGS 需要包含所有静态链接的库，这通常由 CMake 在 mamba 项目内部处理，
# 但为了以防万一，可以设置基础的库路径。
# Mamba 的 CMakeLists.txt 应该会处理具体链接哪些库。
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${DEPS_PREFIX}/lib64 ${LDFLAGS}"
export CMAKE_PREFIX_PATH="${DEPS_PREFIX}:${CMAKE_PREFIX_PATH}"


export LD_LIBRARY_PATH=/opt/conda_static_deps/lib64:/opt/conda_static_deps/lib:$LD_LIBRARY_PATH

echo "=== 1. 从源码安装 Micromamba ==="
# Micromamba 的编译依赖 (cmake, C++ 编译器等) 应已在 Dockerfile 中安装
cd /tmp # 在 /tmp 目录进行编译，避免污染工作目�

#git clone --depth 1 https://github.com/mamba-org/mamba.git
#git clone git@gitee.com:physicaldddd/mamba.git

#mv  /home/wulin/conda-docker/conda-docker/mamba ./

#if [ ! -d mamba ]; then
#    git clone --depth 1 https://github.com/mamba-org/mamba.git
#else
#    echo "mamba 目录已存在，跳过 git clone。"
#fi
#ls ./
cp -r /opt/builder/mamba ./
cd mamba

# 在运行 CMake 之前修补 mamba 的 libmamba/CMakeLists.txt
# 错误日志显示 libmamba/CMakeLists.txt 尝试链接 simdjson::simdjson_static
# 我们假设 DEPS_PREFIX 中的 simdjson 提供了静态库，
# 并且其 CMake 目标 simdjson::simdjson 指向该静态库。
echo "Attempting to patch mamba's libmamba/CMakeLists.txt to use simdjson::simdjson"
if [ -f libmamba/CMakeLists.txt ]; then
    if grep -q "simdjson::simdjson_static" libmamba/CMakeLists.txt; then
        sed -i 's/simdjson::simdjson_static/simdjson::simdjson/g' libmamba/CMakeLists.txt
        echo "Successfully patched libmamba/CMakeLists.txt for simdjson."
    else
        echo "Pattern 'simdjson::simdjson_static' not found in libmamba/CMakeLists.txt. No simdjson patch applied. This might be okay if mamba's source changed."
    fi
else
    echo "Warning: libmamba/CMakeLists.txt not found at expected location. Cannot apply simdjson patch."
fi

# 应用 micromamba/CMakeLists.txt 的补丁
echo "Attempting to patch mamba's micromamba/CMakeLists.txt for linking dependencies"
MICROMAMBA_CMAKE_PATCH_CONTENT=$(cat <<'EOF'
--- a/micromamba/CMakeLists.txt
+++ b/micromamba/CMakeLists.txt
@@ -68,7 +68,8 @@ macro(mambaexe_create_target target_name linkage output_name)
     mamba_target_set_lto(${target_name} MODE ${MAMBA_LTO})
     set_property(TARGET ${target_name} PROPERTY CXX_STANDARD 17)
 
-    target_link_libraries(${target_name} PRIVATE Threads::Threads reproc reproc++)
+    # 重要：先不链接任何库，等所有库都找到后再统一链接
+    # 避免循环依赖问题
 
     # Static build
     # ============
@@ -76,7 +77,144 @@ macro(mambaexe_create_target target_name linkage output_name)
         if(NOT (TARGET mamba::libmamba-static))
             find_package(libmamba REQUIRED)
         endif()
-        target_link_libraries(${target_name} PRIVATE mamba::libmamba-static)
+
+        # 查找所有需要的库
+        find_library(PSL_LIBRARY NAMES psl libpsl REQUIRED)
+        find_library(BROTLIDEC_LIBRARY NAMES brotlidec libbrotlidec REQUIRED)
+        find_library(BROTLICOMMON_LIBRARY NAMES brotlicommon libbrotlicommon REQUIRED)
+        find_library(IDN2_LIBRARY NAMES idn2 libidn2 REQUIRED)
+        find_library(UNISTRING_LIBRARY NAMES unistring libunistring REQUIRED)
+        
+        
+        find_library(XML2_LIBRARY NAMES xml2 libxml2 REQUIRED)
+        
+
+        # 额外库 - 根据成功的编译命令添加
+        find_library(FMT_LIBRARY NAMES fmt libfmt REQUIRED)
+        find_library(YAMLCPP_LIBRARY NAMES yaml-cpp libyaml-cpp REQUIRED)
+        find_library(SIMDJSON_LIBRARY NAMES simdjson libsimdjson REQUIRED)
+        find_library(SOLV_LIBRARY NAMES solv libsolv REQUIRED)
+        find_library(SOLVEXT_LIBRARY NAMES solvext libsolvext REQUIRED)
+        find_library(CURL_LIBRARY NAMES curl libcurl REQUIRED)
+        find_library(SSH2_LIBRARY NAMES ssh2 libssh2 REQUIRED)
+        find_library(GSSAPI_KRB5_LIBRARY NAMES gssapi_krb5 libgssapi_krb5 REQUIRED)
+        find_library(KRB5_LIBRARY NAMES krb5 libkrb5 REQUIRED)
+        find_library(K5CRYPTO_LIBRARY NAMES k5crypto libk5crypto REQUIRED)
+        find_library(KRB5SUPPORT_LIBRARY NAMES krb5support libkrb5support REQUIRED)
+        find_library(COM_ERR_LIBRARY NAMES com_err libcom_err REQUIRED)
+        find_library(SSL_LIBRARY NAMES ssl libssl REQUIRED)
+        find_library(CRYPTO_LIBRARY NAMES crypto libcrypto REQUIRED)
+        find_library(ARCHIVE_LIBRARY NAMES archive libarchive REQUIRED)
+        find_library(BZ2_LIBRARY NAMES bz2 libbz2 REQUIRED)
+        find_library(LZ4_LIBRARY NAMES lz4 liblz4 REQUIRED)
+        find_library(ZSTD_LIBRARY NAMES zstd libzstd REQUIRED)
+        find_library(Z_LIBRARY NAMES z libz REQUIRED)
+        find_library(LZMA_LIBRARY NAMES lzma liblzma REQUIRED)
+        find_library(NGHTTP2_LIBRARY NAMES nghttp2 libnghttp2 REQUIRED)
+
+        # 使用普通链接方式，避免LINK_GROUP生成循环依赖
+        if(UNIX AND NOT APPLE)
+            # 在Linux系统上使用--start-group和--end-group链接方式
+            # 不用CMake的LINK_GROUP，而是手动构建链接命令
+            target_link_libraries(${target_name} PRIVATE
+                Threads::Threads
+                reproc
+                reproc++
+            )
+
+            # 构建链接命令，确保将所有库放在一个组内
+            set(GROUP_LIBS "-Wl,--start-group")
+            list(APPEND GROUP_LIBS
+                mamba::libmamba-static
+                ${PSL_LIBRARY}
+                ${BROTLICOMMON_LIBRARY}
+                ${BROTLIDEC_LIBRARY}
+                ${IDN2_LIBRARY}
+                ${UNISTRING_LIBRARY}
+                
+                
+                ${XML2_LIBRARY}
+                
+                ${FMT_LIBRARY}
+                ${YAMLCPP_LIBRARY}
+                ${SIMDJSON_LIBRARY}
+                ${SOLV_LIBRARY}
+                ${SOLVEXT_LIBRARY}
+                ${CURL_LIBRARY}
+                ${SSH2_LIBRARY}
+                ${GSSAPI_KRB5_LIBRARY}
+                ${KRB5_LIBRARY}
+                ${K5CRYPTO_LIBRARY}
+                ${KRB5SUPPORT_LIBRARY}
+                ${COM_ERR_LIBRARY}
+                ${SSL_LIBRARY}
+                ${CRYPTO_LIBRARY}
+                ${ARCHIVE_LIBRARY}
+                ${BZ2_LIBRARY}
+                ${LZ4_LIBRARY}
+                ${ZSTD_LIBRARY}
+                ${Z_LIBRARY}
+                ${LZMA_LIBRARY}
+                ${NGHTTP2_LIBRARY}
+                 
+                 
+                 
+                
+                -lrt
+                -ldl
+                -lresolv
+            )
+            list(APPEND GROUP_LIBS "-Wl,--end-group")
+
+            # 将整个组添加为链接项
+            target_link_libraries(${target_name} PRIVATE "${GROUP_LIBS}")
+        else()
+            # 对于非Unix系统，使用普通的链接方式
+            target_link_libraries(${target_name} PRIVATE
+                Threads::Threads
+                reproc
+                reproc++
+                mamba::libmamba-static
+                ${PSL_LIBRARY}
+                ${BROTLICOMMON_LIBRARY}
+                ${BROTLIDEC_LIBRARY}
+                ${IDN2_LIBRARY}
+                 
+                
+                
+                ${XML2_LIBRARY}
+                
+                ${FMT_LIBRARY}
+                ${YAMLCPP_LIBRARY}
+                ${SIMDJSON_LIBRARY}
+                ${SOLV_LIBRARY}
+                ${SOLVEXT_LIBRARY}
+                ${CURL_LIBRARY}
+                ${SSH2_LIBRARY}
+                ${GSSAPI_KRB5_LIBRARY}
+                ${KRB5_LIBRARY}
+                ${K5CRYPTO_LIBRARY}
+                ${KRB5SUPPORT_LIBRARY}
+                ${COM_ERR_LIBRARY}
+                ${SSL_LIBRARY}
+                ${CRYPTO_LIBRARY}
+                ${ARCHIVE_LIBRARY}
+                ${BZ2_LIBRARY}
+                ${LZ4_LIBRARY}
+                ${ZSTD_LIBRARY}
+                ${Z_LIBRARY}
+                ${LZMA_LIBRARY}
+                ${NGHTTP2_LIBRARY}
+                gnutls
+                nettle
+                hogweed
+                gmp
+                rt
+                dl
+                resolv
+            )
+        endif()
+
         if(APPLE)
             target_link_options(${target_name} PRIVATE -nostdlib++)
         endif()
EOF
)

if [ -f micromamba/CMakeLists.txt ]; then
    echo "${MICROMAMBA_CMAKE_PATCH_CONTENT}" > /tmp/micromamba_cmake.patch
    if patch -p1 -N --dry-run < /tmp/micromamba_cmake.patch > /dev/null; then
        patch -p1 < /tmp/micromamba_cmake.patch
        echo "Successfully patched micromamba/CMakeLists.txt."
    else
        echo "Warning: Failed to apply patch to micromamba/CMakeLists.txt (dry run failed or patch already applied)."
        # 尝试检查是否是因为补丁已经应用
        # 注意：这种检查方式比较粗略，可能不完全准确
        if ! patch -p1 -N --reverse --dry-run < /tmp/micromamba_cmake.patch > /dev/null; then
             echo "Micromamba patch seems to be already applied or file content is unexpected."
        else
             echo "Micromamba patch dry run failed for other reasons."
        fi
    fi
    rm -f /tmp/micromamba_cmake.patch
else
    echo "Warning: micromamba/CMakeLists.txt not found at expected location. Cannot apply micromamba CMake patch."
fi

mkdir build && cd build

# 注意：LDFLAGS 和 LIBS 的设置对于静态链接至关重要
# Mamba 的 CMake 可能足够智能，可以找到 DEPS_PREFIX 中的库，
# 但有时需要显式指定。
# Micromamba 的 CMake 配置应该会使用 CMAKE_PREFIX_PATH 来找到依赖项。
# 它会查找如 libcurl.a, libssl.a, libcrypto.a, libsolv.a, libarchive.a 等。

echo "--- Listing CMake files in DEPS_PREFIX ---"
echo "Listing ${DEPS_PREFIX}/lib/cmake:"
ls -R "${DEPS_PREFIX}/lib/cmake" || echo "Directory ${DEPS_PREFIX}/lib/cmake not found or ls failed"
echo "Listing ${DEPS_PREFIX}/lib64/cmake:"
ls -R "${DEPS_PREFIX}/lib64/cmake" || echo "Directory ${DEPS_PREFIX}/lib64/cmake not found or ls failed"
echo "Listing ${DEPS_PREFIX}/share/cmake:"
ls -R "${DEPS_PREFIX}/share/cmake" || echo "Directory ${DEPS_PREFIX}/share/cmake not found or ls failed"
echo "--- End listing CMake files ---"

#cmake .. -DCMAKE_INSTALL_PREFIX="${MICROMAMBA_INSTALL_DIR}" \
#         -DBUILD_LIBMAMBA=ON \
#         -DBUILD_MICROMAMBA=ON \
#         -DBUILD_SHARED=OFF \
#         -DBUILD_STATIC=ON \
#	 -DCMAKE_CXX_FLAGS="-I/usr/local/include"\
#         -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" 
cmake .. -DCMAKE_INSTALL_PREFIX="${MICROMAMBA_INSTALL_DIR}" \
         -DBUILD_LIBMAMBA=ON \
         -DBUILD_MICROMAMBA=ON \
         -DBUILD_SHARED=OFF \
         -DBUILD_STATIC=ON \
         -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
         -DCMAKE_C_COMPILER=gcc-14 \
         -DCMAKE_CXX_COMPILER=g++-14 \
         -DCMAKE_CXX_STANDARD=20 \
         -Dfmt_DIR="${DEPS_PREFIX}/lib64/cmake/fmt"

make -j$(nproc) # 使用所有可用的 CPU核心进行编译
make install

#cp /opt/conda_static_deps/lib64/libsolv.so.1  /opt/conda_static_deps/lib/
cp /opt/conda_static_deps/lib64/lib* /opt/conda_static_deps/lib/
cd /tmp # 返回 /tmp
rm -rf mamba # 清理源码
echo "Micromamba 已安装到 ${MICROMAMBA_INSTALL_DIR}/bin"

# 确保 Micromamba 在 PATH 中，以便后续脚本可以使用它
export PATH="${MICROMAMBA_INSTALL_DIR}/bin:${PATH}"
# 验证安装
micromamba --version
