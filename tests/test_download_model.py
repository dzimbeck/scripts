import contextlib
import io
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import download_model


def _fake_huggingface_hub() -> types.ModuleType:
    module = types.ModuleType("huggingface_hub")

    class HfApi:
        pass

    def hf_hub_url(*, filename: str, **_kwargs: str) -> str:
        return f"https://example.invalid/{filename}"

    module.HfApi = HfApi
    module.hf_hub_url = hf_hub_url
    module.snapshot_download = lambda **_kwargs: None
    return module


class FakeStopEvent:
    def __init__(self, iterations: int):
        self.iterations = iterations
        self.calls = 0

    def wait(self, _timeout: float) -> bool:
        self.calls += 1
        return self.calls > self.iterations


class DownloadModelTests(unittest.TestCase):
    def test_filter_files_respects_default_ignore_overrides(self) -> None:
        files = ["model.safetensors", "preview.png", "notes/readme.txt"]

        filtered_default = download_model._filter_files(
            files, allow=None, ignore=None, use_default_ignores=True
        )
        filtered_full = download_model._filter_files(
            files, allow=None, ignore=None, use_default_ignores=False
        )

        self.assertEqual(filtered_default, ["model.safetensors", "notes/readme.txt"])
        self.assertEqual(filtered_full, files)

    def test_find_missing_downloads_skips_non_downloadable_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            dest_dir = Path(tmpdir)
            download_model._repo_file_path(dest_dir, "config.json").write_text("{}")

            missing = download_model._find_missing_downloads(
                ["config.json", "nested/model.safetensors", "refs/", ""], dest_dir
            )

        self.assertEqual(missing, ["nested/model.safetensors"])

    def test_progress_watchdog_rate_limits_stall_notices(self) -> None:
        output = io.StringIO()
        stop_event = FakeStopEvent(iterations=4)

        with contextlib.redirect_stdout(output), mock.patch.object(
            download_model, "POLL_INTERVAL", 1
        ), mock.patch.object(
            download_model, "STALL_WARN_SECONDS", 3
        ), mock.patch.object(
            download_model, "_dir_bytes", return_value=1024
        ), mock.patch.object(
            download_model.time, "time", side_effect=[0.0, 0.0, 3.0, 4.0, 5.0, 6.0]
        ):
            download_model._progress_watchdog(Path("."), stop_event)

        lines = [line for line in output.getvalue().splitlines() if "apparent file size" in line]
        self.assertEqual(len(lines), 2)
        self.assertTrue(all("Note:" in line for line in lines))

    def test_download_repo_falls_back_after_aria2_failure_without_logging_token(self) -> None:
        token = "hf_secret_token"
        state = {}

        def fake_aria2(_aria2_bin: str, input_file: Path, *_args: int) -> bool:
            state["input_file"] = input_file
            state["input_text"] = input_file.read_text()
            return False

        with tempfile.TemporaryDirectory() as tmpdir:
            dest_root = Path(tmpdir)
            dest_dir = dest_root / "model"
            output = io.StringIO()
            fake_hf = _fake_huggingface_hub()

            def fake_snapshot(*_args, **_kwargs) -> bool:
                model_path = download_model._repo_file_path(dest_dir, "weights/model.safetensors")
                model_path.parent.mkdir(parents=True, exist_ok=True)
                model_path.write_bytes(b"ok")
                return True

            with contextlib.redirect_stdout(output), mock.patch.dict(
                sys.modules, {"huggingface_hub": fake_hf}
            ), mock.patch.object(
                download_model, "_get_token", return_value=token
            ), mock.patch.object(
                download_model, "_list_files", return_value=["weights/model.safetensors"]
            ), mock.patch.object(
                download_model, "_ensure_aria2", return_value="aria2c"
            ), mock.patch.object(
                download_model, "_aria2_download", side_effect=fake_aria2
            ), mock.patch.object(
                download_model, "_snapshot_download_fallback", side_effect=fake_snapshot
            ), mock.patch.object(
                threading.Thread, "start", return_value=None
            ), mock.patch.object(
                threading.Thread, "join", return_value=None
            ):
                ok = download_model.download_repo("org/repo", str(dest_root), token=token)

            self.assertTrue(ok)
            self.assertIn("Authorization: Bearer " + token, state["input_text"])
            self.assertFalse(state["input_file"].exists())
            self.assertNotIn(token, output.getvalue())
            self.assertTrue((dest_dir / "DOWNLOAD_COMPLETE").exists())

    def test_download_repo_skips_completion_marker_when_verification_fails(self) -> None:
        def fake_snapshot(*_args, **_kwargs) -> bool:
            keep_file.write_text("keep")
            found_file.write_text("{}")
            return True

        with tempfile.TemporaryDirectory() as tmpdir:
            dest_root = Path(tmpdir)
            dest_dir = dest_root / "model"
            keep_file = dest_dir / "keep.txt"
            found_file = download_model._repo_file_path(dest_dir, "config.json")
            output = io.StringIO()
            fake_hf = _fake_huggingface_hub()

            with contextlib.redirect_stdout(output), mock.patch.dict(
                sys.modules, {"huggingface_hub": fake_hf}
            ), mock.patch.object(
                download_model, "_get_token", return_value=None
            ), mock.patch.object(
                download_model, "_list_files", return_value=["config.json", "missing/model.safetensors", "refs/"]
            ), mock.patch.object(
                download_model, "_snapshot_download_fallback", side_effect=fake_snapshot
            ):
                ok = download_model.download_repo(
                    "org/repo", str(dest_root), use_aria2=False
                )

            self.assertFalse(ok)
            self.assertTrue(keep_file.exists())
            self.assertFalse((dest_dir / "DOWNLOAD_COMPLETE").exists())
            self.assertIn("1 file(s) missing", output.getvalue())


if __name__ == "__main__":
    unittest.main()
