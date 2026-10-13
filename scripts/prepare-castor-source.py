#!/usr/bin/env python3
"""Export the current release candidate locally without Git history or publication."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_ADDITIONS = {"docs/CASTOR_MIGRATION.md", "scripts/prepare-castor-source.py"}
LOCAL_PARTS = {
    ".git", ".claude", ".codex", ".build", ".swiftpm", "Arils_Dataset",
    ".venv", "venv", "dist", "layer-eval-report", "__pycache__", "xcuserdata",
    ".pomegranate-tts", ".pomegranate-lama", ".pomegranate-pointer", ".pomegranate-anime-face",
    ".castor-tts", ".castor-lama", ".castor-pointer", ".castor-anime-face",
}
LOCAL_NAMES = {"AGENTS.md", "HANDOFF_CODEX.md", "X_PROMOTION_PLAN.md", "temporary.md", ".DS_Store"}
SENSITIVE_SUFFIXES = {".p12", ".cer", ".p8", ".pem", ".key", ".keychain", ".keychain-db"}
TEXT_CHECKS = {
    "credential pattern": re.compile(
        r"ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}"
        r"|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    ),
    "personal home path": re.compile(r"/(?:Users|home)/[^/\s\"']+"),
    "Apple team ID": re.compile(r"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}"),
}


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def renamed_path(relative):
    """Include known uncommitted renames without collecting arbitrary untracked files."""
    parts = []
    for part in Path(relative).parts:
        name = part.replace("Pomegranate", "Castor").replace("pomegranate", "Castor").replace("Pome", "Castor")
        parts.append("castor-core-check.yml" if name == "Castor-core-check.yml" else name)
    return Path(*parts).as_posix()


def prepare(output):
    output = output.resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError("Choose an output folder outside the source checkout.")
    if output.exists():
        raise ValueError("Output already exists; choose a new folder to avoid overwriting it.")
    tracked = {p for p in git("ls-files", "--cached", "-z").decode().split("\0") if p}
    tracked = {p if (ROOT / p).exists() else renamed_path(p) for p in tracked}
    payload = []
    omitted = []
    for relative in sorted(tracked | PUBLIC_ADDITIONS):
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Invalid source path.")
        if (set(path.parts) & LOCAL_PARTS or path.name in LOCAL_NAMES
                or path.name.startswith(".env") or path.name.endswith(".local")
                or path.suffix.lower() in SENSITIVE_SUFFIXES):
            omitted.append(relative)
            continue
        source = ROOT / path
        if source.is_symlink():
            raise ValueError(f"Review symbolic link before export: {relative}")
        if not source.is_file():
            if relative in PUBLIC_ADDITIONS:
                raise ValueError(f"Missing preparation file: {relative}")
            omitted.append(relative)
            continue
        data = source.read_bytes()
        if b"\0" not in data:
            content = data.decode("utf-8", errors="replace")
            for label, pattern in TEXT_CHECKS.items():
                if pattern.search(content):
                    raise ValueError(f"Review {label} in: {relative}")
        payload.append((relative, data, source.stat().st_mode & 0o777))

    manifest = {
        "project": "Castor",
        "sourceCommit": git("rev-parse", "HEAD").decode().strip(),
        "includesWorkingTreeChanges": True,
        "historyIncluded": False,
        "checkScope": "Known filename and text patterns only; not a full secret or license audit.",
        "omittedTrackedFiles": omitted,
        "files": [{"path": name, "sha256": hashlib.sha256(data).hexdigest()}
                  for name, data, _ in payload],
    }
    source_root = output / "Castor"
    source_root.mkdir(parents=True)
    for name, data, mode in payload:
        destination = source_root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(mode)
    (output / "migration-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    archive = shutil.make_archive(str(output / "Castor-source-preparation"), "zip", output, "Castor")
    print(f"Prepared {len(payload)} files in {source_root}")
    print(f"Source archive: {archive}")
    print("No account, remote, repository, or publication settings were changed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New local output folder")
    args = parser.parse_args()
    try:
        prepare(args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
