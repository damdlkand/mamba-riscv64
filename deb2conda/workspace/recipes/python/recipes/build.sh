#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="${RECIPE_DIR}/../debs"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
shopt -s nullglob
debs=( "$DEB_DIR"/*.deb )
(( ${#debs[@]} )) || { echo "[ERROR] no .deb in $DEB_DIR"; exit 1; }
for f in "${debs[@]}"; do dpkg-deb -x "$f" "$work"; done

# 统一 copy 函数（不依赖 rsync）
copy_tree(){ local src="$1" dst="$2"; mkdir -p "$dst"; (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -); }


# Python 主体 + stdlib + lib-dynload
PY="3.9"
copy_tree "$work/usr/bin" "$PREFIX/bin"
[ -d "$work/usr/include" ] && copy_tree "$work/usr/include" "$PREFIX/include"
[ -d "$work/usr/lib/python$PY" ] && copy_tree "$work/usr/lib/python$PY" "$PREFIX/lib/python$PY"

# 兼容多架构路径：/usr/lib/*-linux-gnu/python$PY 与其中的 lib-dynload
arch_py_dir="$(find "$work/usr/lib" -maxdepth 2 -type d -path "*/lib/*-linux-gnu/python$PY" | head -n1 || true)"
if [ -n "$arch_py_dir" ]; then
  copy_tree "$arch_py_dir" "$PREFIX/lib/python$PY"
fi

# 保证存在一个最小的 sitecustomize.py，conda 创建环境时会引用该文件
mkdir -p "$PREFIX/lib/python$PY" "$PREFIX/lib/python$PY/lib-dynload"
if [ ! -f "$PREFIX/lib/python$PY/sitecustomize.py" ]; then
  install -m 0644 -D /dev/null "$PREFIX/lib/python$PY/sitecustomize.py"
  cat > "$PREFIX/lib/python$PY/sitecustomize.py" <<'PYSC'
# Minimal sitecustomize for deb2conda-wrapped Python.
# Intentionally empty to satisfy conda environment initialization.
PYSC
fi
# 确保 _ssl/_hashlib
dyn="$PREFIX/lib/python$PY/lib-dynload"
mkdir -p "$dyn"
for m in _ssl _hashlib; do
  if ! ls "$dyn/${m}.cpython-39-*.so" >/dev/null 2>&1; then
    # 优先标准路径
    so="$(find "$work" -type f -path "*/lib/python$PY/lib-dynload/${m}.cpython-39-*.so" | head -n1 || true)"
    # 兼容多架构路径 /usr/lib/*-linux-gnu/python$PY/
    if [ -z "$so" ]; then
      so="$(find "$work" -type f -path "*/lib/*-linux-gnu/python$PY/${m}.cpython-39-*.so" | head -n1 || true)"
    fi
    # 放宽匹配（某些发行版命名差异）
    if [ -z "$so" ]; then
      so="$(find "$work" -type f -name "${m}.cpython-*.so" | head -n1 || true)"
    fi
    if [ -z "$so" ]; then
      so="$(find "$work" -type f -name "${m}*.so" | head -n1 || true)"
    fi
    [ -n "$so" ] && install -m 0755 -D "$so" "$dyn/$(basename "$so")" || { echo "[ERROR] missing $m"; find "$work" -type f -name "${m}*" | head -n 50; exit 1; }
  fi
done



# 软链（openblas 提供兼容 BLAS/LAPACK）

# 清理：移除属于其他包的 SONAME，避免与独立包发生 clobber（例如 libgfortran）。
if [ "libx11" != "python" ]; then
  rm -f "$PREFIX/lib/libX11.so.6" "$PREFIX/lib"/libX11.so.6.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libX11.so.6" "$archdir"/libX11.so.6.* 2>/dev/null || true
  done
fi
if [ "libgfortran" != "python" ]; then
  rm -f "$PREFIX/lib/libgfortran.so.5" "$PREFIX/lib"/libgfortran.so.5.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libgfortran.so.5" "$archdir"/libgfortran.so.5.* 2>/dev/null || true
  done
fi
if [ "openblas" != "python" ]; then
  rm -f "$PREFIX/lib/libopenblas.so.0" "$PREFIX/lib"/libopenblas.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libopenblas.so.0" "$archdir"/libopenblas.so.0.* 2>/dev/null || true
  done
fi
if [ "libquadmath" != "python" ]; then
  rm -f "$PREFIX/lib/libquadmath.so.0" "$PREFIX/lib"/libquadmath.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libquadmath.so.0" "$archdir"/libquadmath.so.0.* 2>/dev/null || true
  done
fi
if [ "openblas" != "python" ]; then
  rm -f "$PREFIX/lib/libblas.so.3" "$PREFIX/lib"/libblas.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libblas.so.3" "$archdir"/libblas.so.3.* 2>/dev/null || true
  done
fi
if [ "openblas" != "python" ]; then
  rm -f "$PREFIX/lib/liblapack.so.3" "$PREFIX/lib"/liblapack.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/liblapack.so.3" "$archdir"/liblapack.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "python" ]; then
  rm -f "$PREFIX/lib/libssl.so.3" "$PREFIX/lib"/libssl.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libssl.so.3" "$archdir"/libssl.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "python" ]; then
  rm -f "$PREFIX/lib/libcrypto.so.3" "$PREFIX/lib"/libcrypto.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libcrypto.so.3" "$archdir"/libcrypto.so.3.* 2>/dev/null || true
  done
fi
if [ "libxxhash" != "python" ]; then
  rm -f "$PREFIX/lib/libxxhash.so.0" "$PREFIX/lib"/libxxhash.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libxxhash.so.0" "$archdir"/libxxhash.so.0.* 2>/dev/null || true
  done
fi

# activate：最小化修改，仅导出 $CONDA_PREFIX/lib 到 LD_LIBRARY_PATH
mkdir -p "$PREFIX/etc/conda/activate.d" "$PREFIX/etc/conda/deactivate.d"
cat > "$PREFIX/etc/conda/activate.d/python_activate.sh" <<'ACT'
if [ "${LD_LIBRARY_PATH+x}" = x ]; then export _OLD_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"; fi
case ":${LD_LIBRARY_PATH:-}:" in *":$CONDA_PREFIX/lib:"*) : ;; *) export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
ACT
cat > "$PREFIX/etc/conda/deactivate.d/python_deactivate.sh" <<'DEACT'
if [ "${_OLD_LD_LIBRARY_PATH+x}" = x ]; then export LD_LIBRARY_PATH="$_OLD_LD_LIBRARY_PATH"; else unset LD_LIBRARY_PATH; fi
unset _OLD_LD_LIBRARY_PATH
DEACT
chmod +x "$PREFIX"/etc/conda/{activate.d,deactivate.d}/*

echo "[INFO] python done."

