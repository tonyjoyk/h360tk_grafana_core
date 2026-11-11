#!/usr/bin/env python3
"""A bad Reports source folder fails the build with BuildError (exit 2), never a skip or a KeyError.

    python3 scripts/test_build_reports_dashboard.py
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_reports_dashboard as b  # noqa: E402


class BadSourceFolder(unittest.TestCase):
    def setUp(self):
        self.src = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.src)

    def fails(self, pattern: str):
        with self.assertRaisesRegex(b.BuildError, pattern):
            b.build(self.src)

    def test_bad_folders(self):
        self.fails("_shell.json: not found")
        (self.src / "_shell.json").write_text(json.dumps({"uid": b.UID}))
        self.fails("needs a spec")
        shutil.copy(b.SHELL, self.src / "_shell.json")
        shutil.copytree(b.SRC / b.SHARED_DIR, self.src / b.SHARED_DIR)
        self.fails(r"0-start\.json: not found")


if __name__ == "__main__":
    unittest.main()
