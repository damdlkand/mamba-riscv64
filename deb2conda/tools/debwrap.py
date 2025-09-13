#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Generate conda-build recipes from Debian package manifest/rules.

Usage:
  python tools/debwrap.py gen --manifest manifest.yaml --rules rules.yaml

Outputs per package under workspace/recipes/<name>/:
  - debs/           (put matching .deb files here)
  - recipes/
      - meta.yaml
      - build.sh
"""

import argparse
import os
import re
import sys
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Tuple, Optional
from urllib.parse import urlparse
import urllib.request
import time

try:
    import yaml  # type: ignore
except Exception as exc:  # pragma: no cover
    print("[ERROR] Missing dependency pyyaml. pip install pyyaml", file=sys.stderr)
    raise

try:
    from jinja2 import Environment, FileSystemLoader  # type: ignore
except Exception as exc:  # pragma: no cover
    print("[ERROR] Missing dependency jinja2. pip install jinja2", file=sys.stderr)
    raise

#假设脚本在 repo/tools/debwrap.py，则 REPO_ROOT = repo/。
REPO_ROOT = Path(__file__).resolve().parents[1]
TEMPLATES_DIR = REPO_ROOT / "templates"
WORKSPACE_DIR = REPO_ROOT / "workspace" / "recipes"

#读取 YAML 并返回字典；or {} 保险空文件时不崩。 示例：manifest = read_yaml(Path("manifest.yaml"))
def read_yaml(path: Path) -> Dict[str, Any]:
    """Read YAML with robust decoding.
    Tries UTF-8 (with BOM), then falls back to latin-1 while ignoring invalid bytes.
    """
    try:
        with path.open("r", encoding="utf-8-sig") as f:
            return yaml.safe_load(f) or {}
    except UnicodeDecodeError:
        with path.open("r", encoding="latin-1", errors="ignore") as f:
            return yaml.safe_load(f) or {}

#确保目录存在；示例：ensure_dir(Path("workspace/recipes")) 递归建目录，若已存在不报错
def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)

#从 manifest 推断 Python 版本/ABI
#packages:
#  - name: python
#    kind: python_core
#    debs:
#      - python3.11-minimal
#      - python3.11-dev
#则返回 ("3.11", "311")。如果写：
#extras: { pyver: "3.10", pyabi: "310" }

#则返回被覆盖的 ("3.10", "310")。
def detect_python_version_from_manifest(manifest: Dict[str, Any]) -> Tuple[str, str]:
    """Detect python version (e.g. 3.12) and abi (e.g. 312) from the python core entry.
    Fallback to 3.12/312 if not detectable.
    """
    packages: List[Dict[str, Any]] = manifest.get("packages", []) or []
    pyver = "3.12"
    pyabi = "312"
    for entry in packages:
        if entry.get("kind") == "python_core":
            # Try to parse from deb patterns like python3.12-*
            debs: List[str] = entry.get("debs", []) or []
            joined = " ".join(debs)
            m = re.search(r"python3\.(\d+)", joined)
            if m:
                minor = m.group(1)
                pyver = f"3.{minor}"
                pyabi = f"3{minor}"
            # Allow explicit override via extras
            extras = entry.get("extras", {}) or {}
            if isinstance(extras.get("pyver"), str):
                pyver = extras["pyver"]
            if isinstance(extras.get("pyabi"), str):
                pyabi = extras["pyabi"]
            break
    return pyver, pyabi

# manifest.yaml 中的某个包
#extras:
#  needs: [ "numpy >=1.26", "scipy" ]

# rules.yaml
#python_site_requires:
#  myext: [ "cython", "numpy" ]
#对 name: myext 来说，最终 run_deps = ["numpy >=1.26", "scipy", "cython", "numpy"] 去重后
# ["numpy >=1.26", "scipy", "cython", "numpy"]（注意去重保序，会保留第一个 "numpy >=1.26"，
#后续的 "numpy" 与之不同，会一起保留——如果想更智能合并版本约束，可以在这里加规则）。

def compute_run_deps(pkg: Dict[str, Any], rules: Dict[str, Any], auto_run_deps: Optional[List[str]] = None) -> List[str]:
    run_deps: List[str] = []

    # Allow extras.needs to directly specify run deps
    extras = pkg.get("extras", {}) or {}
    needs = extras.get("needs", []) or []
    if isinstance(needs, list):
        run_deps.extend([str(x) for x in needs])

    # If python_ext, consider python_site_requires overrides by package name
    if pkg.get("kind") == "python_ext":
        site_requires = rules.get("python_site_requires", {}) or {}
        reqs = site_requires.get(pkg.get("name"), []) or []
        run_deps.extend([str(x) for x in reqs])

    # Auto derived dependencies from DSO scanning (if provided)
    if auto_run_deps:
        run_deps.extend([str(x) for x in auto_run_deps])

    # Dedupe while keeping order
    seen = set()
    unique: List[str] = []
    for r in run_deps:
        if r not in seen:
            unique.append(r)
            seen.add(r)
    return unique

# manifest
#extras:
#  ensure_modules: [ "cv2", "numpy" ]

# rules
#test_snippets:
#  import_only: "python -c \"import {module}\""
#则生成两条命令：

#python -c "import cv2"

#python -c "import numpy"
def compute_test_cmds(pkg: Dict[str, Any], rules: Dict[str, Any]) -> List[str]:
    cmds: List[str] = []
    snippets = rules.get("test_snippets", {}) or {}

    # If extras.ensure_modules present, create import tests per module
    extras = pkg.get("extras", {}) or {}
    ensure_modules = extras.get("ensure_modules", []) or []
    if ensure_modules:
        tmpl = snippets.get("import_only", "python -c \"import {module}; print('OK')\"")
        for m in ensure_modules:
            cmds.append(tmpl.replace("{module}", str(m)))

    # Allow explicit extra test commands per package via extras.test_cmds (any kind)
    extra_cmds = extras.get("test_cmds", []) or []
    if isinstance(extra_cmds, list) and extra_cmds:
        cmds.extend([str(x) for x in extra_cmds])

    # For plain libraries, verify key DSOs exist in $PREFIX/lib using map_run_deps inversion
    kind = pkg.get("kind", "")
    if kind in {"lib", "bin", "data"}:
        map_run_deps: Dict[str, str] = rules.get("map_run_deps", {}) or {}
        provides: List[str] = []
        this_name = str(pkg.get("name"))
        for dso, mapped in map_run_deps.items():
            # value may include version constraints, only compare the package token
            mapped_name = str(mapped).split()[0]
            if mapped_name == this_name:
                provides.append(dso)
        for dso in provides:
            # Ensure the SONAME file exists after installation
            cmds.append(f"bash -c 'test -e \"$PREFIX/lib/{dso}\"'")

    # If 'bin' kind, allow package-specific smoke tests from rules.bin_tests
    if kind == "bin":
        bin_tests: Dict[str, List[str]] = rules.get("bin_tests", {}) or {}
        for c in bin_tests.get(str(pkg.get("name")), []) or []:
            cmds.append(str(c))

    # Fallback minimal test
    if not cmds and pkg.get("kind", "") in {"python_core", "python_ext"}:
        cmds.append("python -V")

    return cmds

#作用：从 extras.version 读取版本；若为空则默认 "0"（占位，避免模板无版本）。

#示例：extras: { version: "1.2.3" } → 返回 "1.2.3"。
def _extract_version_from_filename(path: Path) -> Optional[str]:
    # Try to parse patterns like name_1.2.3-1_riscv64.deb or name_1.2.3_all.deb
    m = re.search(r"_(\d[^_]*)_(?:riscv64|all)\.deb$", path.name)
    if m:
        return m.group(1)
    return None


def _extract_version_with_dpkg(deb_path: Path) -> Optional[str]:
    try:
        proc = subprocess.run(["dpkg-deb", "-f", str(deb_path), "Version"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        v = proc.stdout.decode("utf-8", errors="ignore").strip()
        return v or None
    except Exception:
        return None


def _sanitize_conda_version(raw: str) -> str:
    v = raw.strip()
    # Drop Debian epoch like '2:1.6.9-2ubuntu1' → '1.6.9-2ubuntu1'
    if ":" in v:
        v = v.split(":", 1)[1]
    # Replace disallowed chars for conda versions (allow only [A-Za-z0-9_.])
    v = v.replace("-", "_").replace("+", "_").replace("~", "_")
    v = re.sub(r"[^A-Za-z0-9_.]", "_", v)
    # Collapse multiple underscores
    v = re.sub(r"_+", "_", v).strip("._")
    return v or "0"


def compute_version(pkg: Dict[str, Any], copied_debs: Optional[List[Path]] = None) -> str:
    # 1) explicit override (package-level takes precedence)
    direct = pkg.get("version")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    extras = pkg.get("extras", {}) or {}
    if isinstance(extras.get("version"), str) and extras["version"].strip():
        return extras["version"].strip()

    # 2) from copied debs (prefer version_from if provided)
    if copied_debs:
        preferred_key = str(pkg.get("version_from", "")).strip()
        ordered: List[Path] = list(copied_debs)
        if preferred_key:
            # move preferred debs to front if filename contains the key
            ordered.sort(key=lambda p: (preferred_key not in p.name, p.name))
        for p in ordered:
            v = _extract_version_with_dpkg(p) or _extract_version_from_filename(p)
            if v:
                return _sanitize_conda_version(v)

    # 3) fallback
    return "0"

#整理模板上下文（名字、版本、依赖、测试命令、Python 版本/ABI 等）；

#用 templates/meta.yaml.j2 与 templates/build.sh.j2 渲染；

#写到 <out_dir>/meta.yaml 与 build.sh，并给 build.sh 加可执行权限。
def render_templates(pkg: Dict[str, Any], rules: Dict[str, Any], pyver: str, pyabi: str, env: Environment, out_dir: Path) -> None:
    name = pkg["name"]
    version = pkg.get("_resolved_version") or compute_version(pkg)
    build_number = int(pkg.get("build_number", 0))
    kind = pkg.get("kind", "lib")

    run_deps = compute_run_deps(pkg, rules, pkg.get("_auto_run_deps"))
    test_cmds = compute_test_cmds(pkg, rules)

    summary = f"Wrapped from Debian packages: {', '.join(pkg.get('debs', []) or [])}"
    # Allow per-package override of python version/abi via extras {pyver, pyabi}
    pkg_extras = pkg.get("extras", {}) or {}
    eff_pyver = str(pkg_extras.get("pyver")).strip() if isinstance(pkg_extras.get("pyver"), str) and pkg_extras.get("pyver").strip() else pyver
    eff_pyabi = str(pkg_extras.get("pyabi")).strip() if isinstance(pkg_extras.get("pyabi"), str) and pkg_extras.get("pyabi").strip() else pyabi
    context: Dict[str, Any] = {
        "name": name,
        "version": version,
        "build_number": build_number,
        "kind": kind,
        "run_deps": run_deps,
        "test_cmds": test_cmds,
        "summary": summary,
        "missing_dso": pkg.get("missing_dso", []) or [],
        "extras": pkg.get("extras", {}) or {},
        "pyver": eff_pyver,
        "pyabi": eff_pyabi,
        "map_run_deps": rules.get("map_run_deps", {}) or {},
    }

    # meta.yaml
    meta_t = env.get_template("meta.yaml.j2")
    meta_out = meta_t.render(**context)
    (out_dir / "meta.yaml").write_text(meta_out, encoding="utf-8")

    # build.sh: choose a simpler template for plain libs to avoid Jinja control tags
    if kind in {"lib", "bin", "data"}:
        build_t = env.get_template("build.lib.sh.j2")
    else:
        build_t = env.get_template("build.sh.j2")
    build_out = build_t.render(**context)
    build_path = out_dir / "build.sh"
    build_path.write_text(build_out, encoding="utf-8")
    os.chmod(build_path, 0o755)

#作用：
#读取配置；创建 Jinja 环境；遍历 packages；
#为每个包创建 debs/ 和 recipes/ 目录；
#调用 render_templates() 生成文件；
#打印结果。
#示例：对于 name: opencv-python，会创建
def _copy_matching_debs(deb_src: Path, patterns: List[str], dest_dir: Path) -> int:
    """Copy .deb files from deb_src matching any of patterns into dest_dir.
    Returns number of files copied.
    """
    copied = 0
    for pat in patterns:
        # Use Path.glob relative to deb_src
        for match in deb_src.glob(pat):
            if match.is_file():
                target = dest_dir / match.name
                shutil.copy2(match, target)
                print(f"[COPY] {match} -> {target}")
                copied += 1
    if copied == 0:
        pats = ", ".join(patterns) if patterns else "<none>"
        print(f"[WARN] No .deb matched in {deb_src} for patterns: {pats}")
    return copied
def _is_valid_deb(path: Path) -> bool:
    """Best-effort validation for a .deb file by asking dpkg-deb for metadata.
    Returns True when dpkg-deb can parse fields; otherwise False.
    """
    if not path.exists() or not path.is_file():
        return False
    try:
        proc = subprocess.run(["dpkg-deb", "-f", str(path), "Package"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return proc.returncode == 0 and proc.stdout.decode("utf-8", errors="ignore").strip() != ""
    except Exception:
        return False


def _download_with_retries(url: str, dest: Path, tries: int = 4, backoff_s: float = 1.5) -> bool:
    """Download url -> dest with retry and exponential backoff. Returns True on success."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, max(1, tries) + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as resp, open(dest, "wb") as out:
                shutil.copyfileobj(resp, out)
            if _is_valid_deb(dest):
                print(f"[FETCH] ok {url} -> {dest}")
                return True
            else:
                print(f"[FETCH] invalid deb after download, removing: {dest}")
                dest.unlink(missing_ok=True)
        except Exception as exc:  # pragma: no cover
            print(f"[FETCH] attempt {attempt} failed: {url} ({exc})")
        if attempt < tries:
            time.sleep(backoff_s * attempt)
    return False


