#!/bin/bash
set -eo pipefail
set -x

# 变量定义，与 build_python.sh 保持一致
INSTALL_ROOT="/opt/conda_tools"
MICROMAMBA_INSTALL_DIR="${INSTALL_ROOT}/micromamba"
CONDA_ENV_DIR="${INSTALL_ROOT}/env"
DEPS_PREFIX="/opt/conda_static_deps"
export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${DEPS_PREFIX}/lib64:${LD_LIBRARY_PATH}"

# 确保 micromamba 路径在 PATH 中
export PATH="/root/.cargo/bin:${MICROMAMBA_INSTALL_DIR}/bin:${PATH}"

export CMAKE_PREFIX_PATH=/opt/conda_static_deps:${CMAKE_PREFIX_PATH}
# 辅助函数，用于在 Conda 环境中执行命令
run_in_env() {
   # "${MICROMAMBA_INSTALL_DIR}/bin/micromamba" run -p "${CONDA_ENV_DIR}" "$@"
   #cd /opt/conda_tools/micromamba/bin

   eval "$(/opt/conda_tools/micromamba/bin/micromamba shell hook --shell bash)"

   micromamba activate ${CONDA_ENV_DIR}
   "$@"
   micromamba deactivate

  
}

#安装menuinst
echo "=== 1. 安装 menuinst ==="
cd /tmp
#git clone --depth 1 https://github.com/conda/menuinst.git -b 2.2.0
cp -r /opt/builder/menuinst ./
cd menuinst
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf menuinst
echo "menuinst 已安装到环境 ${CONDA_ENV_DIR}"



echo "===2.LIEF==="
#build LIEF
cp -r /opt/builder/LIEF ./
cd LIEF/api/python
run_in_env python -m pip install .
#run_in_env python -c "import lief;print('LIEF version:',lief.__version__)"
rm -rf LIEF

echo "=== 3. 从源码安装 Conda (Python包) ==="
cd /tmp
#git clone --depth 1 https://github.com/conda/conda.git -b 25.3.1
cp -r /opt/builder/conda ./
cd conda
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda
echo "Conda 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 4. 从源码安装 Conda-Build ==="
cd /tmp
#git clone --depth 1 https://github.com/conda/conda-build.git -b 25.4.2
cp -r /opt/builder/conda-build ./
cd conda-build
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-build
echo "Conda-Build 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 5. 从源码安装 Conda-Index ==="
cd /tmp
#git clone --depth 1 https://github.com/conda/conda-index.git -b 0.6.0
cp -r /opt/builder/conda-index ./
cd conda-index
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-index
echo "Conda-Index 已安装到环境 ${CONDA_ENV_DIR}"

echo "=== 6. 从源码安装 Conda-Smithy ==="
cd /tmp
#git clone --depth 1 https://github.com/conda-forge/conda-smithy.git -b v3.48.1
cp -r /opt/builder/conda-smithy ./
cd conda-smithy
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-smithy
echo "Conda-Smithy 已安装到环境 ${CONDA_ENV_DIR}"

#安装conda-libmamba-solver
echo "=== 7. 安装 conda-libmamba-solver ==="
cd /tmp
#git clone --depth 1 https://github.com/conda/conda-libmamba-solver.git -b 25.4.0
cp -r /opt/builder/conda-libmamba-solver ./
cd conda-libmamba-solver
run_in_env python -m pip install --no-cache-dir .
cd /tmp
rm -rf conda-libmamba-solver

# 构建Error while loading conda entry point: conda-libmamba-solver (No module named 'libmambapy')
# 安装libmambapy
echo "=== 8. 安装 libmambapy ==="
cd /tmp
#git clone --depth 1 https://github.com/mamba-org/mamba 
cp -r /opt/builder/mamba ./
cd mamba
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
         -DBUILD_LIBMAMBA=ON \
         -DBUILD_MICROMAMBA=OFF \
         -DBUILD_SHARED=ON \
         -DBUILD_STATIC=OFF \
         -DBUILD_LIBMAMBAPY=ON \
	 -Dlibmamba_DIR=/opt/conda_static_deps/lib64/cmake/libmamba \
         -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}"
make -j$(nproc)
make install
cd ..
run_in_env python -m pip install --no-cache-dir ./libmambapy
cd /tmp
rm -rf mamba


#build LIEF

echo "=== 7. 清理工作 ==="
run_in_env micromamba clean -a -y

echo "=== Conda 及相关工具安装完成 ==="
