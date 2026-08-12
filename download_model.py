"""
download_model.py — General-purpose Hugging Face repository downloader.

Downloads any model, dataset, or Space from Hugging Face with:
  • aria2c batch download (parallel, resumable) with progress watchdog
  • Automatic aria2c provisioning (Windows: downloads portable binary)
  • Fallback to huggingface_hub snapshot_download when aria2 unavailable
  • Gated-repo detection with helpful error messages
  • DOWNLOAD_COMPLETE / MODEL_SOURCE.txt completion markers
  • Never deletes already-downloaded data

Usage (positional – backwards-compatible):
    python download_model.py "<repo_id>" "<dest_dir>"

Usage (full flags):
    python download_model.py "<repo_id>" "<dest_dir>" \\
        [--subdir NAME] \\
        [--repo-type {model,dataset,space}] \\
        [--revision REV] \\
        [--allow PATTERN ...] \\
        [--ignore PATTERN ...] \\
        [--include-default-ignores | --no-default-ignores] \\
        [--threads N] [--concurrent N] \\
        [--token TOKEN] \\
        [--no-aria2] \\
        [--force]

Examples:
    # Download a model (default subdir "model/"):
    python download_model.py "black-forest-labs/FLUX.2-klein-4B" "ai-model"

    # Download only .safetensors files to a custom subdir:
    python download_model.py "stabilityai/stable-diffusion-xl-base-1.0" "ai" \\
        --subdir sd_xl --allow "*.safetensors"

    # Download a dataset:
    python download_model.py "HuggingFaceH4/ultrachat_200k" "datasets" \\
        --repo-type dataset --subdir ultrachat

    # Download ACE-Step checkpoints:
    python download_model.py "ACE-Step/acestep-v15-base" "ai" --subdir checkpoints
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from pathlib import Path
import re
from typing import List, Optional

# ---------------------------------------------------------------------------
# Default ignore patterns (generic – no tool-specific entries)
# Callers can override via --ignore / ignore= or extend via DEFAULT_IGNORE_PATTERNS.
# ---------------------------------------------------------------------------
DEFAULT_IGNORE_PATTERNS: List[str] = [
    "*.gguf",
    "*.gguf.part",
    "*.mp4",
    "*.webm",
    "*.avi",
    "*.mov",
    "*.mkv",
    "*.mp3",
    "*.wav",
    "*.flac",
    "*.ogg",
    "*.png",
    "*.jpg",
    "*.jpeg",
    "*.gif",
    "*.webp",
]

ARIA2_THREADS = 8
ARIA2_CONCURRENT = 4
STALL_WARN_SECONDS = 60  # warn if bytes-on-disk don't change for this long
POLL_INTERVAL = 5  # seconds between progress checks


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _get_token(explicit: Optional[str] = None) -> Optional[str]:
    if explicit:
        return explicit
    for var in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        val = os.environ.get(var)
        if val:
            return val
    try:
        from huggingface_hub import get_token  # type: ignore
        return get_token()
    except Exception:
        return None


def _dir_bytes(path: Path) -> int:
    """Return total bytes currently on disk under *path*."""
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except OSError:
        pass
    return total


def _matches_any(name: str, patterns: List[str]) -> bool:
    return any(fnmatch.fnmatch(name, p) for p in patterns)


def _safe_isinstance(obj: object, klass: Optional[type]) -> bool:
    return bool(klass) and isinstance(obj, klass)


def _load_hf_exception_types() -> dict:
    classes = {
        "GatedRepoError": None,
        "RepositoryNotFoundError": None,
        "RevisionNotFoundError": None,
        "HfHubHTTPError": None,
    }
    for module_name in ("huggingface_hub.errors", "huggingface_hub.utils"):
        try:
            module = __import__(module_name, fromlist=list(classes.keys()))
            for name in classes:
                classes[name] = classes[name] or getattr(module, name, None)
        except Exception:
            continue
    return classes


def _http_status_from_exc(exc: Exception) -> Optional[int]:
    status = getattr(exc, "status_code", None)
    if isinstance(status, int):
        return status
    response = getattr(exc, "response", None)
    response_status = getattr(response, "status_code", None)
    if isinstance(response_status, int):
        return response_status
    msg = str(exc)
    match = re.search(r"\b([1-5]\d{2})\b", msg)
    if match:
        try:
            return int(match.group(1))
        except ValueError:
            return None
    return None


def _is_likely_gated_message(exc: Exception) -> bool:
    msg = str(exc).lower()
    return "gated" in msg and ("accept" in msg or "license" in msg or "access request" in msg)


def _is_likely_revision_not_found_message(exc: Exception) -> bool:
    msg = str(exc).lower()
    return "revision" in msg and ("not found" in msg or "doesn't exist" in msg or "does not exist" in msg)


def _unwrap_exception(exc: Exception) -> Exception:
    cause = getattr(exc, "__cause__", None)
    if isinstance(cause, Exception):
        return cause
    return exc


def _classify_hf_error(exc: Exception, repo_id: str, revision: str) -> tuple[str, str]:
    base_exc = _unwrap_exception(exc)
    exc_types = _load_hf_exception_types()
    repo_url = f"https://huggingface.co/{repo_id}"
    revision_url = f"{repo_url}/tree/{revision}"
    status = _http_status_from_exc(base_exc)

    if _safe_isinstance(base_exc, exc_types["GatedRepoError"]) or (
        exc_types["GatedRepoError"] is None and _is_likely_gated_message(base_exc)
    ):
        return (
            "gated",
            "[download_model] This repository is gated and requires access approval/license acceptance.\n"
            f"  Model page: {repo_url}\n"
            "  1. Sign in and accept the model license/access request.\n"
            "  2. Set HF_TOKEN=<your_token> and re-run."
        )

    if _safe_isinstance(base_exc, exc_types["RevisionNotFoundError"]) or (
        exc_types["RevisionNotFoundError"] is None
        and status == 404
        and _is_likely_revision_not_found_message(base_exc)
    ):
        return (
            "revision_not_found",
            "[download_model] Revision not found for this repository.\n"
            f"  Attempted revision URL: {revision_url}\n"
            "  Verify --revision (branch/tag/commit) and re-run."
        )

    # For compatibility across hub versions, raw 404 defaults to repo-not-found
    # after explicit revision-not-found handling above.
    if _safe_isinstance(base_exc, exc_types["RepositoryNotFoundError"]) or status == 404:
        return (
            "repo_not_found",
            "[download_model] Repository not found or invalid repo ID.\n"
            f"  Attempted: {repo_url}\n"
            "  Verify the installer's REPO_ID value and try again."
        )

    if status in (401, 403):
        return (
            "auth",
            "[download_model] Authentication or private-repository access failure.\n"
            f"  Attempted: {repo_url}\n"
            "  Ensure your HF token is set (HF_TOKEN) and has access to this repo."
        )

    if _safe_isinstance(base_exc, exc_types["HfHubHTTPError"]):
        return (
            "http_error",
            "[download_model] Hugging Face API/network error while accessing the repository.\n"
            f"  URL: {repo_url}\n"
            f"  Details: {base_exc}"
        )

    return (
        "other_error",
        "[download_model] Unexpected error while listing/downloading repository files.\n"
        f"  URL: {repo_url}\n"
        f"  Details: {exc}"
    )


# ---------------------------------------------------------------------------
# aria2c provisioning
# ---------------------------------------------------------------------------

ARIA2_WIN_URL = (
    "https://github.com/aria2/aria2/releases/download/release-1.37.0/"
    "aria2-1.37.0-win-64bit-build1.zip"
)
_ARIA2_LOCAL_DIR = Path(__file__).parent / "_aria2"


def _find_aria2() -> Optional[str]:
    # Check PATH first
    found = shutil.which("aria2c")
    if found:
        return found
    # Check our local provisioned copy
    local = _ARIA2_LOCAL_DIR / "aria2c.exe"
    if local.exists():
        return str(local)
    return None


def _provision_aria2_windows() -> Optional[str]:
    """Download portable aria2c for Windows if not already present."""
    _ARIA2_LOCAL_DIR.mkdir(parents=True, exist_ok=True)
    exe = _ARIA2_LOCAL_DIR / "aria2c.exe"
    if exe.exists():
        return str(exe)
    print(f"[download_model] aria2c not found — downloading portable binary …")
    try:
        zip_path = _ARIA2_LOCAL_DIR / "aria2.zip"
        urllib.request.urlretrieve(ARIA2_WIN_URL, zip_path)
        with zipfile.ZipFile(zip_path) as zf:
            for member in zf.namelist():
                if member.endswith("aria2c.exe"):
                    zf.extract(member, _ARIA2_LOCAL_DIR)
                    # Move to top-level
                    extracted = _ARIA2_LOCAL_DIR / member
                    shutil.move(str(extracted), str(exe))
                    break
        zip_path.unlink(missing_ok=True)
        # Clean up extracted subdir
        for item in _ARIA2_LOCAL_DIR.iterdir():
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
        if exe.exists():
            print(f"[download_model] aria2c provisioned at {exe}")
            return str(exe)
    except Exception as exc:
        print(f"[download_model] Warning: could not provision aria2c: {exc}")
    return None


def _ensure_aria2() -> Optional[str]:
    aria2 = _find_aria2()
    if aria2:
        return aria2
    if platform.system() == "Windows":
        return _provision_aria2_windows()
    return None


# ---------------------------------------------------------------------------
# File listing
# ---------------------------------------------------------------------------

def _list_files(
    api,
    repo_id: str,
    repo_type: str,
    revision: str,
    token: Optional[str],
) -> List[str]:
    """Return list of file paths in the repo."""
    try:
        if repo_type == "model":
            info = api.model_info(repo_id, revision=revision, token=token)
        elif repo_type == "dataset":
            info = api.dataset_info(repo_id, revision=revision, token=token)
        else:
            info = api.space_info(repo_id, revision=revision, token=token)
        siblings = info.siblings or []
        return [s.rfilename for s in siblings]
    except Exception as exc:
        raise RuntimeError(f"Failed to list files for {repo_id}") from exc


def _filter_files(
    files: List[str],
    allow: Optional[List[str]],
    ignore: Optional[List[str]],
    use_default_ignores: bool,
) -> List[str]:
    effective_ignore: List[str] = []
    if use_default_ignores:
        effective_ignore.extend(DEFAULT_IGNORE_PATTERNS)
    if ignore:
        effective_ignore.extend(ignore)

    result = []
    for f in files:
        name = Path(f).name
        if allow and not _matches_any(name, allow) and not _matches_any(f, allow):
            continue
        if effective_ignore and (_matches_any(name, effective_ignore) or _matches_any(f, effective_ignore)):
            continue
        result.append(f)
    return result


# ---------------------------------------------------------------------------
# aria2c download
# ---------------------------------------------------------------------------

def _build_input_file(
    files: List[str],
    repo_id: str,
    repo_type: str,
    revision: str,
    dest_dir: Path,
    token: Optional[str],
) -> Path:
    """Build an aria2 input file and return its path."""
    from huggingface_hub import hf_hub_url  # type: ignore

    lines = []
    for rel_path in files:
        url = hf_hub_url(
            repo_id=repo_id,
            filename=rel_path,
            repo_type=repo_type,
            revision=revision,
        )
        out_file = dest_dir / rel_path
        out_file.parent.mkdir(parents=True, exist_ok=True)
        lines.append(url)
        lines.append(f"  dir={out_file.parent}")
        lines.append(f"  out={out_file.name}")
        if token:
            lines.append(f"  header=Authorization: ******")
        lines.append("")

    tmp = tempfile.NamedTemporaryFile(
        mode="w", suffix=".txt", delete=False, encoding="utf-8"
    )
    tmp.write("\n".join(lines))
    tmp.close()
    return Path(tmp.name)


def _progress_watchdog(dest_dir: Path, stop_event: threading.Event) -> None:
    """Periodically print download progress until stop_event is set."""
    last_bytes = 0
    last_change_time = time.time()
    start_time = time.time()

    while not stop_event.is_set():
        time.sleep(POLL_INTERVAL)
        now = time.time()
        cur_bytes = _dir_bytes(dest_dir)
        elapsed = now - start_time
        delta = cur_bytes - last_bytes

        if delta > 0:
            last_bytes = cur_bytes
            last_change_time = now
            speed = delta / POLL_INTERVAL / 1024 / 1024  # MB/s

            # We don't know total size easily so just show bytes
            print(
                f"[download_model] Progress: {cur_bytes / 1024 / 1024:.1f} MB  "
                f"speed={speed:.2f} MB/s  elapsed={elapsed:.0f}s",
                flush=True,
            )
        else:
            stall = now - last_change_time
            if stall >= STALL_WARN_SECONDS:
                print(
                    f"[download_model] Warning: no new bytes for {stall:.0f}s "
                    f"({cur_bytes / 1024 / 1024:.1f} MB on disk). "
                    "Download may be stalled.",
                    flush=True,
                )


def _aria2_download(
    aria2_bin: str,
    input_file: Path,
    threads: int,
    concurrent: int,
) -> bool:
    cmd = [
        aria2_bin,
        "--input-file", str(input_file),
        "--max-connection-per-server", str(threads),
        "--split", str(threads),
        "--max-concurrent-downloads", str(concurrent),
        "--continue=true",
        "--auto-file-renaming=false",
        "--allow-overwrite=false",
        "--console-log-level=warn",
    ]
    print(f"[download_model] Running: {' '.join(cmd[:3])} ... (aria2c)")
    result = subprocess.run(cmd)
    return result.returncode == 0


# ---------------------------------------------------------------------------
# snapshot_download fallback
# ---------------------------------------------------------------------------

def _snapshot_download_fallback(
    repo_id: str,
    dest_dir: Path,
    repo_type: str,
    revision: str,
    allow: Optional[List[str]],
    ignore: Optional[List[str]],
    use_default_ignores: bool,
    token: Optional[str],
) -> bool:
    from huggingface_hub import snapshot_download  # type: ignore

    effective_ignore: List[str] = []
    if use_default_ignores:
        effective_ignore.extend(DEFAULT_IGNORE_PATTERNS)
    if ignore:
        effective_ignore.extend(ignore)

    kwargs = dict(
        repo_id=repo_id,
        local_dir=str(dest_dir),
        repo_type=repo_type,
        revision=revision,
        token=token,
        ignore_patterns=effective_ignore or None,
    )
    if allow:
        kwargs["allow_patterns"] = allow

    print(f"[download_model] Using snapshot_download fallback …")
    try:
        snapshot_download(**kwargs)
        return True
    except Exception as exc:
        _kind, message = _classify_hf_error(exc, repo_id, revision)
        print(message)
        return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def download_repo(
    repo_id: str,
    dest: str,
    *,
    subdir: str = "model",
    repo_type: str = "model",
    revision: str = "main",
    allow: Optional[List[str]] = None,
    ignore: Optional[List[str]] = None,
    include_default_ignores: Optional[bool] = None,
    token: Optional[str] = None,
    use_aria2: bool = True,
    threads: int = ARIA2_THREADS,
    concurrent: int = ARIA2_CONCURRENT,
    force: bool = False,
) -> bool:
    """
    Download a Hugging Face repository to *dest/subdir/*.

    Parameters
    ----------
    repo_id:
        HF repo ID, e.g. ``"black-forest-labs/FLUX.2-klein-4B"``.
    dest:
        Parent directory (created if needed).
    subdir:
        Subdirectory under *dest* where files land (default ``"model"``).
    repo_type:
        ``"model"``, ``"dataset"``, or ``"space"``.
    revision:
        Git revision / branch / tag (default ``"main"``).
    allow:
        Glob allow-list; when given, only matching files are downloaded.
    ignore:
        Extra glob ignore patterns (in addition to, or replacing, defaults).
    include_default_ignores:
        If ``None`` (default): apply DEFAULT_IGNORE_PATTERNS only when *allow*
        is not given. If ``True``/``False``: explicit override.
    token:
        Explicit HF token; falls back to env vars / ``huggingface-cli login``.
    use_aria2:
        Try aria2c first (default ``True``); falls back to snapshot_download.
    threads:
        aria2c ``--max-connection-per-server`` / ``--split``.
    concurrent:
        aria2c ``--max-concurrent-downloads``.
    force:
        If ``True``, ignore existing ``DOWNLOAD_COMPLETE`` marker.

    Returns
    -------
    bool
        ``True`` on success.
    """
    from huggingface_hub import HfApi  # type: ignore

    dest_dir = Path(dest) / subdir
    dest_dir.mkdir(parents=True, exist_ok=True)

    complete_marker = dest_dir / "DOWNLOAD_COMPLETE"
    source_file = dest_dir / "MODEL_SOURCE.txt"

    if complete_marker.exists() and not force:
        print(f"[download_model] {dest_dir} already complete (DOWNLOAD_COMPLETE present). Use --force to re-verify.")
        return True

    resolved_token = _get_token(token)

    # Determine whether to apply default ignores
    if include_default_ignores is None:
        use_default_ignores = (allow is None)
    else:
        use_default_ignores = include_default_ignores

    print(f"[download_model] Repo       : {repo_id}")
    print(f"[download_model] Type       : {repo_type}")
    print(f"[download_model] Revision   : {revision}")
    print(f"[download_model] Destination: {dest_dir}")

    api = HfApi()

    # List files
    try:
        all_files = _list_files(api, repo_id, repo_type, revision, resolved_token)
    except Exception as exc:
        _kind, message = _classify_hf_error(exc, repo_id, revision)
        print(message)
        return False

    filtered = _filter_files(all_files, allow, ignore, use_default_ignores)
    print(f"[download_model] Files      : {len(all_files)} total, {len(filtered)} to download")

    if not filtered:
        print("[download_model] No files to download after filtering.")
        return False

    success = False

    if use_aria2:
        aria2_bin = _ensure_aria2()
        if aria2_bin:
            input_file = _build_input_file(
                filtered, repo_id, repo_type, revision, dest_dir, resolved_token
            )
            stop_evt = threading.Event()
            watcher = threading.Thread(
                target=_progress_watchdog, args=(dest_dir, stop_evt), daemon=True
            )
            watcher.start()
            try:
                success = _aria2_download(aria2_bin, input_file, threads, concurrent)
            finally:
                stop_evt.set()
                watcher.join(timeout=2)
            try:
                input_file.unlink(missing_ok=True)
            except Exception:
                pass
            if not success:
                print("[download_model] aria2c reported errors — falling back to snapshot_download.")
        else:
            print("[download_model] aria2c not available — using snapshot_download.")

    if not success:
        success = _snapshot_download_fallback(
            repo_id, dest_dir, repo_type, revision,
            allow, ignore, use_default_ignores, resolved_token
        )

    if success:
        complete_marker.write_text("OK\n")
        source_file.write_text(
            f"repo_id={repo_id}\nrepo_type={repo_type}\nrevision={revision}\n"
        )
        print(f"[download_model] ✓ Download complete → {dest_dir}")

    return success


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="download_model.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("repo_id", help="Hugging Face repo ID, e.g. 'black-forest-labs/FLUX.2-klein-4B'")
    p.add_argument("dest", metavar="ai_dir", help="Parent destination directory")
    p.add_argument("--subdir", default="model",
                   help="Subdirectory under dest (default: model)")
    p.add_argument("--repo-type", default="model",
                   choices=["model", "dataset", "space"],
                   help="Repository type (default: model)")
    p.add_argument("--revision", default="main",
                   help="Git revision / branch / tag (default: main)")
    p.add_argument("--allow", metavar="PATTERN", action="append",
                   help="Glob allow-list (repeatable); only matching files are downloaded")
    p.add_argument("--ignore", metavar="PATTERN", action="append",
                   help="Extra glob ignore patterns (repeatable)")
    inc = p.add_mutually_exclusive_group()
    inc.add_argument("--include-default-ignores", dest="default_ignores",
                     action="store_true", default=None,
                     help="Always apply built-in media/GGUF ignore list")
    inc.add_argument("--no-default-ignores", dest="default_ignores",
                     action="store_false",
                     help="Skip built-in ignore list even without --allow")
    p.add_argument("--threads", type=int, default=ARIA2_THREADS,
                   help=f"aria2c connections per server (default: {ARIA2_THREADS})")
    p.add_argument("--concurrent", type=int, default=ARIA2_CONCURRENT,
                   help=f"aria2c concurrent downloads (default: {ARIA2_CONCURRENT})")
    p.add_argument("--token", default=None,
                   help="Explicit HF token (falls back to env / huggingface-cli login)")
    p.add_argument("--no-aria2", dest="no_aria2", action="store_true",
                   help="Skip aria2c and use snapshot_download directly")
    p.add_argument("--force", action="store_true",
                   help="Re-download even if DOWNLOAD_COMPLETE marker is present")
    return p


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    ok = download_repo(
        repo_id=args.repo_id,
        dest=args.dest,
        subdir=args.subdir,
        repo_type=args.repo_type,
        revision=args.revision,
        allow=args.allow,
        ignore=args.ignore,
        include_default_ignores=args.default_ignores,
        token=args.token,
        use_aria2=not args.no_aria2,
        threads=args.threads,
        concurrent=args.concurrent,
        force=args.force,
    )
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
