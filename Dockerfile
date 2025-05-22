# Dockerfile
FROM openkylin/openkylin

# 设置非交互式安装和时区
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# 添加 OpenKylin 软件源
RUN echo "deb [trusted=yes] http://factory.openkylin.top/kif/archive/get/repos/riscv_common_software nile main" > /etc/apt/sources.list.d/riscv-common.list && \
    echo "deb http://archive.build.openkylin.top/openkylin/ nile main cross pty" >> /etc/apt/sources.list && \
    echo "deb http://archive.build.openkylin.top/openkylin/ nile-security main cross pty" >> /etc/apt/sources.list && \
    echo "deb http://archive.build.openkylin.top/openkylin/ nile-updates main cross pty" >> /etc/apt/sources.list && \
    echo "deb http://archive.build.openkylin.top/openkylin/ nile-proposed main cross pty" >> /etc/apt/sources.list && \
    apt-get update && apt-get upgrade -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -y

# 安装构建依赖
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    ca-certificates \
    gcc-14 \
    g++-14 \
    python-is-python3 \
    python-dev-is-python3 \
    python3-dev \
    python3-pip \
    ninja-build \
    vim \
    libfmt-dev \
    libspdlog-dev \
    libexpat1-dev \
    bison \
    flex \
    pkg-config \
    libgdbm-dev \
    libnss3-dev \
    libsqlite3-dev \
    libreadline-dev \
    libffi-dev \
    tk-dev \
    uuid-dev \
    libbz2-dev \
    liblzma-dev \
    xz-utils \
    # 清理 apt 缓存
    # && apt-get clean \
    # && rm -rf /var/lib/apt/lists/* \
    # 设置 gcc 14 为默认版本
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 99 --slave /usr/bin/g++ g++ /usr/bin/g++-14 --slave /usr/bin/gcc-ar gcc-ar /usr/bin/gcc-ar-14 --slave /usr/bin/gcc-nm gcc-nm /usr/bin/gcc-nm-14 --slave /usr/bin/gcc-ranlib gcc-ranlib /usr/bin/gcc-ranlib-14 --slave /usr/bin/gcov gcov /usr/bin/gcov-14 --slave /usr/bin/gcov-dump gcov-dump /usr/bin/gcov-dump-14 --slave /usr/bin/gcov-tool gcov-tool /usr/bin/gcov-tool-14 --slave /usr/bin/lto-dump lto-dump /usr/bin/lto-dump-14

# 安装pathcelf
RUN wget https://launchpad.net/ubuntu/+archive/primary/+files/patchelf_0.18.0-1.4_riscv64.deb && \
    dpkg -i patchelf_0.18.0-1.4_riscv64.deb && \
    rm patchelf_0.18.0-1.4_riscv64.deb
# 安装rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path



# 设置工作目录，构建脚本将在这里执行
# 工具将安装到 /opt/conda_tools (由 build_env.sh 控制)
WORKDIR /opt/builder

# 复制构建脚本到镜像中
COPY build_dep.sh .

# 赋予脚本执行权限并运行脚本
# 脚本执行完毕后将其删除
RUN chmod +x ./build_dep.sh && \
    ./build_dep.sh && \
    rm ./build_dep.sh

COPY build_micromamba.sh .

# 赋予脚本执行权限并运行脚本
# 脚本执行完毕后将其删除
RUN chmod +x ./build_micromamba.sh && \
    ./build_micromamba.sh && \
    rm ./build_micromamba.sh

COPY build_python.sh .

# 赋予脚本执行权限并运行脚本
# 脚本执行完毕后将其删除
RUN chmod +x ./build_python.sh && \
    ./build_python.sh && \
    rm ./build_python.sh

#拷贝glibc_fix 文件夹
COPY glibc_fix .

