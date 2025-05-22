#!/bin/bash
set -eo pipefail
set -x

# 变量定义，与 build_python.sh 保持一致
INSTALL_ROOT="/opt/conda_tools"
MICROMAMBA_INSTALL_DIR="${INSTALL_ROOT}/micromamba"
CONDA_ENV_DIR="${INSTALL_ROOT}/env"
DEPS_PREFIX="/opt/conda_static_deps"
export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${LD_LIBRARY_PATH}"

# 确保 micromamba 路径在 PATH 中
export PATH="/root/.cargo/bin:${MICROMAMBA_INSTALL_DIR}/bin:${PATH}"


# 辅助函数，用于在 Conda 环境中执行命令
run_in_env() {
    "${MICROMAMBA_INSTALL_DIR}/bin/micromamba" run -p "${CONDA_ENV_DIR}" "$@"
}

#安装menuinst
echo "=== 1. 安装 menuinst ==="
cd /tmp
git clone --depth 1 https://github.com/conda/menuinst.git -b 2.2.0
cd menuinst
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf menuinst
echo "menuinst 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 3. 从源码安装 Conda (Python包) ==="
cd /tmp
git clone --depth 1 https://github.com/conda/conda.git -b 25.3.1
cd conda
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda
echo "Conda 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 4. 从源码安装 Conda-Build ==="
cd /tmp
git clone --depth 1 https://github.com/conda/conda-build.git -b 25.4.2
cd conda-build
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-build
echo "Conda-Build 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 5. 从源码安装 Conda-Index ==="
cd /tmp
git clone --depth 1 https://github.com/conda/conda-index.git -b 0.6.0
cd conda-index
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-index
echo "Conda-Index 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 6. 从源码安装 Conda-Smithy ==="
cd /tmp
git clone --depth 1 https://github.com/conda-forge/conda-smithy.git -b v3.48.1
cd conda-smithy
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-smithy
echo "Conda-Smithy 已安装到环境 ${CONDA_ENV_DIR}"

#安装conda-libmamba-solver
echo "=== 7. 安装 conda-libmamba-solver ==="
cd /tmp
git clone --depth 1 https://github.com/conda/conda-libmamba-solver.git -b 25.4.0
cd conda-libmamba-solver
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-libmamba-solver

echo "=== 7. 清理工作 ==="
run_in_env micromamba clean -a -y

echo "=== Conda 及相关工具安装完成 ==="
