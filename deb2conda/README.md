## deb2conda 配置与使用指南（manifest.yaml / rules.yaml）

本项目把一组 Debian/Ubuntu 的 .deb 包包装为可在 conda 频道中分发的包。配置分为两部分：
- manifest.yaml：声明要生成的目标包及其来源 .deb 与基本属性
- rules.yaml：提供全局映射与测试片段，辅助自动推导依赖

下面逐项说明字段语义与用法，并给出推荐工作流程。

### 一、manifest.yaml

- channel_root: 本地 conda 频道根目录（auto_build.sh 会对该目录 `conda index`）。

- packages: 列表，声明要生成的包。每个元素支持：
  - name: 生成的 conda 包名（字符串，必填）
  - version: 直接指定写入 meta.yaml 的版本（字符串，可选；优先级最高）
  - debs: 该包来源的 .deb 文件名（或通配，数组，必填）。例如：
    - `libx11-6_*riscv64.deb`
    - `python3-scipy_*riscv64.deb`
  - kind: 包类型（必填）
    - `lib`/`bin`/`data`：系统库/可执行/纯数据；模板会把 `usr/{bin,lib,include,share}` 拷入 `$PREFIX`
    - `python_core`：Python 主包（pythonX.Y、stdlib、lib-dynload）
    - `python_ext`：Python 扩展（例如 numpy、scipy、python-tk）
  - build_number: 构建号（整数，可选，默认 0）
  - missing_dso: 允许缺失的 DSO 白名单（数组，可选）
  - extras: 扩展配置（对象，可选）：
    - needs: 额外运行依赖（数组），会合并进 `requirements.run`
    - ensure_modules: 生成导入测试的模块名（数组），如 `["scipy"]`
    - pyver / pyabi: 覆盖 Python 版本与 ABI（字符串），用于 `python_*` 包。例如 `pyver: "3.11"`, `pyabi: "311"`
    - blas_alias / lapack_alias: 对 openblas 包启用兼容软链（在 `$PREFIX/lib` 建立 `libblas.so.3`/`liblapack.so.3`）
    - version: 明确写入的版本字符串（可选，不写则默认 "0"）
    - skip_auto: 从自动推导的依赖中排除的包名（数组），例如 `["libquadmath"]`

示例：
```yaml
channel_root: /workspace/local-conda-channel/

packages:
  - name: libx11
    debs: [ libx11-6_*riscv64.deb ]
    kind: lib

  - name: libgfortran
    debs: [ libgfortran5_*riscv64.deb ]
    kind: lib

  - name: numpy
    version: "1.24.2"
    debs: [ python3-numpy_*riscv64.deb ]
    kind: python_ext
    extras: { pyver: "3.11", pyabi: "311", needs: [openblas, libgfortran], ensure_modules: [numpy] }

  - name: scipy
    debs: [ python3-scipy_*riscv64.deb ]
    kind: python_ext
    extras: { pyver: "3.11", pyabi: "311", needs: [numpy, openblas, libgfortran], ensure_modules: [scipy] }

  # 带 urls 的示例：当 --deb-src 下找不到匹配的 .deb 时，生成器会按顺序尝试下载这些 url
  #（下载文件会保存到你提供的 --deb-src 目录中，文件名取自 URL 路径的 basename），
  # 下载成功并通过 dpkg-deb 校验后，会再次从 --deb-src 复制到 workspace/recipes/<name>/debs/。
  - name: jq
    version: "1.7.1"
    debs: [ jq_*riscv64.deb ]
    kind: bin
    urls:
      - https://deb.debian.org/debian/pool/main/j/jq/jq_1.7.1-6+deb13u1_riscv64.deb
      - http://ftp.debian.org/debian/pool/main/j/jq/jq_1.7.1-6+deb13u1_riscv64.deb
```

### 二、rules.yaml

- map_run_deps: DSO → conda 包名 映射（全局）。生成器会在解包后扫描 ELF 的 NEEDED，
  将发现的 SONAME（如 `libopenblas.so.0`）映射为运行依赖写入 `requirements.run`。

- python_site_requires: 针对 `kind: python_ext` 的追加依赖（Python 生态层面），例如 `scipy -> numpy`。

- test_snippets: 测试命令模板。`extras.ensure_modules` 会使用 `import_only` 模板生成导入测试。

示例：
```yaml
map_run_deps:
  libX11.so.6:       "libx11"
  libgfortran.so.5:  "libgfortran"
  libquadmath.so.0:  "libquadmath"
  libopenblas.so.0:  "openblas"
  libblas.so.3:      "openblas"
  liblapack.so.3:    "openblas"

python_site_requires:
  scipy: ["numpy"]
  numpy: ["openblas","libgfortran"]

test_snippets:
  import_only: "python -c \"import {module}; print('OK')\""
```

### 三、依赖合并规则（requirements.run）

最终写入 `meta.yaml -> requirements.run` 的依赖由以下来源合并去重：
1) manifest.extras.needs（手动声明）
2) rules.python_site_requires[包名]（Python 层）
3) DSO 自动扫描（readelf 解析 NEEDED + rules.map_run_deps 映射）
4) 可选从自动结果中排除：manifest.extras.skip_auto

注意：求解器（conda/libmamba）只负责“解版本”，不会“猜依赖”。依赖项需要由上述 1-3 步写入。

