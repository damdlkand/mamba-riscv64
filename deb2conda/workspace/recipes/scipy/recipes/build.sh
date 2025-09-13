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



# Python 扩展（numpy / python-tk 等）
PY="3.12"
SP="$PREFIX/lib/python$PY/site-packages"
DY="$PREFIX/lib/python$PY/lib-dynload"
mkdir -p "$SP" "$DY"

# 复制 site-packages（版本专属路径）
if d="$(find "$work" -type d -path "*/lib/python$PY/site-packages" | head -n1)"; then
  copy_tree "$d" "$SP"
fi

# 兼容 Debian 的 /usr/lib/python3/dist-packages：将内容整体拷入 site-packages
if d3="$(find "$work" -type d -path "*/lib/python3/dist-packages" | head -n1)"; then
  copy_tree "$d3" "$SP"
fi

# 兼容 /usr/lib/python$PY/dist-packages：将内容整体拷入 site-packages
if d4="$(find "$work" -type d -path "*/lib/python$PY/dist-packages" | head -n1)"; then
  copy_tree "$d4" "$SP"
fi

# 兜底：若上面未命中，直接查找任何 pythonX.Y 的 (site|dist)-packages/scipy 并复制其上级目录
if ! ls "$SP/scipy" >/dev/null 2>&1; then
  while IFS= read -r pkgdir; do
    copy_tree "$pkgdir" "$SP"
  done < <(find "$work" -type d -regex ".*/lib/python[0-9]+\.[0-9]+/(site|dist)-packages/scipy" -print 2>/dev/null | sed 's|/scipy$||' | sort -u)
fi

# 若仍被放进了错误版本的 pythonX.Y 目录，重定位到目标 $PY 目录（含元数据目录）
for d in $(find "$PREFIX/lib" -maxdepth 3 -type d -regex ".*/lib/python[0-9]+\.[0-9]+/(site|dist)-packages" 2>/dev/null | grep -v "/python$PY/"); do
  # 主包目录
  if [ -d "$d/scipy" ]; then
    copy_tree "$d/scipy" "$SP/scipy"
    rm -rf "$d/scipy"
  fi
  # 相关的 dist-info/egg-info 元数据目录（多版本共存时关键）
  for meta in "$d"/scipy-*.dist-info "$d"/scipy-*.egg-info "$d"/scipy.dist-info "$d"/scipy.egg-info; do
    [ -e "$meta" ] || continue
    base="$(basename "$meta")"
    mkdir -p "$SP/$base"
    copy_tree "$meta" "$SP/$base"
    rm -rf "$meta"
  done
done

# 复制 lib-dynload/*.so（如 _tkinter）
for so in $(find "$work" -type f -path "*/lib/python$PY/lib-dynload/*.so" 2>/dev/null || true); do
  install -m 0755 -D "$so" "$DY/$(basename "$so")"
done

# 兼容部分发行版的 dist-packages/<pkg> 直挂目录
if d2="$(find "$work" -type d -path "*/dist-packages/*" | head -n1)"; then
  copy_tree "$(dirname "$d2")" "$SP"
fi

# 软链（openblas 提供兼容 BLAS/LAPACK）

# 清理：移除属于其他包的 SONAME，避免与独立包发生 clobber（例如 libgfortran）。
if [ "libx11" != "scipy" ]; then
  rm -f "$PREFIX/lib/libX11.so.6" "$PREFIX/lib"/libX11.so.6.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libX11.so.6" "$archdir"/libX11.so.6.* 2>/dev/null || true
  done
fi
if [ "libgfortran" != "scipy" ]; then
  rm -f "$PREFIX/lib/libgfortran.so.5" "$PREFIX/lib"/libgfortran.so.5.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libgfortran.so.5" "$archdir"/libgfortran.so.5.* 2>/dev/null || true
  done
fi
if [ "openblas" != "scipy" ]; then
  rm -f "$PREFIX/lib/libopenblas.so.0" "$PREFIX/lib"/libopenblas.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libopenblas.so.0" "$archdir"/libopenblas.so.0.* 2>/dev/null || true
  done
fi
if [ "libquadmath" != "scipy" ]; then
  rm -f "$PREFIX/lib/libquadmath.so.0" "$PREFIX/lib"/libquadmath.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libquadmath.so.0" "$archdir"/libquadmath.so.0.* 2>/dev/null || true
  done
fi
if [ "openblas" != "scipy" ]; then
  rm -f "$PREFIX/lib/libblas.so.3" "$PREFIX/lib"/libblas.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libblas.so.3" "$archdir"/libblas.so.3.* 2>/dev/null || true
  done
fi
if [ "openblas" != "scipy" ]; then
  rm -f "$PREFIX/lib/liblapack.so.3" "$PREFIX/lib"/liblapack.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/liblapack.so.3" "$archdir"/liblapack.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "scipy" ]; then
  rm -f "$PREFIX/lib/libssl.so.3" "$PREFIX/lib"/libssl.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libssl.so.3" "$archdir"/libssl.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "scipy" ]; then
  rm -f "$PREFIX/lib/libcrypto.so.3" "$PREFIX/lib"/libcrypto.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libcrypto.so.3" "$archdir"/libcrypto.so.3.* 2>/dev/null || true
  done
fi
if [ "libxxhash" != "scipy" ]; then
  rm -f "$PREFIX/lib/libxxhash.so.0" "$PREFIX/lib"/libxxhash.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libxxhash.so.0" "$archdir"/libxxhash.so.0.* 2>/dev/null || true
  done
fi

# activate：最小化修改，仅导出 $CONDA_PREFIX/lib 到 LD_LIBRARY_PATH
mkdir -p "$PREFIX/etc/conda/activate.d" "$PREFIX/etc/conda/deactivate.d"
cat > "$PREFIX/etc/conda/activate.d/scipy_activate.sh" <<'ACT'
if [ "${LD_LIBRARY_PATH+x}" = x ]; then export _OLD_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"; fi
case ":${LD_LIBRARY_PATH:-}:" in *":$CONDA_PREFIX/lib:"*) : ;; *) export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
ACT
cat > "$PREFIX/etc/conda/deactivate.d/scipy_deactivate.sh" <<'DEACT'
if [ "${_OLD_LD_LIBRARY_PATH+x}" = x ]; then export LD_LIBRARY_PATH="$_OLD_LD_LIBRARY_PATH"; else unset LD_LIBRARY_PATH; fi
unset _OLD_LD_LIBRARY_PATH
DEACT
chmod +x "$PREFIX"/etc/conda/{activate.d,deactivate.d}/*

echo "[INFO] scipy done."

