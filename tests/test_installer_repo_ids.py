import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_FLUX = REPO_ROOT / "install.bat"
INSTALL_ACESTEP = REPO_ROOT / "install_acestep.bat"
README = REPO_ROOT / "README.md"

EXPECTED_FLUX_REPOS = {
    # Keep these in sync with install.bat FLUX.2 menu REPO_ID mappings.
    "black-forest-labs/FLUX.2-klein-4B",
    "black-forest-labs/FLUX.2-klein-9B",
    "black-forest-labs/FLUX.2-dev",
}

EXPECTED_ACESTEP_REPOS = {
    "ACE-Step/acestep-v15-base",
    "ACE-Step/acestep-v15-sft",
    "ACE-Step/acestep-v15-turbo-continuous",
}

FORBIDDEN_REPOS = {
    "black-forest-labs/FLUX.2-standard-8B",
    "ACE-Step/ACE-Step-v1.5",
    "ACE-Step/ACE-Step-v1-chinese-rap-LoRA",
}


def _extract_repo_ids(text: str):
    return set(re.findall(r'set "REPO_ID=([^"]+)"', text))


class InstallerRepoIdConsistencyTests(unittest.TestCase):
    def test_flux_installer_repo_ids_match_expected_choices(self):
        repo_ids = _extract_repo_ids(INSTALL_FLUX.read_text(encoding="utf-8"))
        flux_repo_ids = {repo for repo in repo_ids if repo.startswith("black-forest-labs/")}
        self.assertEqual(flux_repo_ids, EXPECTED_FLUX_REPOS)

    def test_acestep_installer_repo_ids_match_expected_choices(self):
        repo_ids = _extract_repo_ids(INSTALL_ACESTEP.read_text(encoding="utf-8"))
        acestep_repo_ids = {repo for repo in repo_ids if repo.startswith("ACE-Step/")}
        self.assertEqual(acestep_repo_ids, EXPECTED_ACESTEP_REPOS)

    def test_readme_includes_all_installer_repo_ids(self):
        readme_text = README.read_text(encoding="utf-8")
        for repo_id in EXPECTED_FLUX_REPOS | EXPECTED_ACESTEP_REPOS:
            self.assertIn(f"`{repo_id}`", readme_text)

    def test_forbidden_repo_ids_removed(self):
        combined = "\n".join(
            [
                INSTALL_FLUX.read_text(encoding="utf-8"),
                INSTALL_ACESTEP.read_text(encoding="utf-8"),
                README.read_text(encoding="utf-8"),
            ]
        )
        for repo_id in FORBIDDEN_REPOS:
            self.assertNotIn(repo_id, combined)


if __name__ == "__main__":
    unittest.main()