重要注意（自依赖与误判排除）：
- 生成器在写 `requirements.run` 时会自动过滤“自依赖”（包名等于自身的依赖项会被丢弃），避免出现 “package cannot depend on itself”。
- 若 DSO 扫描误判出某些依赖（例如把自身或不需要的库扫描进来），可以在该包的 `manifest.yaml` 条目配置排除列表：
  ```yaml
  extras:
    skip_auto: [ openssl, zlib ]  # 示例：按需填写要排除的自动推导依赖名
  ```

### 四、生成与构建流程

准备：把所有待转换的 `.deb` 放在项目根目录的 `allDebs/` 目录（或任意你指定的目录）。生成/构建时通过 `--deb-src allDebs` 让生成器自动把匹配到的 `.deb` 复制到 `workspace/recipes/<name>/debs/`。

1) 生成 recipes（同时从 `--deb-src` 复制 .deb）：
```
python tools/debwrap.py gen --manifest manifest.yaml --rules rules.yaml --deb-src allDebs
```
会在 `workspace/recipes/<name>/{debs,recipes}` 下生成 `meta.yaml` 和 `build.sh`。

提示（urls 自动下载）：
- 若 `--deb-src` 目录缺少某包 `debs:` 指定的文件，生成器会读取该包的 `urls`（或 `extras.urls`），按顺序下载（最多重试 4 次），保存到 `--deb-src` 目录，然后再从 `--deb-src` 复制到对应包的 `debs/`。
- 未提供 `--deb-src` 时不会启用自动下载。

2) 构建（增量跳过、可 `--force` 强制）：
```
./auto_build.sh --deb-src allDebs [--force]
```
脚本会：
- 调用生成器；
- 仅对签名变化的包执行 `conda-build`；
- 使用 `manifest.channel_root` 作为唯一频道（`--override-channels -c file://...`）；
- 构建后 `conda index` 更新频道索引。

依赖与顺序（重要）：
- 在 `manifest.yaml` 里，请将“被依赖的包”放在“依赖它的包”之前。例如先列 `libonig`、`libjq`，再列 `jq`。
- 构建时，测试环境仅从本地频道解析依赖；因此依赖包必须先被构建并写入频道索引，求解器才能安装到测试环境。
- `extras.needs` 只影响 `requirements.run`（依赖求解），不会把依赖的 `.deb` 复制到当前包目录。要打出依赖包，请在 `packages:` 中为依赖单独建条目并提供其 `debs:` 或 `urls`。

推荐排序规则（强烈建议遵守）：
1) 基础库（lib）优先：放在列表最前，包括常见运行库与数值/压缩库
   - 例如：`libstdcxx`, `libgcc`, `libgomp`, `libgfortran`, `openblas`, `zlib`, `libzstd`, `libgmp`, `libmpfr`, `libmpc`, `libisl`, `openssl`, `libxxhash`, `libmagic`, `libjq`, `libonig` 等
2) 工具链与工具（bin）：其次
   - 例如：`binutils`, `gcc`/`g++`, `make`, `cmake`, `file`, `jq`
3) 语言运行时与扩展：其后
   - 例如：`python`（`kind: python_core`）→ `numpy`/`scipy` 等 `python_ext`
4) 应用与数据包（bin/data）：最后

这样安排可以避免“先构建依赖者时频道里还没有依赖包”导致的求解失败。

### 五、模板行为要点

- templates/meta.yaml.j2：
  - 固定写入 `build: binary_relocation: False` 与 `script_env: [LD_LIBRARY_PATH, LD_PRELOAD]`
  - 仅在有内容时生成 `requirements.run`；
  - `test.commands` 根据 `ensure_modules` 与 DSO 结果生成（无则回退 `echo OK`）。
  - package.version 的来源优先级：manifest.package.version > manifest.extras.version > 从 deb 解析（dpkg/文件名，自动规范化）> 0。

- templates/build.lib.sh.j2（lib/bin/data）：
  - 复制 `usr/{bin,lib,include,share}` 到 `$PREFIX`；
  - 处理多架构目录（`$PREFIX/lib/*-linux-gnu`）到顶层 `$PREFIX/lib` 的软链。

- templates/build.sh.j2（python_core/python_ext）：
  - python_core：复制 pythonX.Y、stdlib、lib-dynload 并保证 `_ssl/_hashlib`；
  - python_ext：复制 `lib/python$PY/site-packages`，兼容 `lib/python3/dist-packages`；
  - 复制 `lib-dynload/*.so`；
  - 生成 activate/deactivate 脚本以管理 `LD_LIBRARY_PATH`。

### 六、常见问题

- 求解失败：提示缺某库或 Python 版本不匹配。
  - 检查频道路径是否与 `manifest.channel_root` 一致，且已 `conda index`；
  - 核对 `extras.pyver/pyabi` 与频道中 Python 版本是否匹配；
  - 对缺失的 SONAME 在 rules.map_run_deps 中补全映射，或将对应包加入 manifest。

- 测试导入失败（如 `import scipy`）：
  - 确认 numpy 已写入 `requirements.run`（来自 `python_site_requires` 或 `extras.needs`）；
  - 查看 `$PREFIX/lib/python$PY/site-packages` 是否包含实际文件（若 deb 安装到 `dist-packages`，模板会自动迁移）。

### 七、提示

- 你可以在包的 `extras.needs` 手工声明依赖；自动推导仅作为辅助。
- 若自动 DSO 推导产生多余依赖，可用 `extras.skip_auto` 排除。


