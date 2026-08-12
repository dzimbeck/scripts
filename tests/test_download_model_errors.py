import unittest
from unittest.mock import patch

import download_model


class _FakeResponse:
    def __init__(self, status_code):
        self.status_code = status_code


class _FakeHfHubHTTPError(Exception):
    def __init__(self, message="", status_code=None):
        super().__init__(message)
        self.response = _FakeResponse(status_code) if status_code is not None else None


class _FakeGatedRepoError(_FakeHfHubHTTPError):
    pass


class _FakeRepositoryNotFoundError(_FakeHfHubHTTPError):
    pass


class _FakeRevisionNotFoundError(_FakeHfHubHTTPError):
    pass


FAKE_TYPES = {
    "GatedRepoError": _FakeGatedRepoError,
    "RepositoryNotFoundError": _FakeRepositoryNotFoundError,
    "RevisionNotFoundError": _FakeRevisionNotFoundError,
    "HfHubHTTPError": _FakeHfHubHTTPError,
}


class ClassifyHfErrorTests(unittest.TestCase):
    @patch("download_model._load_hf_exception_types", return_value=FAKE_TYPES)
    def test_gated_repo_error_is_gated(self, _mock_types):
        kind, message = download_model._classify_hf_error(
            _FakeGatedRepoError("gated", status_code=403),
            "org/model",
            "main",
        )
        self.assertEqual(kind, "gated")
        self.assertIn("https://huggingface.co/org/model", message)

    @patch("download_model._load_hf_exception_types", return_value=FAKE_TYPES)
    def test_repository_not_found_error_is_not_found(self, _mock_types):
        kind, message = download_model._classify_hf_error(
            _FakeRepositoryNotFoundError("repo not found", status_code=404),
            "org/missing",
            "main",
        )
        self.assertEqual(kind, "repo_not_found")
        self.assertIn("invalid repo ID", message)

    @patch("download_model._load_hf_exception_types", return_value=FAKE_TYPES)
    def test_revision_not_found_error_is_distinct(self, _mock_types):
        kind, message = download_model._classify_hf_error(
            _FakeRevisionNotFoundError("revision not found", status_code=404),
            "org/model",
            "bad-rev",
        )
        self.assertEqual(kind, "revision_not_found")
        self.assertIn("/tree/bad-rev", message)

    @patch("download_model._load_hf_exception_types", return_value=FAKE_TYPES)
    def test_auth_error_is_not_gated(self, _mock_types):
        kind, message = download_model._classify_hf_error(
            _FakeHfHubHTTPError("forbidden", status_code=403),
            "org/private-model",
            "main",
        )
        self.assertEqual(kind, "auth")
        self.assertNotIn("gated", message.lower())

    @patch("download_model._load_hf_exception_types", return_value=FAKE_TYPES)
    def test_other_http_error_is_network_api_failure(self, _mock_types):
        kind, message = download_model._classify_hf_error(
            _FakeHfHubHTTPError("server error", status_code=500),
            "org/model",
            "main",
        )
        self.assertEqual(kind, "http_error")
        self.assertIn("API/network error", message)


if __name__ == "__main__":
    unittest.main()
