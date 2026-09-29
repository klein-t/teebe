"""Regression checks for title validation, including untrusted event text."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check-pr-title.py")
SPEC = importlib.util.spec_from_file_location("title_policy", SCRIPT)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class TitlePolicyTests(unittest.TestCase):
    def test_supported_titles(self):
        for title in ["fix(files): restore preview focus", "feat!: remove old API",
                      "build(deps): bump Sparkle", "chore(release): release v0.3.0"]:
            with self.subTest(title=title):
                self.assertEqual(POLICY.errors(title), [])

    def test_invalid_titles(self):
        for title in ["Fix preview", "fix: WIP", "fix: fix bugs", "fix: trailing period.",
                      "fix: first\nsecond", "feat(UI): add a button", "fix: bad\x00title"]:
            with self.subTest(title=title):
                self.assertTrue(POLICY.errors(title))

    def test_title_is_data_not_shell(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / "unexpected"
            title = f"fix: keep $(touch {marker}) literal"
            result = subprocess.run([sys.executable, str(SCRIPT)],
                                    env={**os.environ, "PR_TITLE": title}, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