#安装glibc_fix下的所有deb
RUN dpkg -i libc-bin_2.38-1ok6.10riscv1_riscv64.deb \
libc-dev-bin_2.38-1ok6.10riscv1_riscv64.deb \
libc-devtools_2.38-1ok6.10riscv1_riscv64.deb \
libc6-dbg_2.38-1ok6.10riscv1_riscv64.deb \
libc6-dev_2.38-1ok6.10riscv1_riscv64.deb  \
libc6-prof_2.38-1ok6.10riscv1_riscv64.deb \
libc6_2.38-1ok6.10riscv1_riscv64.deb \
locales-all_2.38-1ok6.10riscv1_riscv64.deb \
nscd_2.38-1ok6.10riscv1_riscv64.deb && rm *.deb

COPY build_conda.sh .

# 赋予脚本执行权限并运行脚本
# 脚本执行完毕后将其删除
RUN chmod +x ./build_conda.sh && \
    ./build_conda.sh && \
    rm ./build_conda.sh

# 设置 PATH 环境变量，以便可以直接使用安装的工具
# 这些路径与 build_env.sh 中定义的安装路径一致
ENV MICROMAMBA_INSTALL_DIR="/opt/conda_tools/micromamba"
ENV CONDA_ENV_DIR="/opt/conda_tools/env"
# 将 $HOME/.cargo/bin (即 /root/.cargo/bin) 添加到 PATH
ENV PATH="/root/.cargo/bin:${MICROMAMBA_INSTALL_DIR}/bin:${CONDA_ENV_DIR}/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/conda_static_deps/lib:${LD_LIBRARY_PATH}"

# 确保 ~/.bash_profile (如果存在并被登录 shell 读取) 会加载 ~/.bashrc。
# 大多数情况下，交互式 `docker run ... bash` 是非登录 shell，会直接读取 ~/.bashrc。
# 但为了更广泛的兼容性，添加此行是好的做法。
RUN echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.bash_profile

# ---------------------------------------------------------------------------
# Micromamba 初始化和激活设置
# ---------------------------------------------------------------------------

# 使用 /bin/bash -c 来执行 micromamba 初始化，避免 --login 可能带来的复杂性，
# 以确保 micromamba shell init 主要针对 ~/.bashrc进行修改。
SHELL ["/bin/bash", "-c"]

# 设置 MAMBA_ROOT_PREFIX 环境变量，micromamba shell init 可能会参考它。
# 并且在 init 命令中也明确指定 --root-prefix。
ENV MAMBA_ROOT_PREFIX=${MICROMAMBA_INSTALL_DIR}

# 初始化 micromamba。
# 根据 micromamba 运行时错误信息的提示，显式使用 --root-prefix 参数，
# 指向我们 micromamba 的实际安装目录。
RUN "${MICROMAMBA_INSTALL_DIR}/bin/micromamba" shell init --shell bash --root-prefix "${MICROMAMBA_INSTALL_DIR}"

# 将环境激活命令追加到 ~/.bashrc。
# 这应该在 micromamba shell init 已经配置好 shell hook 之后执行。
# 当 ~/.bashrc 被加载时，这个命令会被执行。
RUN echo "micromamba activate ${CONDA_ENV_DIR}" >> ~/.bashrc

# (可选，用于构建时调试) 输出 .bashrc 和 .bash_profile 的内容，检查是否正确生成。
# RUN echo "DEBUG: Contents of /root/.bashrc during build:" && \
#     cat /root/.bashrc && \
#     echo "DEBUG: --- End of /root/.bashrc ---"
# RUN echo "DEBUG: Contents of /root/.bash_profile during build:" && \
#     cat /root/.bash_profile && \
#     echo "DEBUG: --- End of /root/.bash_profile ---"

# 恢复您可能在 Dockerfile 后续部分需要的 SHELL 设置，
# 例如，如果您希望后续 RUN 命令在登录 shell 中运行。
# SHELL ["/bin/bash", "--login", "-c"]

# (可选) 设置容器启动时的默认命令。
# 如果设置了 CMD ["/bin/bash"] (或不设置 CMD，则默认为基础镜像的 CMD，通常是 shell)，
# 启动的 bash 会话应该会加载 ~/.bashrc 或 ~/.bash_profile。
# CMD ["/bin/bash"]