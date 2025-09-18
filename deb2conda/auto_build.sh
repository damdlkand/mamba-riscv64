#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PYTHONUNBUFFERED=1

# Parse optional flags
DEB_SRC=""
FORCE=0
while [[ ${1:-} ]]; do
  case "$1" in
    --deb-src)
      DEB_SRC="${2:-}"
      shift 2 ;;
    --force)
      FORCE=1
      shift ;;
    *)
      echo "Usage: $0 [--deb-src DIR] [--force]" >&2
      exit 2 ;;
  esac
done

# 1) Generate recipes (optionally copy debs from --deb-src)
if [[ -n "$DEB_SRC" ]]; then
  python "$ROOT/tools/debwrap.py" gen --manifest "$ROOT/manifest.yaml" --rules "$ROOT/rules.yaml" --deb-src "$DEB_SRC"
else
  python "$ROOT/tools/debwrap.py" gen --manifest "$ROOT/manifest.yaml" --rules "$ROOT/rules.yaml"
fi

# Helpers to read YAML via python (avoid yq dependency)
read_pkg_names() {
  python - "$ROOT/manifest.yaml" <<'PY'
import sys,yaml
m=yaml.safe_load(open(sys.argv[1])) or {}
for p in m.get('packages',[]) or []:
    n=p.get('name')
    if n: print(n)
PY
}

read_channel_root() {
  python - "$ROOT/manifest.yaml" <<'PY'
import sys,yaml
m=yaml.safe_load(open(sys.argv[1])) or {}
print(m.get('channel_root','/workspace/local-conda-channel/'))
PY
}
# Snapshot current channel artifacts before build (for diff later)
CHANNEL_ROOT_PRE="$(read_channel_root)"
TMP_BEFORE="$(mktemp)"
find "$CHANNEL_ROOT_PRE" -type f \( -name '*.conda' -o -name '*.tar.bz2' \) | sort > "$TMP_BEFORE"

calc_sig() {
  local pkg="$1"
  local base
  base="$(resolve_base_dir "$pkg")"
  local rec="$base/recipes"
  local deb="$base/debs"
  {
    sha256sum "$rec/meta.yaml" "$rec/build.sh" 2>/dev/null || true
    if compgen -G "$deb"/*.deb > /dev/null; then sha256sum "$deb"/*.deb; fi
  } | sha256sum | awk '{print $1}'
}

# Resolve workspace directory for a package name, supporting version-suffixed dirs (<name>-<ver>)
resolve_base_dir() {
  local pkg="$1"
  local base="$ROOT/workspace/recipes"
  if [ -d "$base/$pkg/recipes" ]; then
    echo "$base/$pkg"
    return
  fi
  # Pick the newest recipes dir among <name>-*/recipes if multiple exist
  local newest
  newest="$(ls -1dt "$base/$pkg"-*/recipes 2>/dev/null | head -n1 || true)"
  if [ -n "$newest" ]; then
    dirname "$newest"
    return
  fi
  # Fallback to non-suffixed
  echo "$base/$pkg"
}

# 2) Build changed packages only
while read -r pkg; do
  [[ -z "$pkg" ]] && continue
  echo "===> evaluate $pkg"
  basedir="$(resolve_base_dir "$pkg")"
  recdir="$basedir/recipes"
  sigfile="$basedir/.build_sig"
  newsig="$(calc_sig "$pkg")"
  CHANNEL_ROOT="$(read_channel_root)"
  # Predict output filename
  expected_base="$( cd "$recdir" && conda-build --output . | xargs -n1 basename | tail -n1 )"
  # Resolve package name prefix for broader channel presence check (name-version-build.ext)
  pkg_name_prefix=""
  if [[ -n "$expected_base" ]]; then
    pkg_name_prefix="${expected_base%%-*}"
  fi
  channel_has_any_pkg=0
  if [[ -n "$pkg_name_prefix" ]]; then
    if find "$CHANNEL_ROOT" -type f \( -name "${pkg_name_prefix}-*.conda" -o -name "${pkg_name_prefix}-*.tar.bz2" \) -print -quit | grep -q .; then
      channel_has_any_pkg=1
    fi
  fi
  exact_artifact_exists=0
  if [[ -n "$expected_base" ]] && find "$CHANNEL_ROOT" -type f -name "$expected_base" -print -quit | grep -q .; then
    exact_artifact_exists=1
  fi
  # Build decision matrix:
  # - If channel has no package with this name -> build
  # - Else if exact artifact exists AND signature unchanged -> skip
  # - Else -> build
  if [[ $FORCE -eq 0 ]]; then
    if [[ $channel_has_any_pkg -eq 0 ]]; then
      echo "===> channel missing $pkg; will build"
    elif [[ $exact_artifact_exists -eq 1 && -f "$sigfile" && "$(cat "$sigfile")" == "$newsig" ]]; then
      echo "===> skip $pkg (no changes and artifact already present)"
      continue
    fi
  fi
  echo "===> build $pkg"
  ( cd "$recdir" \
    && conda-build . --override-channels -c file://"$CHANNEL_ROOT" --output-folder "${CHANNEL_ROOT}" )
  echo "$newsig" > "$sigfile"
done < <(read_pkg_names)

# 3) Index channel
CHANNEL_ROOT="$(read_channel_root)"
conda index "$CHANNEL_ROOT"

# Show local channel contents via conda search (override other channels)
echo "===> Local channel packages (conda search)"
conda search --override-channels -c file://"$CHANNEL_ROOT" "*" | cat || true

# Diff: show newly added artifacts
TMP_AFTER="$(mktemp)"
find "$CHANNEL_ROOT" -type f \( -name '*.conda' -o -name '*.tar.bz2' \) | sort > "$TMP_AFTER"
echo "===> New artifacts added in this run:"
NEW_LIST="$(mktemp)"
comm -13 "$TMP_BEFORE" "$TMP_AFTER" | tee "$NEW_LIST" || true
NEW_COUNT="$(wc -l < "$NEW_LIST" | tr -d ' ')"
echo "===> Added count: ${NEW_COUNT}"

echo "All done."

