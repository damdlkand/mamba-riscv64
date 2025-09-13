#!/bin/bash
set -eo pipefail # 如果任何命令失败，脚本将立即退出
set -x # 执行时打印命令及其参数。

# 定义安装的根目录和各个组件的安装路径
# 这些应该与 build_dep.sh 和 build_micromamba.sh 中的定义一致
INSTALL_ROOT="/opt/conda_tools"
MICROMAMBA_INSTALL_DIR="${INSTALL_ROOT}/micromamba"
CONDA_ENV_DIR="${INSTALL_ROOT}/env" # Conda 环境的路径
DEPS_PREFIX="/opt/conda_static_deps" # 静态依赖的安装路径，与 build_dep.sh 一致

# 确保 Micromamba 的路径在 PATH 中
# Dockerfile 中也会设置 PATH，但在这里重申以确保脚本独立可运行性（如果单独测试）
export PATH="${MICROMAMBA_INSTALL_DIR}/bin:${PATH}"
# 确保编译 Python 时能找到 DEPS_PREFIX 中的库和头文件
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/lib64/pkgconfig:${DEPS_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH}"
export CPPFLAGS="-I${DEPS_PREFIX}/include ${CPPFLAGS}"
export CFLAGS="-fPIC -mcmodel=medany ${CFLAGS}"
export CXXFLAGS="-fPIC -mcmodel=medany ${CXXFLAGS}"
export LDFLAGS="-L${DEPS_PREFIX}/lib -L${DEPS_PREFIX}/lib64 ${LDFLAGS}"
export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${LD_LIBRARY_PATH}"

# 创建 Conda 环境目录的父目录（如果尚不存在）
mkdir -p "${INSTALL_ROOT}"

echo "=== 2. 使用 Micromamba 创建基础 Conda 环境 (不预装 Python) ==="
# 创建一个空环境，稍后我们将从源码编译并安装 Python 到此环境
"${MICROMAMBA_INSTALL_DIR}/bin/micromamba" create -p "${CONDA_ENV_DIR}" -y --no-deps
echo "基础 Conda 环境结构已创建于 ${CONDA_ENV_DIR}"

# 辅助函数，用于在创建的 Conda 环境中执行命令
run_in_env() {
   # echo "run_in_env-------start"
    #"${MICROMAMBA_INSTALL_DIR}/bin/micromamba" run -p "${CONDA_ENV_DIR}" "$@"
    #exit_code=$?
    #echo "micromamba exit code: $exit_code"
    #echo "run_in_env-------end"
    cd /opt/conda_tools/micromamba/bin

    # 手动初始化shell hook（关键步骤）
    eval "$(/opt/conda_tools/micromamba/bin/micromamba shell hook --shell bash)"

    # 现在可以使用micromamba命令了
    micromamba activate ${CONDA_ENV_DIR}
    "$@"
    micromamba deactivate

    cd -
}

echo "=== 2.1. 从源码编译并安装 Python 到 Conda 环境 ==="

# 重要: 确保编译 Python 所需的依赖已安装 (例如: build-essential)
# build_dep.sh 应该已经编译了 openssl, zlib 等到 DEPS_PREFIX
PYTHON_VERSION="3.12.10" # 您选择一个合适的 Python 版本
PYTHON_SRC_DIR="/tmp/Python-${PYTHON_VERSION}"
#cp /opt/conda_static_deps/lib64/* /opt/conda_static_deps/lib/
cd /tmp
if [ ! -f "Python-${PYTHON_VERSION}.tgz" ]; then
    wget "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" --no-check-certificate
fi
tar -xzf "Python-${PYTHON_VERSION}.tgz"
cd "${PYTHON_SRC_DIR}"

echo "准备配置 Python..."
echo "DEPS_PREFIX for configure: ${DEPS_PREFIX}"
echo "CONDA_ENV_DIR for configure: ${CONDA_ENV_DIR}"
echo "Current LDFLAGS for configure: ${LDFLAGS}"
echo "Current CPPFLAGS for configure: ${CPPFLAGS}"
echo "Current PKG_CONFIG_PATH for configure: ${PKG_CONFIG_PATH}"

#patch python的configure ，使其中的" OPENSSL_LIBS="-lssl -lcrypto" 替换为 "OPENSSL_LIBS="-lssl -lcrypto -lz"
sed -i 's/OPENSSL_LIBS="-lssl -lcrypto"/OPENSSL_LIBS="-lssl -lcrypto -lz"/' configure

# 配置编译选项

./configure --prefix="${CONDA_ENV_DIR}" \
            --with-ensurepip=install \
            --enable-static \
            --with-openssl="${DEPS_PREFIX}" \
            --with-system-expat \
            --enable-loadable-sqlite-extensions

# echo "输出 Python config.log 内容:"
# cat "${PYTHON_SRC_DIR}/config.log" || echo "config.log 未找到或无法读取"
# echo "输出 Python config.log 内容结束"

make -j$(nproc)
make install

echo "创建 python 和 pip 的符号链接到 python3 和 pip3"
if [ -f "${CONDA_ENV_DIR}/bin/python3" ] && [ ! -f "${CONDA_ENV_DIR}/bin/python" ]; then
    ln -s python3 "${CONDA_ENV_DIR}/bin/python"
    echo "已创建符号链接 ${CONDA_ENV_DIR}/bin/python -> python3"
fi
if [ -f "${CONDA_ENV_DIR}/bin/pip3" ] && [ ! -f "${CONDA_ENV_DIR}/bin/pip" ]; then
    ln -s pip3 "${CONDA_ENV_DIR}/bin/pip"
    echo "已创建符号链接 ${CONDA_ENV_DIR}/bin/pip -> pip3"
fi

cd /tmp
rm -rf "${PYTHON_SRC_DIR}" "Python-${PYTHON_VERSION}.tgz"
echo "Python ${PYTHON_VERSION} 已编译并安装到 ${CONDA_ENV_DIR}"

# 验证环境中新安装的 Python 和 Pip
run_in_env echo "Micromamba run test in env ${CONDA_ENV_DIR} successful."
echo "1---end"
run_in_env python --version # 确认使用的是我们编译的 Python
echo "2---end"
run_in_env pip --version   # 确认 pip 也来自我们编译的 Python
echo "3---end"
run_in_env python -c "import ssl; print(ssl.OPENSSL_VERSION)" # 检查链接的 OpenSSL 版本
# 验证python加载的so库
echo "4---end"
run_in_env ldd "${CONDA_ENV_DIR}/bin/python"

echo "all---end"

echo "=== 安装完成 ==="
echo "Micromamba 安装于: ${MICROMAMBA_INSTALL_DIR}/bin"
echo "Python (从源码编译) 安装于 Conda 环境: ${CONDA_ENV_DIR}"
echo "PATH 环境变量已在 Dockerfile 中设置，可以直接使用这些工具。"
echo "如果需要在新的交互式 shell 中激活环境 (例如在容器内):"
echo "  micromamba activate ${CONDA_ENV_DIR}"
echo "或者 (如果 micromamba 不在 PATH):"
echo "  ${MICROMAMBA_INSTALL_DIR}/bin/micromamba activate ${CONDA_ENV_DIR}" 



