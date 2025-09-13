#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="${RECIPE_DIR}/../debs"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
shopt -s nullglob
debs=( "$DEB_DIR"/*.deb )
if ! compgen -G "$DEB_DIR"/*.deb > /dev/null; then echo "[ERROR] no .deb in $DEB_DIR"; exit 1; fi
for f in "${debs[@]}"; do dpkg-deb -x "$f" "$work"; done

# 统一 copy 函数（不依赖 rsync）
copy_tree(){ local src="$1" dst="$2"; mkdir -p "$dst"; (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -); }

# 通用：把 usr/{bin,lib,include,share} 拷到 $PREFIX
[ -d "$work/usr/bin" ]     && copy_tree "$work/usr/bin"     "$PREFIX/bin"
[ -d "$work/usr/lib" ]     && copy_tree "$work/usr/lib"     "$PREFIX/lib"
[ -d "$work/usr/include" ] && copy_tree "$work/usr/include" "$PREFIX/include"
[ -d "$work/usr/share" ]   && copy_tree "$work/usr/share"   "$PREFIX/share"

# 若是多架构目录（如 */lib/riscv64-linux-gnu/），为顶层 $PREFIX/lib 创建软链，
# 以符合 conda 生态常见布局并便于消费者查找。
for archdir in "$PREFIX/lib"/*-linux-gnu; do
  [ -d "$archdir" ] || continue
  for so in "$archdir"/*.so*; do
    [ -e "$so" ] || continue
    base="$(basename "$so")"
    # 仅在顶层不存在同名文件/软链时创建
    if [ ! -e "$PREFIX/lib/$base" ]; then
      ln -s "$(basename "$archdir")/$base" "$PREFIX/lib/$base"
    fi
  done
done

# 清理：移除属于其他包的 SONAME，避免与独立包发生 clobber（例如 libgfortran）。
if [ "libx11" != "file" ]; then
  rm -f "$PREFIX/lib/libX11.so.6" "$PREFIX/lib"/libX11.so.6.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libX11.so.6" "$archdir"/libX11.so.6.* 2>/dev/null || true
  done
fi
if [ "libgfortran" != "file" ]; then
  rm -f "$PREFIX/lib/libgfortran.so.5" "$PREFIX/lib"/libgfortran.so.5.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libgfortran.so.5" "$archdir"/libgfortran.so.5.* 2>/dev/null || true
  done
fi
if [ "openblas" != "file" ]; then
  rm -f "$PREFIX/lib/libopenblas.so.0" "$PREFIX/lib"/libopenblas.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libopenblas.so.0" "$archdir"/libopenblas.so.0.* 2>/dev/null || true
  done
fi
if [ "libquadmath" != "file" ]; then
  rm -f "$PREFIX/lib/libquadmath.so.0" "$PREFIX/lib"/libquadmath.so.0.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libquadmath.so.0" "$archdir"/libquadmath.so.0.* 2>/dev/null || true
  done
fi
if [ "openblas" != "file" ]; then
  rm -f "$PREFIX/lib/libblas.so.3" "$PREFIX/lib"/libblas.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libblas.so.3" "$archdir"/libblas.so.3.* 2>/dev/null || true
  done
fi
if [ "openblas" != "file" ]; then
  rm -f "$PREFIX/lib/liblapack.so.3" "$PREFIX/lib"/liblapack.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/liblapack.so.3" "$archdir"/liblapack.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "file" ]; then
  rm -f "$PREFIX/lib/libssl.so.3" "$PREFIX/lib"/libssl.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libssl.so.3" "$archdir"/libssl.so.3.* 2>/dev/null || true
  done
fi
if [ "openssl" != "file" ]; then
  rm -f "$PREFIX/lib/libcrypto.so.3" "$PREFIX/lib"/libcrypto.so.3.* 2>/dev/null || true
  for archdir in "$PREFIX/lib"/*-linux-gnu; do
    [ -d "$archdir" ] || continue
    rm -f "$archdir/libcrypto.so.3" "$archdir"/libcrypto.so.3.* 2>/dev/null || true
  done
fi

# activate：最小化修改，仅导出 $CONDA_PREFIX/lib 到 LD_LIBRARY_PATH
mkdir -p "$PREFIX/etc/conda/activate.d" "$PREFIX/etc/conda/deactivate.d"
cat > "$PREFIX/etc/conda/activate.d/file_activate.sh" <<'ACT'
if [ "${LD_LIBRARY_PATH+x}" = x ]; then export _OLD_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"; fi
case ":${LD_LIBRARY_PATH:-}:" in *":$CONDA_PREFIX/lib:"*) : ;; *) export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";; esac
ACT
cat > "$PREFIX/etc/conda/deactivate.d/file_deactivate.sh" <<'DEACT'
if [ "${_OLD_LD_LIBRARY_PATH+x}" = x ]; then export LD_LIBRARY_PATH="$_OLD_LD_LIBRARY_PATH"; else unset LD_LIBRARY_PATH; fi
unset _OLD_LD_LIBRARY_PATH
DEACT
chmod +x "$PREFIX"/etc/conda/{activate.d,deactivate.d}/*

echo "[INFO] file done."


