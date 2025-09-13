cat > compile_python311.sh << 'EOF'
#!/bin/bash

# 设置环境变量
INSTALL_ROOT="/opt/conda_tools"
DEPS_PREFIX="/opt/conda_static_deps"
PYTHON_VERSION="3.11.7"
PYTHON_INSTALL_DIR="${INSTALL_ROOT}/env_py311"

# 设置编译环境变量
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH}"
export CPPFLAGS="-I${DEPS_PREFIX}/include ${CPPFLAGS}"
export CFLAGS="-fPIC -mcmodel=medany ${CFLAGS}"
export CXXFLAGS="-fPIC -mcmodel=medany ${CXXFLAGS}"
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${DEPS_PREFIX}/lib64 ${LDFLAGS}"
export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${LD_LIBRARY_PATH}"

echo "=== 开始编译 Python ${PYTHON_VERSION} ==="

# 创建安装目录
mkdir -p "${PYTHON_INSTALL_DIR}"

# 下载源码
cd /tmp
if [ ! -f "Python-${PYTHON_VERSION}.tgz" ]; then
    echo "下载 Python ${PYTHON_VERSION} 源码..."
    wget "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" --no-check-certificate
fi

# 解压源码
echo "解压源码..."
tar -xzf "Python-${PYTHON_VERSION}.tgz"
cd "Python-${PYTHON_VERSION}"

# 配置编译选项
echo "配置编译选项..."
./configure --prefix="${PYTHON_INSTALL_DIR}" \
            --with-ensurepip=install \
            --enable-static \
            --with-openssl="${DEPS_PREFIX}" \
            --with-system-expat \
            --enable-loadable-sqlite-extensions

# 编译
echo "开始编译..."
make -j$(nproc)

# 安装
echo "安装 Python ${PYTHON_VERSION}..."
make install

# 创建符号链接
echo "创建符号链接..."
if [ -f "${PYTHON_INSTALL_DIR}/bin/python3" ] && [ ! -f "${PYTHON_INSTALL_DIR}/bin/python" ]; then
    ln -s python3 "${PYTHON_INSTALL_DIR}/bin/python"
fi
if [ -f "${PYTHON_INSTALL_DIR}/bin/pip3" ] && [ ! -f "${PYTHON_INSTALL_DIR}/bin/pip" ]; then
    ln -s pip3 "${PYTHON_INSTALL_DIR}/bin/pip"
fi

# 清理
cd /tmp
rm -rf "Python-${PYTHON_VERSION}" "Python-${PYTHON_VERSION}.tgz"

# 验证安装
echo "验证安装..."
"${PYTHON_INSTALL_DIR}/bin/python" --version
"${PYTHON_INSTALL_DIR}/bin/python" -c "import ssl; print('OpenSSL version:', ssl.OPENSSL_VERSION)"

echo "=== Python ${PYTHON_VERSION} 编译完成 ==="
echo "安装路径: ${PYTHON_INSTALL_DIR}"
echo "使用方法: ${PYTHON_INSTALL_DIR}/bin/python"
EOF

chmod +x compile_python311.sh
