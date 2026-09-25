#!/usr/bin/env python3
"""Offline Hermes upstream maintenance.

ONLINE MAINTENANCE TOOL. `update-upstream` and `refresh` (without --dry-run)
fetch from the upstream Git repository, PyPI and the npm registry. Nothing in
the offline install path (install-offline, verify-*, build-bundle) runs this
file. `check` and `refresh --dry-run` read only local files.

Subcommands (the scripts/*.sh wrappers are the documented entry points):
  check              selection rules reproduce manifests/python.lock and node.lock
  surface OLD NEW    dependency/network/installer/license surface diff between two upstream commits
  update-upstream    import a new upstream commit into upstream/hermes-agent
  refresh            re-vendor Python wheels and npm tarballs for the imported upstream

Requires Python 3.11+ (tomllib) and the `packaging` library (pip's vendored
copy is used when it is not installed).
"""
from __future__ import annotations

import argparse
import base64
import collections
import datetime as dt
import email.parser
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request
import zipfile
from dataclasses import dataclass, field
from fnmatch import fnmatch
from pathlib import Path, PurePosixPath

try:
    from packaging.markers import Marker
    from packaging.requirements import Requirement
    from packaging.tags import compatible_tags, cpython_tags
    from packaging.utils import canonicalize_name, parse_wheel_filename
except ImportError:  # pip always carries a copy
    from pip._vendor.packaging.markers import Marker
    from pip._vendor.packaging.requirements import Requirement
    from pip._vendor.packaging.tags import compatible_tags, cpython_tags
    from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename

REPO = Path(__file__).resolve().parents[2]
UPSTREAM_DIR = "upstream/hermes-agent"
PROFILE = REPO / "profiles" / "windows-x64-desktop.toml"
MANIFESTS = REPO / "manifests"
REPORTS = REPO / "reports" / "upstream-updates"
DEFAULT_GIT = REPO / ".maintenance" / "upstream.git"


class MaintError(Exception):
    pass


def say(msg: str = "") -> None:
    print(msg, flush=True)


# --------------------------------------------------------------------------
# Upstream sources: the working tree, or a commit in the upstream Git clone.


class Source:
    def read(self, path: str) -> bytes | None:
        raise NotImplementedError

    def text(self, path: str) -> str | None:
        data = self.read(path)
        return None if data is None else data.decode("utf-8")


class DirSource(Source):
    def __init__(self, root: Path):
        self.root = root

    def read(self, path):
        p = self.root / path
        return p.read_bytes() if p.is_file() else None


class GitSource(Source):
    def __init__(self, git_dir: Path, commit: str):
        self.git_dir, self.commit = git_dir, commit

    def read(self, path):
        r = subprocess.run(git_cmd(self.git_dir, "show", f"{self.commit}:{path}"), capture_output=True)
        return r.stdout if r.returncode == 0 else None


def git_cmd(git_dir: Path | None, *args: str) -> list[str]:
    base = ["git", "-c", "core.autocrlf=false", "-c", "core.quotepath=off"]
    if git_dir is not None:
        base += ["--git-dir", str(git_dir)]
    return base + list(args)


def git(git_dir: Path | None, *args: str, cwd: Path | None = None) -> str:
    r = subprocess.run(git_cmd(git_dir, *args), capture_output=True, cwd=cwd)
    if r.returncode != 0:
        raise MaintError(f"git {' '.join(args)} failed:\n{r.stderr.decode('utf-8', 'replace').strip()}")
    return r.stdout.decode("utf-8", "replace")


# --------------------------------------------------------------------------
# Manifests: TOML-like files with [[artifact]] blocks. Blocks are kept
# verbatim so an unchanged artifact keeps its reviewed record byte for byte.


@dataclass
class Block:
    fields: dict
    text: str


@dataclass
class Manifest:
    header: str
    blocks: list
    trailer: str = ""

    @classmethod
    def load(cls, path: Path, marker: str = "[[artifact]]") -> "Manifest":
        text = path.read_text(encoding="utf-8")
        parts = text.split(marker + "\n")
        blocks = []
        for raw in parts[1:]:
            fields = {}
            for m in re.finditer(r'^([a-z0-9_]+) = (".*"|\[.*\]|[0-9]+|true|false)$', raw, re.M):
                fields[m.group(1)] = tomllib.loads(f"v = {m.group(2)}")["v"]
            blocks.append(Block(fields, marker + "\n" + raw))
        return cls(parts[0], blocks)

    def render(self) -> str:
        return self.header + "".join(b.text for b in self.blocks)