def _attempt_fetch_debs_from_urls(pkg: Dict[str, Any], deb_src: Path, tries: int = 4) -> int:
    """Try to fetch deb files declared in pkg["urls"] (or extras.urls) into deb_src.
    Returns number of new files successfully fetched.
    """
    urls: List[str] = []
    raw_urls = pkg.get("urls") or (pkg.get("extras", {}) or {}).get("urls")
    if isinstance(raw_urls, list):
        urls = [str(u) for u in raw_urls]
    if not urls:
        return 0

    fetched = 0
    for u in urls:
        try:
            parsed = urlparse(u)
            name = os.path.basename(parsed.path) or f"file_{int(time.time())}.deb"
            dest = deb_src / name
            if dest.exists() and _is_valid_deb(dest):
                print(f"[FETCH] skip existing valid {dest}")
                continue
            if _download_with_retries(u, dest, tries=tries):
                fetched += 1
        except Exception:
            # continue to next url
            pass
    return fetched



def _scan_dsos_and_map_run_deps(extracted_root: Path, rules: Dict[str, Any]) -> List[str]:
    """Scan ELF files under extracted_root and map NEEDED DSOs to run deps via rules.map_run_deps.
    We check files in common library and binary locations and parse `readelf -d` output
    to collect NEEDED entries (e.g. libopenblas.so.0), then map with rules.
    """
    dso_to_pkg: Dict[str, str] = rules.get("map_run_deps", {}) or {}
    found: List[str] = []
    seen = set()

    candidate_dirs = [
        extracted_root / "usr" / "lib",
        extracted_root / "usr" / "bin",
        extracted_root / "lib",
        extracted_root / "bin",
    ]

    for base in candidate_dirs:
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file():
                continue
            try:
                proc = subprocess.run(["readelf", "-d", str(p)], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                text = proc.stdout.decode("utf-8", errors="ignore")
                if not text:
                    continue
            except Exception:
                continue
            for line in text.splitlines():
                if "NEEDED" in line and "Shared library" in line:
                    # example: 0x0000000000000001 (NEEDED)             Shared library: [libopenblas.so.0]
                    m = re.search(r"Shared library:\s*\[(.+?)\]", line)
                    if not m:
                        continue
                    soname = m.group(1).strip()
                    mapped = dso_to_pkg.get(soname)
                    if mapped and mapped not in seen:
                        found.append(mapped)
                        seen.add(mapped)
    return found


def cmd_gen(manifest_path: Path, rules_path: Path, deb_src: Optional[Path] = None, enable_dso_scan: bool = True) -> None:
    manifest = read_yaml(manifest_path)
    rules = read_yaml(rules_path)

    pyver, pyabi = detect_python_version_from_manifest(manifest)

    # Use custom comment delimiters to avoid accidental parsing issues in shell scripts
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        autoescape=False,
        trim_blocks=True,
        lstrip_blocks=True,
        comment_start_string="##~",
        comment_end_string="~##",
    )

    pkgs: List[Dict[str, Any]] = manifest.get("packages", []) or []
    if not pkgs:
        print("[WARN] No packages found in manifest.")

    for pkg in pkgs:
        name = pkg.get("name")
        if not name:
            print("[WARN] Skip entry without name")
            continue

        base_dir = WORKSPACE_DIR / name
        debs_dir = base_dir / "debs"
        recipes_dir = base_dir / "recipes"
        ensure_dir(debs_dir)
        ensure_dir(recipes_dir)

        # Optionally copy .deb files from a source directory into per-package debs/.
        # If not found, try to fetch from pkg.urls (or extras.urls) into deb_src with retries, then copy again.
        if deb_src is not None:
            if not deb_src.exists() or not deb_src.is_dir():
                print(f"[ERROR] --deb-src path not a directory: {deb_src}")
            else:
                patterns: List[str] = [str(x) for x in (pkg.get("debs", []) or [])]
                copied = _copy_matching_debs(deb_src, patterns, debs_dir)
                if copied == 0:
                    fetched = _attempt_fetch_debs_from_urls(pkg, deb_src, tries=4)
                    if fetched > 0:
                        copied = _copy_matching_debs(deb_src, patterns, debs_dir)
                # If still none, and we expected something, fail fast to surface missing resource
                if copied == 0 and patterns:
                    # Try a second fetch round to increase resilience, as要求: 至少拉取四次
                    fetched = _attempt_fetch_debs_from_urls(pkg, deb_src, tries=4)
                    if fetched > 0:
                        copied = _copy_matching_debs(deb_src, patterns, debs_dir)
                if copied == 0 and patterns:
                    print(f"[ERROR] Missing .deb for package {name}; attempted fetch from urls and failed.")
                    raise SystemExit(2)

        # Optional: extract debs to a temp dir to scan DSOs for auto deps
        if enable_dso_scan and debs_dir.exists():
            with tempfile.TemporaryDirectory() as tmpd:
                tmp_root = Path(tmpd)
                # extract all .deb under debs_dir
                deb_files = list(debs_dir.glob("*.deb"))
                # resolve version from deb metadata if not provided
                try:
                    version = compute_version(pkg, deb_files)
                    if version and not pkg.get("_resolved_version"):
                        pkg["_resolved_version"] = version
                except Exception:
                    pass
                for f in deb_files:
                    try:
                        subprocess.run(["dpkg-deb", "-x", str(f), str(tmp_root)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    except Exception:
                        # ignore failing archives; best-effort
                        pass
                auto_run = _scan_dsos_and_map_run_deps(tmp_root, rules)
                if auto_run:
                    pkg["_auto_run_deps"] = auto_run

        render_templates(pkg, rules, pyver, pyabi, env, recipes_dir)
        print(f"[OK] Generated recipe for {name} -> {recipes_dir}")

#作用：定义 gen 子命令及其参数；路由到 cmd_gen。

#示例：

#python tools/debwrap.py gen --manifest manifest.yaml --rules rules.yaml
def main() -> None:
    parser = argparse.ArgumentParser(prog="debwrap", description="Generate conda recipes from Debian packages")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_gen = sub.add_parser("gen", help="Generate recipes")
    p_gen.add_argument("--manifest", required=True, type=Path)
    p_gen.add_argument("--rules", required=True, type=Path)
    p_gen.add_argument("--deb-src", required=False, type=Path, help="Directory containing source .deb files to copy from")
    p_gen.add_argument("--no-dso-scan", action="store_true", help="Disable DSO-based auto dependency mapping")

    args = parser.parse_args()

    if args.cmd == "gen":
        cmd_gen(args.manifest, args.rules, args.deb_src, enable_dso_scan=(not args.no_dso_scan))
    else:  # pragma: no cover
        parser.error("unknown command")


if __name__ == "__main__":
    main()