def toml_str(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def render_block(fields: dict, trailing_blank: bool) -> str:
    lines = ["[[artifact]]"]
    for key, value in fields.items():
        if isinstance(value, list):
            lines.append(f"{key} = [{', '.join(toml_str(v) for v in value)}]")
        else:
            lines.append(f"{key} = {toml_str(value)}")
    return "\n".join(lines) + "\n" + ("\n" if trailing_blank else "")


def set_header_value(header: str, key: str, value) -> str:
    rendered = str(value) if isinstance(value, int) else toml_str(value)
    new, n = re.subn(rf"^{key} = .*$", f"{key} = {rendered}", header, count=1, flags=re.M)
    if n != 1:
        raise MaintError(f"manifest header has no '{key}'")
    return new


def load_profile() -> dict:
    return tomllib.loads(PROFILE.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
# Python closure from uv.lock.


@dataclass
class PyArtifact:
    name: str
    version: str
    filename: str
    url: str
    sha256: str
    source: str = "registry"


def python_closure(src: Source, profile: dict) -> tuple[dict, list]:
    """Returns ({filename: PyArtifact}, notes). Notes list non-registry sources and excluded packages reached."""
    cfg = profile["python"]
    lock_text = src.text("uv.lock")
    pyproject_text = src.text("pyproject.toml")
    if lock_text is None or pyproject_text is None:
        raise MaintError("upstream has no uv.lock or pyproject.toml")
    lock = tomllib.loads(lock_text)
    pyproject = tomllib.loads(pyproject_text)
    env = dict(cfg["markers"])
    major, minor = cfg["python_version"]
    tags = list(cpython_tags((major, minor), platforms=cfg["platforms"])) + list(
        compatible_tags((major, minor), platforms=cfg["platforms"]))
    rank = {t: i for i, t in enumerate(tags)}
    excluded = {canonicalize_name(e["name"]): e for e in cfg.get("exclude", [])}

    packages = collections.defaultdict(list)
    for p in lock["package"]:
        packages[canonicalize_name(p["name"])].append(p)

    def marker_ok(marker: str | None, extra: str = "") -> bool:
        if not marker:
            return True
        return Marker(marker).evaluate({**env, "extra": extra})

    def pick(name: str, dep: dict) -> dict:
        cands = packages.get(canonicalize_name(name))
        if not cands:
            raise MaintError(f"uv.lock has no package {name}")
        if len(cands) == 1:
            return cands[0]
        if "version" in dep:
            for c in cands:
                if c["version"] == dep["version"]:
                    return c
        forks = [c for c in cands if any(marker_ok(m) for m in c.get("resolution-markers", []))]
        if len(forks) == 1:
            return forks[0]
        raise MaintError(f"cannot choose between {len(cands)} uv.lock entries for {name}")

    project = pyproject["project"]["name"]
    root = next((p for p in lock["package"] if p["name"] == project), None)
    if root is None:
        raise MaintError(f"uv.lock has no entry for the project {project}")
    queue = list(root.get("dependencies", []))
    if cfg.get("include_build_requires"):
        for req in pyproject.get("build-system", {}).get("requires", []):
            r = Requirement(req)
            pin = next((str(s.version) for s in r.specifier if s.operator == "=="), None)
            if pin and canonicalize_name(r.name) in packages:
                queue.append({"name": r.name, "version": pin})
            elif not any(canonicalize_name(p["name"]) == canonicalize_name(r.name) for p in cfg.get("pins", [])):
                raise MaintError(f"build requirement '{req}' is neither in uv.lock nor pinned in the profile")

    notes, selected, reached_excluded = [], {}, set()
    # Direct dependencies that only apply to other Python versions mean the
    # profile's interpreter is behind upstream: the closure would install,
    # but Hermes would be missing core packages.
    # uv drops markers implied by the lock's resolution environments, so both
    # the lock's resolution-markers and pyproject's own markers are checked.
    profile_python = cfg["markers"]["python_full_version"]
    direct = [Requirement(d) for d in pyproject["project"].get("dependencies", [])]
    version_gated = sorted(r.name for r in direct if r.marker and re.search(r"python_(?:full_)?version", str(r.marker))
                           and not r.marker.evaluate({**env, "extra": ""}))
    resolution = lock.get("resolution-markers", [])
    if resolution and not any(marker_ok(m) for m in resolution):
        notes.append(f"PROFILE PYTHON OUTDATED: uv.lock is resolved only for {' | '.join(resolution)}, "
                     f"which excludes the profile's Python {profile_python}.")
    if len(version_gated) * 4 > len(direct):
        notes.append(f"PROFILE PYTHON OUTDATED: {len(version_gated)} of {len(direct)} direct dependencies in "
                     f"pyproject.toml apply only to other Python versions than {profile_python} "
                     f"(for example {', '.join(version_gated[:6])}).")
    if any(n.startswith("PROFILE PYTHON") for n in notes):
        notes.append("PROFILE PYTHON OUTDATED: move the profile's [python] markers and the vendored CPython "
                     "(manifests/binaries.lock) to a version upstream resolves for, then refresh.")
    while queue:
        dep = queue.pop()
        if not marker_ok(dep.get("marker")):
            continue
        if canonicalize_name(dep["name"]) in excluded:
            reached_excluded.add(canonicalize_name(dep["name"]))
            continue
        pkg = pick(dep["name"], dep)
        key = (canonicalize_name(pkg["name"]), pkg["version"])
        extras = set(dep.get("extra", []))
        if key in selected and extras <= selected[key][1]:
            continue
        prev = selected.get(key, (pkg, set()))[1]
        selected[key] = (pkg, prev | extras)
        queue.extend(pkg.get("dependencies", []))
        for ex in extras:
            queue.extend(pkg.get("optional-dependencies", {}).get(ex, []))

    result = {}
    for (name, version), (pkg, _) in sorted(selected.items()):
        source = pkg.get("source", {})
        if "registry" not in source:
            notes.append(f"{pkg['name']} {version} comes from a non-registry source: {source}")
        best = None
        for wheel in pkg.get("wheels", []):
            filename = urllib.request.unquote(wheel["url"].rsplit("/", 1)[1])
            _, _, _, wtags = parse_wheel_filename(filename)
            r = min((rank[t] for t in wtags if t in rank), default=None)
            if r is not None and (best is None or r < best[0]):
                best = (r, filename, wheel)
        if best is None:
            raise MaintError(f"no {cfg['platforms']} cp{major}{minor} wheel for {pkg['name']} {version}; "
                             "the profile cannot build sdists offline")
        _, filename, wheel = best
        if not wheel.get("hash", "").startswith("sha256:"):
            raise MaintError(f"uv.lock has no sha256 for {filename}")
        result[filename] = PyArtifact(pkg["name"], version, filename, wheel["url"], wheel["hash"][7:],
                                      "registry" if "registry" in source else json.dumps(source))
    for pin in cfg.get("pins", []):
        filename = pin["url"].rsplit("/", 1)[1]
        result[filename] = PyArtifact(pin["name"], pin["version"], filename, pin["url"], pin["sha256"], "profile pin")
    for name in sorted(reached_excluded):
        notes.append(f"{name} is reached but excluded by the profile: {excluded[name]['reason']}")
    return result, notes


# --------------------------------------------------------------------------
# npm closure from package-lock.json.


@dataclass
class NodeArtifact:
    name: str
    version: str
    lock_path: str
    url: str
    integrity: str
    license: str
    install_script: bool
    paths: list = field(default_factory=list)

    @property
    def filename(self) -> str:
        return self.name.replace("@", "").replace("/", "__") + f"-{self.version}.tgz"


def node_closure(src: Source, profile: dict) -> tuple[dict, list]:
    cfg = profile["node"]
    lock_text = src.text("package-lock.json")
    if lock_text is None:
        raise MaintError("upstream has no package-lock.json")
    packages = json.loads(lock_text)["packages"]
    excluded = {e["name"]: e for e in cfg.get("exclude", [])}

    def platform_ok(pkg: dict) -> bool:
        def allowed(values, wanted):
            if not values:
                return True
            if "!" + wanted in values:
                return False
            positive = [v for v in values if not v.startswith("!")]
            return not positive or wanted in positive
        return allowed(pkg.get("os"), cfg["os"]) and allowed(pkg.get("cpu"), cfg["cpu"])

    def resolve(frm: str, name: str) -> str | None:
        d = frm
        while True:
            cand = f"{d}/node_modules/{name}" if d else f"node_modules/{name}"
            if cand in packages:
                return cand
            if not d:
                return None
            if "/node_modules/" in d:
                d = d[: d.rfind("/node_modules/")]
            elif d.startswith("node_modules/"):
                d = ""
            else:
                d = d.rsplit("/", 1)[0] if "/" in d else ""

    def pkg_name(path: str) -> str:
        return packages[path].get("name") or path.rsplit("node_modules/", 1)[1]

    notes, selected, seen = [], set(), set()
    queue = list(cfg["roots"])
    for root in cfg["roots"]:
        if root not in packages:
            raise MaintError(f"package-lock.json has no workspace {root}")
    for extra in cfg.get("extra_packages", []):
        path = f"node_modules/{extra['name']}"
        if path not in packages:
            raise MaintError(f"profile extra package {extra['name']} is not at {path} in package-lock.json")
        queue.append(path)
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        pkg = packages[path]
        if pkg.get("link"):
            queue.append(pkg["resolved"])
            continue
        is_dep = "node_modules/" in path
        if is_dep:
            if not platform_ok(pkg):
                continue
            if pkg_name(path) in excluded:
                continue
            selected.add(path)
        kinds = ["dependencies", "optionalDependencies"]
        if path in cfg["roots"]:
            kinds.append("devDependencies")
        if cfg.get("include_peers"):
            kinds.append("peerDependencies")
        for kind in kinds:
            for name in pkg.get(kind, {}):
                if kind == "peerDependencies" and pkg.get("peerDependenciesMeta", {}).get(name, {}).get("optional"):
                    continue
                target = resolve(path, name)
                if target:
                    queue.append(target)
                elif kind == "dependencies":
                    raise MaintError(f"{path} depends on {name}, which package-lock.json does not resolve")

    result = {}
    for path in sorted(selected):
        pkg = packages[path]
        name, version = pkg_name(path), pkg.get("version")
        key = f"{name}@{version}"
        if key in result:
            result[key].paths.append(path)
            continue
        resolved = pkg.get("resolved", "")
        if not resolved.startswith("https://registry.npmjs.org/"):
            notes.append(f"{key} ({path}) resolves outside the npm registry: {resolved or 'no resolved URL'}")
        if not pkg.get("integrity", "").startswith("sha512-"):
            raise MaintError(f"{key} has no sha512 integrity in package-lock.json")
        result[key] = NodeArtifact(name, version, path, resolved, pkg["integrity"], pkg.get("license") or "",
                                   bool(pkg.get("hasInstallScript")), [path])
    reviewed = {e["name"] for e in cfg.get("install_scripts", [])}
    for art in result.values():
        if art.install_script and art.name not in reviewed:
            notes.append(f"UNREVIEWED INSTALL SCRIPT: {art.name}@{art.version} has an npm lifecycle script; "
                         "the installer skips it. Review it and add a [[node.install_scripts]] entry.")
    return result, notes


# Bare module imports in the desktop source. A package the source imports but
# the closure lacks resolves upstream only through another workspace's hoisted
# install; offline, the desktop build fails on it.

IMPORT_RE = re.compile(
    r"""(?:^|[^\w.])(?:import|export)\s+(?!type\b)(?:[^'";]*?\sfrom\s*)?['"]([^'"\n]+)['"]"""
    r"""|\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)|\brequire\s*\(\s*['"]([^'"\n]+)['"]\s*\)""", re.M)
JS_SUFFIXES = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
NODE_BUILTINS = set("""assert async_hooks buffer child_process cluster console constants crypto dgram
    diagnostics_channel dns domain events fs http http2 https inspector module net os path perf_hooks process
    punycode querystring readline repl stream string_decoder sys timers tls trace_events tty url util v8 vm wasi
    worker_threads zlib""".split())


NPM_NAME_RE = re.compile(r"^(?:@[a-z0-9~][a-z0-9._~-]*/)?[a-z0-9~][a-z0-9._~-]*$")
COMMENT_RE = re.compile(r"/\*.*?\*/|(?<![:'\"\\\w])//[^\n]*", re.S)


def import_package(spec: str, aliases: list) -> str | None:
    if spec.startswith((".", "/", "node:", "data:", "http:", "https:")) or any(spec.startswith(a) for a in aliases):
        return None
    parts = spec.split("/")
    name = "/".join(parts[:2]) if spec.startswith("@") else parts[0]
    if not NPM_NAME_RE.match(name) or name in NODE_BUILTINS:
        return None
    return name


def import_findings(files, closure: dict, profile: dict) -> list:
    """files: iterable of (path, text). Returns notes for imported packages outside the closure."""
    cfg = profile["node"]
    aliases = cfg.get("import_aliases", [])
    names = {a.name for a in closure.values()}
    missing = collections.defaultdict(set)
    for path, text in files:
        if not path.endswith(JS_SUFFIXES) or is_low_signal(path) or ".d." in path:
            continue
        for m in IMPORT_RE.finditer(COMMENT_RE.sub(" ", text)):
            pkg = import_package(next(g for g in m.groups() if g), aliases)
            if pkg and pkg not in names:
                missing[pkg].add(path)
    return [f"UNDECLARED IMPORT: {pkg} is imported by {', '.join(sorted(paths)[:3])}"
            f"{' and others' if len(paths) > 3 else ''} but is not in the closure. Upstream resolves it only through "
            "another workspace's hoisted install. Declare it for apps/desktop with a patch, and add it to "
            "[[node.extra_packages]] in the profile." for pkg, paths in sorted(missing.items())]


def scan_tree(root: Path, profile: dict):
    for rel in profile["node"].get("import_scan_dirs", []):
        base = root / rel
        if not base.is_dir():
            continue
        for p in base.rglob("*"):
            if p.is_file() and p.suffix in JS_SUFFIXES and "node_modules" not in p.parts:
                yield p.relative_to(root).as_posix(), p.read_text(encoding="utf-8", errors="replace")


# --------------------------------------------------------------------------
# Manifest comparison and pinned-runtime expectations.


def current_python() -> dict:
    m = Manifest.load(MANIFESTS / "python.lock")
    return {b.fields["path"].rsplit("/", 1)[1]: b for b in m.blocks}


def current_node() -> dict:
    m = Manifest.load(MANIFESTS / "node.lock")
    return {f"{b.fields['name']}@{b.fields['version']}": b for b in m.blocks}


@dataclass
class Plan:
    py_add: list
    py_remove: list
    py_conflict: list
    node_add: list
    node_remove: list
    node_conflict: list
    notes: list
    pinned: list

    @property
    def changed(self) -> bool:
        return bool(self.py_add or self.py_remove or self.node_add or self.node_remove)

    @property
    def blocking(self) -> list:
        items = [f"python checksum changed for an unchanged version: {c}" for c in self.py_conflict]
        items += [f"npm integrity changed for an unchanged version: {c}" for c in self.node_conflict]
        items += [n for n in self.notes if n.startswith(("UNREVIEWED", "PROFILE", "UNDECLARED"))]
        items += [p for p in self.pinned if p.startswith("MANUAL")]
        return items


def pinned_checks(profile: dict, node: dict) -> list:
    by_name = collections.defaultdict(set)
    for art in node.values():
        by_name[art.name].add(art.version)
    out = []
    for rule in profile.get("pinned", []):
        manifest = Manifest.load(MANIFESTS / rule["manifest"])
        versions = {b.fields["version"] for b in manifest.blocks if b.fields.get("name") == rule["artifact"]}
        npm = by_name.get(rule["npm_package"], set())
        match = rule["match"]
        if match == "equal":
            ok = versions == npm
        elif match == "prefix":
            ok = len(npm) == 1 and all(v.startswith(next(iter(npm))) for v in versions)
        elif match == "set":
            ok = versions == npm
        elif match == "reviewed":
            ok = npm == {rule["npm_version"]}
        else:
            raise MaintError(f"unknown pinned match '{match}'")
        desc = (f"{rule['artifact']} ({rule['manifest']}: {', '.join(sorted(versions)) or 'none'}) "
                f"vs npm {rule['npm_package']} {', '.join(sorted(npm)) or 'absent'}")
        if match == "reviewed":
            desc += f" (reviewed against {rule['npm_version']})"
        out.append(("ok: " if ok else "MANUAL UPDATE: ") + desc)
    return out


def make_plan(src: Source, profile: dict, import_files=None) -> tuple[Plan, dict, dict]:
    """import_files: (path, text) pairs to scan for imports; the whole tree for a DirSource by default."""
    py, py_notes = python_closure(src, profile)
    node, node_notes = node_closure(src, profile)
    if import_files is None and isinstance(src, DirSource):
        import_files = scan_tree(src.root, profile)
    if import_files is not None:
        node_notes += import_findings(import_files, node, profile)
    cur_py, cur_node = current_python(), current_node()
    py_conflict = [f"{fn}: manifest {cur_py[fn].fields['sha256']}, uv.lock {art.sha256}"
                   for fn, art in py.items() if fn in cur_py and cur_py[fn].fields["sha256"] != art.sha256]
    node_conflict = [f"{k}: manifest {cur_node[k].fields['npm_integrity']}, package-lock {a.integrity}"
                     for k, a in node.items() if k in cur_node and cur_node[k].fields["npm_integrity"] != a.integrity]
    plan = Plan(
        py_add=sorted(fn for fn in py if fn not in cur_py),
        py_remove=sorted(fn for fn in cur_py if fn not in py),
        py_conflict=py_conflict,
        node_add=sorted(k for k in node if k not in cur_node),
        node_remove=sorted(k for k in cur_node if k not in node),
        node_conflict=node_conflict,
        notes=py_notes + node_notes,
        pinned=pinned_checks(profile, node),
    )
    return plan, py, node


def plan_markdown(plan: Plan, py: dict, node: dict) -> list:
    cur_py, cur_node = current_python(), current_node()
    out = ["## Vendor refresh plan", ""]
    out.append(f"Python wheels: {len(py)} selected; {len(plan.py_add)} to add, {len(plan.py_remove)} to remove. "
               f"npm tarballs: {len(node)} selected; {len(plan.node_add)} to add, {len(plan.node_remove)} to remove.")
    out.append("")
    if plan.blocking:
        out += ["**Blocking, needs a decision before refreshing:**", ""]
        out += [f"- {b}" for b in plan.blocking] + [""]
    for title, items in (("Python wheels to add", [f"`{fn}` ({py[fn].name} {py[fn].version})" for fn in plan.py_add]),
                         ("Python wheels to remove", [f"`{fn}`" for fn in plan.py_remove]),
                         ("npm tarballs to add", [f"`{k}`" + (f" ({node[k].license or 'no license field'})")
                                                  + (" **has an install script**" if node[k].install_script else "")
                                                  for k in plan.node_add]),
                         ("npm tarballs to remove", [f"`{k}`" for k in plan.node_remove])):
        if items:
            out += [f"### {title} ({len(items)})", ""] + [f"- {i}" for i in items] + [""]
    lic = [f"`{k}`: {cur_node[k].fields['license']} -> {a.license}" for k, a in node.items()
           if k in cur_node and cur_node[k].fields["license"] != a.license and a.license]
    if lic:
        out += ["### npm license field changes (same version)", ""] + [f"- {l}" for l in lic] + [""]
    out += ["### Pinned runtimes", ""] + [f"- {p}" for p in plan.pinned] + [""]
    if plan.notes:
        out += ["### Notes", ""] + [f"- {n}" for n in plan.notes] + [""]
    return out


# --------------------------------------------------------------------------
# Surface diff between two upstream commits.

NETWORK_PATTERNS = [
    ("URL", re.compile(r"\b(?:https?|wss?)://(?!(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|(?:[\w-]+\.)*example\.(?:com|org|net))\b)[^\s'\"<>`)\]]+")),
    ("download tool", re.compile(r"\b(?:curl|wget|Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer)\b")),
    ("package install", re.compile(r"\b(?:npx\s|npm\s+(?:i|install|exec)\b|pnpm\s+(?:add|dlx)|yarn\s+(?:add|dlx)|pip\s+install|uv\s+(?:pip\s+install|add|sync|tool\s+install|run\s+--with)|playwright\s+install|brew\s+install|winget\s+install|apt(?:-get)?\s+install|git\s+clone)\b")),
    ("HTTP client", re.compile(r"\b(?:requests\.(?:get|post|put|head|request|Session)|httpx\.(?:get|post|stream|AsyncClient|Client)|aiohttp\.ClientSession|urllib\.request|urlopen|fetch\(|axios[.(]|net\.request|https?\.(?:get|request)\(|new WebSocket\(|websockets\.connect)")),
    ("model download", re.compile(r"\b(?:snapshot_download|hf_hub_download|from_pretrained|ollama\s+pull)\b")),
]
CODE_SUFFIXES = {".py", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".sh", ".ps1", ".psm1", ".bat", ".cmd", ".toml",
                 ".yaml", ".yml", ".json", ".nix", ".rs"}
LOW_SIGNAL = ("tests/", "test/", "tests-js/", "website/", "docs/", "optional-skills/", "skills/", "locales/")
INSTALLER_GLOBS = [
    "scripts/*", "setup.py", "setup.cfg", "pyproject.toml", "package.json", ".npmrc", "uv.toml", ".python-version",
    ".nvmrc", ".gitmodules", "apps/desktop/package.json", "apps/desktop/scripts/*", "apps/desktop/electron/*",
    "apps/desktop/electron-builder*", "apps/shared/package.json", "tools/lazy_deps.py", "hermes_cli/*install*",
    "hermes_cli/*setup*", "hermes_cli/*update*", "hermes_cli/*bootstrap*", "hermes_cli/*doctor*", "*Dockerfile*",
    "docker/*", ".github/workflows/*", "nix/*", "flake.nix", "flake.lock",
]
LICENSE_RE = re.compile(r"(?:^|/)(?:LICEN[CS]E|COPYING|NOTICE)[^/]*$", re.I)


def is_low_signal(path: str) -> bool:
    return path.startswith(LOW_SIGNAL) or "/tests/" in path or "/test/" in path or "__tests__" in path \
        or path.endswith((".md", ".mdx", ".txt", ".snap")) or ".test." in path or ".spec." in path


def is_low_signal_network(path: str) -> bool:
    # Also translation strings and plugin-catalog entries (repository URLs;
    # the catalog is unavailable offline, gap G12). CI workflows are listed
    # under installer changes.
    return is_low_signal(path) or path.startswith((".github/", "plugin-catalog/")) \
        or "/i18n/" in path or "/locales/" in path


def added_lines(git_dir: Path, old: str, new: str) -> dict:
    """{path: [(new_line_number, text)]} for lines added between old and new."""
    raw = git(git_dir, "diff", "--no-color", "--no-ext-diff", "--unified=0", "--no-renames", old, new)
    out, path, line = collections.defaultdict(list), None, 0
    for row in raw.splitlines():
        if row.startswith("+++ "):
            path = row[6:] if row.startswith("+++ b/") else None
        elif row.startswith("@@"):
            m = re.search(r"\+(\d+)", row)
            line = int(m.group(1)) if m else 0
        elif row.startswith("+") and path:
            out[path].append((line, row[1:]))
            line += 1
    return out


def patch_targets(patch_text: str) -> list:
    # From the ---/+++ lines, so plain unified diffs without a
    # "diff --git" header (patch 0001) are covered too.
    targets = []
    for m in re.finditer(r"^(?:---|\+\+\+) [ab]/(\S+)", patch_text, re.M):
        if m.group(1) not in targets:
            targets.append(m.group(1))
    return targets


def check_patches(git_dir: Path, commit: str, changed: set) -> list:
    rows = []
    lock = Manifest.load(MANIFESTS / "patches.lock", "[[patch]]")
    for block in lock.blocks:
        patch = REPO / block.fields["path"]
        text = patch.read_text(encoding="utf-8")
        targets = patch_targets(text)
        with tempfile.TemporaryDirectory(prefix="ohmaint-patch-") as tmp:
            for target in targets:
                data = GitSource(git_dir, commit).read(target)
                if data is not None:
                    dest = Path(tmp) / target
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
            env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(Path(tmp).parent)}
            r = subprocess.run(["git", "apply", "--check", "-p1", str(patch)], cwd=tmp, capture_output=True, env=env)
        touched = sorted(t for t in targets if t in changed)
        status = "applies" if r.returncode == 0 else "**DOES NOT APPLY**"
        detail = "" if r.returncode == 0 else ": " + r.stderr.decode("utf-8", "replace").strip().replace("\n", "; ")
        rows.append(f"- `{block.fields['path']}` {status} to {commit[:10]}{detail}. "
                    f"Targets changed upstream: {', '.join(f'`{t}`' for t in touched) if touched else 'none'}.")
    return rows


def json_field(src: Source, path: str, *keys) -> object:
    text = src.text(path)
    if text is None:
        return None
    value = json.loads(text)
    for k in keys:
        value = value.get(k) if isinstance(value, dict) else None
    return value


def surface(git_dir: Path, old: str, new: str, profile: dict) -> str:
    old = git(git_dir, "rev-parse", "--verify", f"{old}^{{commit}}").strip()
    new = git(git_dir, "rev-parse", "--verify", f"{new}^{{commit}}").strip()
    old_src, new_src = GitSource(git_dir, old), GitSource(git_dir, new)
    log = git(git_dir, "log", "--oneline", "--no-decorate", f"{old}..{new}").splitlines()
    status = [row.split("\t") for row in git(git_dir, "diff", "--name-status", "--no-renames", old, new).splitlines()]
    changed = {row[-1] for row in status}

    out = [f"# Upstream surface diff: {old[:10]}..{new[:10]}", "",
           f"Generated {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by `scripts/diff-dependency-surface.sh`.",
           "", "| | |", "|---|---|",
           f"| From | `{old}` ({git(git_dir, 'show', '-s', '--format=%cI', old).strip()}) |",
           f"| To | `{new}` ({git(git_dir, 'show', '-s', '--format=%cI', new).strip()}) |",
           f"| Commits | {len(log)} |", f"| Files changed | {len(status)} |", ""]

    # Dependency closures at both ends, and the plan against the manifests.
    old_py, _ = python_closure(old_src, profile)
    new_py, _ = python_closure(new_src, profile)
    old_node, _ = node_closure(old_src, profile)
    new_node, _ = node_closure(new_src, profile)

    def delta(a: dict, b: dict, label) -> list:
        # Versions grouped by package: one package can be at several versions.
        av, bv = collections.defaultdict(set), collections.defaultdict(set)
        for v in a.values():
            av[label(v)].add(v.version)
        for v in b.values():
            bv[label(v)].add(v.version)
        rows = []
        for name in sorted(set(av) | set(bv)):
            if av.get(name) != bv.get(name):
                rows.append(f"- `{name}`: {', '.join(sorted(av.get(name, []))) or '(new)'} -> "
                            f"{', '.join(sorted(bv.get(name, []))) or '(removed)'}")
        return rows

    out += ["## Dependency sources", ""]
    py_rows = delta(old_py, new_py, lambda v: canonicalize_name(v.name))
    node_rows = delta(old_node, new_node, lambda v: v.name)
    out += [f"### Python closure ({len(old_py)} -> {len(new_py)} wheels)", ""] + (py_rows or ["No change."]) + [""]
    out += [f"### npm closure ({len(old_node)} -> {len(new_node)} tarballs)", ""] + (node_rows or ["No change."]) + [""]
    for path, keys in (("pyproject.toml", None), ("package.json", ("engines",)), ("apps/desktop/package.json", ("engines",))):
        if path == "pyproject.toml":
            a = (tomllib.loads(old_src.text(path) or "") or {}).get("project", {}).get("requires-python")
            b = (tomllib.loads(new_src.text(path) or "") or {}).get("project", {}).get("requires-python")
            label = "requires-python"
        else:
            a, b, label = json_field(old_src, path, *keys), json_field(new_src, path, *keys), "engines"
        if a != b:
            out.append(f"- `{path}` {label}: `{a}` -> `{b}`")
    manifest_rx = re.compile(r"(?:^|/)(?:package-lock\.json|package\.json|uv\.lock|pyproject\.toml|requirements[^/]*\.txt"
                             r"|Cargo\.(?:toml|lock)|flake\.lock|go\.(?:mod|sum)|\.gitmodules)$")
    extra_sources = [f"- {row[0]} `{row[-1]}`" for row in status if manifest_rx.search(row[-1])
                     and row[-1] not in ("uv.lock", "package-lock.json")]
    if any(row[-1] == ".gitmodules" and row[0] == "A" for row in status):
        extra_sources.insert(0, "- **`.gitmodules` added: upstream now has submodules.**")
    out += ["", "Other dependency manifests changed (outside the profile's closure unless listed above):", ""]
    out += (extra_sources or ["None."]) + [""]
    # Imports added in the scanned workspaces (reading every file of a
    # blobless clone would fetch it; the added lines are what can be new).
    added = added_lines(git_dir, old, new)
    scan_dirs = tuple(d.rstrip("/") + "/" for d in profile["node"].get("import_scan_dirs", []))
    new_imports = [(p, "\n".join(t for _, t in rows)) for p, rows in added.items() if p.startswith(scan_dirs)]
    out += plan_markdown(make_plan(new_src, profile, new_imports)[0], new_py, new_node)

    # Network surface: added lines matching network patterns.
    hits, low = collections.defaultdict(list), collections.Counter()
    for path, rows in added.items():
        if PurePosixPath(path).suffix not in CODE_SUFFIXES and "Dockerfile" not in path:
            continue
        if path.endswith(("package-lock.json", "uv.lock")):
            continue
        for number, text in rows:
            kinds = [k for k, rx in NETWORK_PATTERNS if rx.search(text)]
            if not kinds:
                continue
            if is_low_signal_network(path):
                low["i18n" if "/i18n/" in path or "/locales/" in path else path.split("/", 1)[0]] += 1
            else:
                hits[path].append((number, kinds, text.strip()[:160]))
    out += ["## New network access paths", "",
            "Added lines in runtime code that contain a URL, a download tool, a package-manager install, an HTTP client call or a model download. "
            "Each needs a decision: harmless (documentation string, loopback), blocked by the offline profile, or a new gap.", ""]
    if hits:
        for path in sorted(hits):
            out.append(f"- `{path}`")
            for number, kinds, text in hits[path][:12]:
                out.append(f"  - L{number} ({', '.join(kinds)}): `{text.replace('`', chr(39))}`")
            if len(hits[path]) > 12:
                out.append(f"  - and {len(hits[path]) - 12} more")
    else:
        out.append("None in runtime code.")
    if low:
        out += ["", "Also in tests, docs and skills (not listed): " + ", ".join(f"{k} {v}" for k, v in low.most_common()) + "."]
    out.append("")

    # Installer and bootstrap behavior.
    installer, installer_tests = [], 0
    for row in status:
        path = row[-1]
        if any(fnmatch(path, g) for g in INSTALLER_GLOBS):
            if is_low_signal(path):
                installer_tests += 1
                continue
            n = len(added.get(path, []))
            installer.append(f"- {row[0]} `{path}`" + (f" (+{n} lines)" if n else ""))
    out += ["## Installer and bootstrap behavior", "",
            "Changed files that install, bootstrap, update or package Hermes. Review each against `scripts/install-offline.ps1` and the patches.", ""]
    out += installer or ["None."]
    if installer_tests:
        out.append(f"- and {installer_tests} changed test files in the same areas (not listed)")
    for path in ("package.json", "apps/desktop/package.json"):
        a, b = json_field(old_src, path, "scripts") or {}, json_field(new_src, path, "scripts") or {}
        for name in sorted(set(a) | set(b)):
            if a.get(name) != b.get(name):
                out.append(f"- `{path}` script `{name}`: `{a.get(name)}` -> `{b.get(name)}`")
    out += ["", "### Offline patches", ""] + check_patches(git_dir, new, changed) + [""]

    # Licenses.
    lic_files = [f"- {row[0]} `{row[-1]}`" for row in status if LICENSE_RE.search(row[-1])]
    old_lic = tomllib.loads(old_src.text("pyproject.toml") or "").get("project", {}).get("license")
    new_lic = tomllib.loads(new_src.text("pyproject.toml") or "").get("project", {}).get("license")
    out += ["## Licenses", ""]
    if old_lic != new_lic:
        out.append(f"- **Hermes project license: `{old_lic}` -> `{new_lic}`**")
    out += lic_files or ["No license or notice files changed in the upstream tree."]
    npm_lic = []
    by_path_old = {v.lock_path: v for v in old_node.values()}
    for v in new_node.values():
        o = by_path_old.get(v.lock_path)
        if o and o.license != v.license:
            npm_lic.append(f"- npm `{v.name}`: `{o.license}` -> `{v.license}`")
    out += npm_lic
    out += ["", "Python license metadata is not in uv.lock; `refresh-vendor-artifacts.sh` reads it from each new wheel "
            "and marks new records for human review.", ""]

    out += ["## Commits", ""] + [f"- {c}" for c in log[:200]]
    if len(log) > 200:
        out.append(f"- and {len(log) - 200} more")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Downloads and license inspection.


def download(url: str, dest: Path) -> bytes:
    say(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "offline-hermes-maintenance"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    return data


def sri_ok(data: bytes, integrity: str) -> bool:
    algo, _, digest = integrity.partition("-")
    return base64.b64encode(hashlib.new(algo, data).digest()).decode() == digest


def classify(license_text: str) -> str:
    t = license_text.upper()
    if not t:
        return "review_required"
    if re.search(r"\b(MPL|GPL|LGPL|EPL|CDDL)", t):
        return "source_and_notice_required"
    if "CC-BY" in t or "CC BY" in t:
        return "attribution_required"
    return "redistributable_with_notice"


def wheel_license(data: bytes) -> tuple[str, list]:
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = z.namelist()
        meta_name = next((n for n in names if n.endswith(".dist-info/METADATA")), None)
        declared = ""
        if meta_name:
            meta = email.parser.Parser().parsestr(z.read(meta_name).decode("utf-8", "replace"), headersonly=True)
            classifiers = [c for c in meta.get_all("Classifier") or [] if c.startswith("License ::")]
            lic = (meta.get("License") or "").strip()
            declared = (meta.get("License-Expression") or "").strip() or \
                (lic if lic and "\n" not in lic and len(lic) < 80 else "") or " OR ".join(classifiers)
        files = sorted(n for n in names if "/licenses/" in n or LICENSE_RE.search(n))
    return declared, files


def tarball_license(data: bytes) -> list:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
        return sorted(m.name for m in t.getmembers() if m.isfile() and LICENSE_RE.search(m.name))


# --------------------------------------------------------------------------
# refresh


REVIEW = "automated_refresh_metadata_and_archive_inspection"
REVIEWER = "scripts/refresh-vendor-artifacts.sh; human review pending"


def rewrite_licenses(py_new: dict, node_new: dict, kept_py: set, kept_node: set) -> str:
    lic = Manifest.load(MANIFESTS / "licenses.lock")
    new_blocks = {"python": [], "node": []}
    for b in lic.blocks:
        eco = b.fields["ecosystem"]
        if eco == "python" and b.fields["artifact_path"].rsplit("/", 1)[1] in kept_py:
            new_blocks["python"].append((b.fields["artifact_path"], b))
        elif eco == "node" and f"{b.fields['name']}@{b.fields['version']}" in kept_node:
            new_blocks["node"].append((b.fields["artifact_path"], b))
    for eco, records in (("python", py_new), ("node", node_new)):
        for path, fields in records.items():
            new_blocks[eco].append((path, Block(fields, render_block(fields, True))))
    py_order = {b.fields["path"]: i for i, b in enumerate(Manifest.load(MANIFESTS / "python.lock").blocks)}
    node_order = {b.fields["path"]: i for i, b in enumerate(Manifest.load(MANIFESTS / "node.lock").blocks)}
    ordered = [b for _, b in sorted(new_blocks["python"], key=lambda x: py_order[x[0]])]
    ordered += [b for _, b in sorted(new_blocks["node"], key=lambda x: node_order[x[0]])]
    ordered += [b for b in lic.blocks if b.fields["ecosystem"] not in ("python", "node")]

    header = lic.header
    counts = collections.Counter(b.fields["declared_license"] for b in ordered)
    vendored = sum(1 for b in ordered if b.fields["ecosystem"] != "upstream-source")
    no_file = sum(1 for b in ordered if b.fields.get("license_files") == [])
    header = set_header_value(header, "record_count", len(ordered))
    header = set_header_value(header, "vendored_artifacts", vendored)
    header = set_header_value(header, "artifacts_without_embedded_license_file", no_file)
    header = set_header_value(header, "unknown_required_licenses", sum(1 for b in ordered if b.fields.get("redistribution") == "review_required"))
    block = "[declared_license_counts]\n" + "".join(f"{toml_str(k)} = {counts[k]}\n" for k in sorted(counts))
    header = re.sub(r"\[declared_license_counts\]\n(?:.+\n)*", block, header)
    return header + "".join(b.text for b in ordered)


def write_if_changed(path: Path, text: str, today: str) -> bool:
    old = path.read_text(encoding="utf-8")
    if old == text:
        return False
    if re.search(r"^generated = ", text, re.M):
        text = set_header_value(text.split("[[artifact]]", 1)[0], "generated", today) + text[len(text.split("[[artifact]]", 1)[0]):]
    path.write_text(text, encoding="utf-8", newline="\n")
    return True


def refresh(dry_run: bool, report: Path | None, allow_blocking: bool, force_rewrite: bool = False) -> int:
    profile = load_profile()
    src = DirSource(REPO / UPSTREAM_DIR)
    plan, py, node = make_plan(src, profile)
    lines = [f"# Vendor refresh for upstream {read_lock_value('upstream.lock', 'commit')[:10]}", ""] + plan_markdown(plan, py, node)
    if report:
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    say("\n".join(lines))
    if plan.blocking and not allow_blocking:
        say("Refresh stopped: resolve the blocking items above (or pass --allow-blocking after review).")
        return 2
    if dry_run or (not plan.changed and not force_rewrite):
        say("No vendor changes needed." if not plan.changed else "Dry run: nothing was downloaded or written.")
        return 0

    today = dt.date.today().isoformat()
    py_dir, node_dir = REPO / profile["python"]["vendor_dir"], REPO / profile["node"]["vendor_dir"]
    staged, py_lic, node_lic, py_blocks, node_blocks = [], {}, {}, {}, {}
    try:
        for fn in plan.py_add:
            art = py[fn]
            data = download(art.url, py_dir / fn)
            if hashlib.sha256(data).hexdigest() != art.sha256:
                raise MaintError(f"{fn}: sha256 does not match uv.lock; nothing was written")
            declared, files = wheel_license(data)
            staged.append((py_dir / fn, data))
            rel = f"{profile['python']['vendor_dir']}/{fn}"
            redistribution = classify(declared)
            py_blocks[fn] = {"name": art.name, "version": art.version, "platform": profile["python"]["platforms"][0],
                             "python": f"cp{''.join(map(str, profile['python']['python_version']))}", "source_url": art.url,
                             "path": rel, "sha256": art.sha256, "license": declared, "redistribution": redistribution,
                             "purpose": "Hermes core runtime or PEP 517 build requirement",
                             "consumed_by": "Phase 3 local Python environment"}
            py_lic[rel] = license_fields("python", art.name, art.version, rel, art.sha256, declared, files, redistribution, art.url)
        for key in plan.node_add:
            art = node[key]
            data = download(art.url, node_dir / art.filename)
            if not sri_ok(data, art.integrity):
                raise MaintError(f"{key}: integrity does not match package-lock.json; nothing was written")
            sha = hashlib.sha256(data).hexdigest()
            files = tarball_license(data)
            staged.append((node_dir / art.filename, data))
            rel = f"{profile['node']['vendor_dir']}/{art.filename}"
            redistribution = classify(art.license)
            node_blocks[key] = {"name": art.name, "version": art.version, "platform": f"{profile['node']['os']}-{profile['node']['cpu']}",
                                "source_url": art.url, "path": rel, "sha256": sha, "npm_integrity": art.integrity,
                                "license": art.license, "redistribution": redistribution,
                                "purpose": "Electron desktop runtime/build dependency", "lock_path": art.lock_path,
                                "consumed_by": "Phase 3 offline npm materialization and desktop build"}
            node_lic[rel] = license_fields("node", art.name, art.version, rel, sha, art.license, files, redistribution, art.url)
    except (OSError, urllib.error.URLError) as exc:
        raise MaintError(f"download failed: {exc}; nothing was written") from exc

    # Everything downloaded and verified: write artifacts, then manifests.
    for path, data in staged:
        path.write_bytes(data)
    for fn in plan.py_remove:
        (py_dir / fn).unlink(missing_ok=True)
    for key in plan.node_remove:
        (REPO / current_node()[key].fields["path"]).unlink(missing_ok=True)

    kept_py = {fn for fn in py if fn not in plan.py_add}
    kept_node = {k for k in node if k not in plan.node_add}
    lic_text = None
    for name, kept, added, sort_key, trailing in (
            ("python.lock", kept_py, py_blocks, lambda b: b.fields["path"], False),
            ("node.lock", kept_node, node_blocks, lambda b: b.fields["lock_path"], True)):
        m = Manifest.load(MANIFESTS / name)
        by_id = current_python() if name == "python.lock" else current_node()
        blocks = [by_id[k] for k in kept] + [Block(f, render_block(f, True)) for f in added.values()]
        blocks.sort(key=sort_key)
        for b in blocks:  # python.lock ends without a blank line after the last block
            b.text = b.text.rstrip("\n") + "\n\n"
        text = set_header_value(m.header, "artifact_count", len(blocks)) + "".join(b.text for b in blocks)
        if not trailing:
            text = text.rstrip("\n") + "\n"
        write_if_changed(MANIFESTS / name, text, today)
    lic_text = rewrite_licenses(py_lic, node_lic, kept_py, kept_node)
    write_if_changed(MANIFESTS / "licenses.lock", lic_text, today)
    update_vendor_readme(len(py), len(node))
    write_checksums()
    say(f"Refreshed: +{len(plan.py_add)}/-{len(plan.py_remove)} wheels, +{len(plan.node_add)}/-{len(plan.node_remove)} npm tarballs.")
    say("Next: review the diff of manifests/, run scripts/verify-deps.sh, then the offline install and Phase 4 validation.")
    return 0


def license_fields(eco, name, version, path, sha, declared, files, redistribution, url) -> dict:
    return {"ecosystem": eco, "name": name, "version": version, "artifact_path": path, "artifact_sha256": sha,
            "declared_license": declared or "unknown", "license_files": files, "redistribution": redistribution,
            "source_url": url, "review_status": REVIEW, "reviewer": REVIEWER,
            "notes": ("License or notice files are embedded in the immutable artifact." if files else
                      "Declared license is recorded from package/release metadata; no standalone license file was found by archive-name inspection.")}


def update_vendor_readme(py_count: int, node_count: int) -> None:
    path = REPO / "vendor" / "README.md"
    text = path.read_text(encoding="utf-8")
    for prefix, count in (("| `python/", py_count), ("| `node/", node_count)):
        text = re.sub(rf"^({re.escape(prefix)}.*\| )[\d,]+ \|$", lambda m: f"{m.group(1)}{count:,} |", text, flags=re.M)
    if path.read_text(encoding="utf-8") != text:
        path.write_text(text, encoding="utf-8", newline="\n")


def write_checksums() -> None:
    """Rewrites manifests/checksums.sha256 over every file under vendor/.
    An unchanged path whose bytes no longer match its old checksum stops the
    refresh: that is corruption or tampering, not an update."""
    old = {}
    for row in (MANIFESTS / "checksums.sha256").read_text(encoding="utf-8").splitlines():
        if row.strip():
            digest, rel = row.split("  ", 1)
            old[rel] = digest
    rows, readme = [], "vendor/README.md"
    for path in sorted((REPO / "vendor").rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(REPO).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if rel in old and old[rel] != digest and rel != readme:
            raise MaintError(f"{rel} changed on disk but is not part of this refresh; checksums were not rewritten")
        rows.append(f"{digest}  {rel}")
    rows.sort(key=lambda r: r.split("  ", 1)[1])
    text = "\n".join(rows) + "\n"
    if (MANIFESTS / "checksums.sha256").read_text(encoding="utf-8") != text:
        (MANIFESTS / "checksums.sha256").write_text(text, encoding="utf-8", newline="\n")


# --------------------------------------------------------------------------
# check


def check() -> int:
    profile = load_profile()
    plan, py, node = make_plan(DirSource(REPO / UPSTREAM_DIR), profile)
    problems = []
    if plan.changed:
        problems.append(f"the selection rules do not reproduce the manifests: +{len(plan.py_add)}/-{len(plan.py_remove)} wheels "
                        f"({', '.join(plan.py_add + plan.py_remove)}), +{len(plan.node_add)}/-{len(plan.node_remove)} npm "
                        f"({', '.join(plan.node_add + plan.node_remove)})")
    problems += plan.blocking
    cur_node = current_node()
    for key, art in node.items():
        if cur_node[key].fields["lock_path"] != art.lock_path:
            problems.append(f"{key}: node.lock lock_path {cur_node[key].fields['lock_path']} != {art.lock_path}")
    for p in plan.pinned:
        say(f"  pinned {p}")
    for n in plan.notes:
        say(f"  note: {n}")
    if problems:
        for p in problems:
            say(f"FAIL: {p}")
        return 1
    say(f"Selection check passed: {len(py)} wheels and {len(node)} npm tarballs match manifests/python.lock and node.lock.")
    return 0


# --------------------------------------------------------------------------
# update-upstream


def read_lock_value(name: str, key: str) -> str:
    m = re.search(rf'^{key} = "(.*)"$', (MANIFESTS / name).read_text(encoding="utf-8"), re.M)
    if not m:
        raise MaintError(f"manifests/{name} has no {key}")
    return m.group(1)


def ensure_clone(git_dir: Path) -> None:
    if (git_dir / "HEAD").exists():
        return
    url = read_lock_value("upstream.lock", "repository")
    say(f"Creating a blobless bare clone of {url} in {git_dir} (online)...")
    git_dir.parent.mkdir(parents=True, exist_ok=True)
    git(None, "clone", "--bare", "--filter=blob:none", url, str(git_dir))


def fetch(git_dir: Path, ref: str) -> str:
    # A commit ID (full or abbreviated) already in the clone needs no fetch;
    # servers only accept full IDs anyway.
    if re.fullmatch(r"[0-9a-f]{7,40}", ref):
        r = subprocess.run(git_cmd(git_dir, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"), capture_output=True)
        if r.returncode == 0:
            return r.stdout.decode().strip()
    say(f"Fetching {ref} from upstream (online)...")
    git(git_dir, "fetch", "--filter=blob:none", "origin", ref)
    return git(git_dir, "rev-parse", "FETCH_HEAD^{commit}").strip()


def long_path(p: Path) -> str:
    s = str(p.resolve())
    return "\\\\?\\" + s if os.name == "nt" and not s.startswith("\\\\?\\") else s


def align_index_modes(git_dir: Path, commit: str) -> None:
    """Gives every imported index entry upstream's mode. Git on Windows adds
    files as 100644 (no executable bit, symlinks as files); the content is the
    same blob, so only the mode is corrected. Any path whose content or
    presence differs stops the import."""
    def entries(text: str, object_field: int, strip: str = "") -> dict:
        # ls-tree: "<mode> <type> <object>\t<path>"; ls-files -s: "<mode> <object> <stage>\t<path>"
        out = {}
        for row in text.splitlines():
            meta, path = row.split("\t", 1)
            parts = meta.split()
            out[path[len(strip):] if strip else path] = (parts[0], parts[object_field])
        return out
    upstream = entries(git(git_dir, "ls-tree", "-r", "--full-tree", commit), 2)
    ours = entries(git(None, "-C", str(REPO), "ls-files", "-s", UPSTREAM_DIR), 1, UPSTREAM_DIR + "/")
    missing = sorted(set(upstream) - set(ours))
    extra = sorted(set(ours) - set(upstream))
    differs = sorted(p for p in set(upstream) & set(ours) if upstream[p][1] != ours[p][1])
    if missing or extra or differs:
        detail = []
        for label, items in (("missing", missing), ("not in upstream", extra), ("content differs", differs)):
            if items:
                detail.append(f"{label} ({len(items)}): " + ", ".join(items[:10]) + (" ..." if len(items) > 10 else ""))
        raise MaintError("the imported files do not match upstream: " + "; ".join(detail) +
                         ". The index holds the partial import; reset it with git reset --hard.")
    fixes = [f"{mode} {blob}\t{UPSTREAM_DIR}/{path}" for path, (mode, blob) in upstream.items() if ours[path][0] != mode]
    if fixes:
        r = subprocess.run(git_cmd(None, "-C", str(REPO), "update-index", "--index-info"),
                           input="\n".join(fixes).encode() + b"\n", capture_output=True)
        if r.returncode:
            raise MaintError(f"git update-index failed: {r.stderr.decode('utf-8', 'replace')}")
        say(f"Set upstream's file mode on {len(fixes)} entries (executable bits, symlinks).")


def update_upstream(git_dir: Path, ref: str, branch: bool, allow_dirty: bool) -> int:
    dirty = git(None, "-C", str(REPO), "status", "--porcelain").strip()
    if dirty and not allow_dirty:
        raise MaintError("the repository has uncommitted changes; commit or stash them first")
    ensure_clone(git_dir)
    old = read_lock_value("upstream.lock", "commit")
    new = fetch(git_dir, ref)
    if new == old:
        say(f"upstream/hermes-agent is already at {new}.")
        return 0
    # The pinned commit must be in the clone for the surface diff.
    if subprocess.run(git_cmd(git_dir, "cat-file", "-e", f"{old}^{{commit}}"), capture_output=True).returncode:
        git(git_dir, "fetch", "--filter=blob:none", "origin", old)
    tree = git(git_dir, "rev-parse", f"{new}^{{tree}}").strip()
    date = git(git_dir, "show", "-s", "--format=%cI", new).strip()
    date = dt.datetime.fromisoformat(date).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if branch:
        name = f"upstream-update/{new[:10]}"
        git(None, "-C", str(REPO), "switch", "-c", name)
        say(f"Created branch {name}.")

    target = REPO / UPSTREAM_DIR
    with tempfile.TemporaryDirectory(prefix="ohmaint-import-") as tmp:
        extract = Path(tmp) / "tree"
        extract.mkdir()
        # read-tree -u with a private index: the clone's own index is never
        # touched, and a blobless clone fetches missing contents in batches.
        say(f"Checking out {new[:10]} into a temporary tree (fetches file contents; online)...")
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        r = subprocess.run(git_cmd(git_dir, "--work-tree", long_path(extract), "read-tree", "-u", "--reset", new),
                           capture_output=True, env=env)
        if r.returncode:
            raise MaintError(f"checkout of {new} failed: {r.stderr.decode('utf-8', 'replace').strip()}")
        git(None, "-C", str(REPO), "rm", "-r", "-q", "--cached", UPSTREAM_DIR)
        shutil.rmtree(long_path(target))
        shutil.move(long_path(extract), long_path(target))
    # -f: upstream tracks some files its own .gitignore matches.
    git(None, "-C", str(REPO), "add", "-A", "-f", UPSTREAM_DIR)
    align_index_modes(git_dir, new)
    imported = git(None, "-C", str(REPO), "write-tree", f"--prefix={UPSTREAM_DIR}/").strip()
    if imported != tree:
        raise MaintError(f"imported tree {imported} != upstream tree {tree}. The import is not byte-identical; "
                         "the index holds the partial import, reset it with git reset --hard.")
    say(f"Imported upstream {new[:10]}: tree {tree} matches.")

    lock = (MANIFESTS / "upstream.lock").read_text(encoding="utf-8")
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for key, value in (("commit", new), ("tree", tree), ("commit_date", date), ("imported_at", now)):
        lock = re.sub(rf'^{key} = ".*"$', f'{key} = "{value}"', lock, flags=re.M)
    (MANIFESTS / "upstream.lock").write_text(lock, encoding="utf-8", newline="\n")

    report = REPORTS / f"{old[:10]}..{new[:10]}.md"
    REPORTS.mkdir(parents=True, exist_ok=True)
    report.write_text(surface(git_dir, old, new, load_profile()), encoding="utf-8", newline="\n")
    git(None, "-C", str(REPO), "add", str(MANIFESTS / "upstream.lock"), str(report))
    say(f"Surface report: {report.relative_to(REPO).as_posix()}")
    say("Staged, not committed. Next: review the report, update patches if any do not apply, then run "
        "scripts/refresh-vendor-artifacts.sh --dry-run and scripts/refresh-vendor-artifacts.sh.")
    return 0


# --------------------------------------------------------------------------


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(prog="ohmaint.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="verify the profile reproduces python.lock and node.lock (local only)")
    s = sub.add_parser("surface", help="dependency surface diff between two upstream commits")
    s.add_argument("--git", type=Path, default=Path(os.environ.get("OFFLINE_HERMES_UPSTREAM_GIT", DEFAULT_GIT)))
    s.add_argument("--old", help="default: the commit in manifests/upstream.lock")
    s.add_argument("--new", required=True)
    s.add_argument("--out", type=Path)
    u = sub.add_parser("update-upstream", help="import a new upstream commit (online)")
    u.add_argument("--git", type=Path, default=Path(os.environ.get("OFFLINE_HERMES_UPSTREAM_GIT", DEFAULT_GIT)))
    u.add_argument("--ref", default="main")
    u.add_argument("--no-branch", action="store_true")
    u.add_argument("--allow-dirty", action="store_true")
    r = sub.add_parser("refresh", help="re-vendor wheels and npm tarballs for the imported upstream (online)")
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--report", type=Path)
    r.add_argument("--allow-blocking", action="store_true")
    # Test hook: regenerate every manifest even when nothing changed. On an
    # unchanged upstream the files must come out byte-identical.
    r.add_argument("--force-rewrite", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "check":
            return check()
        if args.cmd == "surface":
            ensure_clone(args.git)
            text = surface(args.git, args.old or read_lock_value("upstream.lock", "commit"), args.new, load_profile())
            if args.out:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(text, encoding="utf-8", newline="\n")
                say(f"Wrote {args.out}")
            else:
                sys.stdout.write(text)
            return 0
        if args.cmd == "update-upstream":
            return update_upstream(args.git, args.ref, not args.no_branch, args.allow_dirty)
        if args.cmd == "refresh":
            return refresh(args.dry_run, args.report, args.allow_blocking, args.force_rewrite)
    except MaintError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
