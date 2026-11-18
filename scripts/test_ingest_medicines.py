#!/usr/bin/env python3
"""Unit test for the importer's optional Medicines column (inotify_scripts/ingest_file_h360tk.py).

Runs the real ingest_and_execute on small xlsx files with psycopg2.connect replaced by a fake
connection that records every SQL statement. It checks that:
  - 'Medicines', 'Obat' and 'Prescription' headers are read (case and spaces ignored);
  - each visit row with text writes one prescriptions upsert for that visit's encounter, with
    source 'upload', keyed on encounter_id;
  - a blank cell, or a file with no medicines column, writes no prescriptions row;
  - the upsert only rewrites a row whose text differs, so re-importing a file changes nothing;
  - a file that cannot be read, or a database that cannot be reached, exits 1, and fileproc.sh then
    writes no done marker (run in this checkout's file-upload-trigger container after
    `source scripts/h360_env.sh`, skipped otherwise).

    python3 scripts/test_ingest_medicines.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
INGEST = ROOT / "inotify_scripts" / "ingest_file_h360tk.py"


def load_ingest():
    spec = importlib.util.spec_from_file_location("ingest_file_h360tk", INGEST)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeCursor:
    """Records SQL; answers the RETURNING queries the importer reads."""

    def __init__(self, log):
        self.log = log
        self._result = None
        self._next_encounter = 1000
        self._encounters = {}

    def execute(self, sql, params=None):
        self.log.append(sql)
        if "upsert_org_unit_chain" in sql:
            self._result = (7,)
        elif "INSERT INTO encounters" in sql:
            key = re.search(r"VALUES \((.*?), (.*?), ", sql, re.S).group(1, 2)
            if key not in self._encounters:
                self._next_encounter += 1
                self._encounters[key] = self._next_encounter
            self._result = (self._encounters[key],)
        else:
            self._result = None

    def fetchone(self):
        return self._result

    def close(self):
        pass


class FakeConnection:
    def __init__(self, log):
        self.log = log
        self.autocommit = False

    def cursor(self):
        return FakeCursor(self.log)

    def close(self):
        pass


BASE = {
    "Registration Date": "01-01-2026 00:00:00",
    "Patient ID": "TEST-1",
    "First Name": "Testpatient",
    "Last Name": "One",
    "Gender": "Female",
    "Phone Number": "9000000001",
    "Region": "Region-T",
    "District": "District-T",
    "Facility": "PHC-T",
    "Sub Facility": "SHC-T",
    "Systolic": 150,
    "Diastolic": 92,
    "Diagnosis 1": "I10",
}


class MedicinesColumnTest(unittest.TestCase):
    def setUp(self):
        self.ingest = load_ingest()
        self.log: list[str] = []
        self.ingest.psycopg2.connect = lambda **kw: FakeConnection(self.log)
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def run_file(self, rows, name="upload.xlsx"):
        path = os.path.join(self.tmp.name, name)
        pd.DataFrame(rows).to_excel(path, index=False)
        self.log.clear()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.ingest.ingest_and_execute(path)
        return [s for s in self.log if "INTO prescriptions" in s]

    def rows(self, header, cells):
        out = []
        for i, cell in enumerate(cells):
            row = dict(BASE)
            row["Visit Time"] = f"0{i + 1}-02-2026 10:00:00"
            row[header] = cell
            out.append(row)
        return out

    def test_medicines_header(self):
        text = "Amlodipine 5 mg - 1 x 1 Tablet Sehari; Atorvastatin 20 mg - 1 x 1 Tablet Sehari"
        sql = self.run_file(self.rows("Medicines", [text]))
        self.assertEqual(len(sql), 1)
        self.assertIn("'Amlodipine 5 mg - 1 x 1 Tablet Sehari; Atorvastatin 20 mg - 1 x 1 Tablet Sehari'", sql[0])
        self.assertIn("'upload'", sql[0])
        self.assertIn("ON CONFLICT (encounter_id) DO UPDATE", sql[0])
        self.assertIn("WHERE prescriptions.obat_raw IS DISTINCT FROM EXCLUDED.obat_raw", sql[0])
        self.assertRegex(sql[0], r"VALUES \(1001, ")

    def test_alias_headers(self):
        for header in ("Obat", "Prescription", " medicines "):
            with self.subTest(header=header):
                sql = self.run_file(self.rows(header, ["Lisinopril 10 mg - 1 x 2 Tablet Sehari"]))
                self.assertEqual(len(sql), 1)
                self.assertIn("Lisinopril 10 mg - 1 x 2 Tablet Sehari", sql[0])

    def test_blank_cells_write_nothing(self):
        sql = self.run_file(self.rows("Medicines", [None, "", "   ", "Amlodipine 10 mg - 1 x 1 Tablet Sehari"]))
        self.assertEqual(len(sql), 1)
        self.assertRegex(sql[0], r"VALUES \(1004, ")
        self.assertIn("Amlodipine 10 mg", sql[0])

    def test_no_column_writes_nothing(self):
        rows = self.rows("Medicines", ["x"])
        for row in rows:
            del row["Medicines"]
        sql = self.run_file(rows)
        self.assertEqual(sql, [])
        self.assertTrue(any("INSERT INTO encounters" in s for s in self.log))

    def test_quotes_are_escaped(self):
        sql = self.run_file(self.rows("Obat", ["Obat herbal 'jamu' 2 x sehari"]))
        self.assertIn("'Obat herbal ''jamu'' 2 x sehari'", sql[0])

    def test_first_listed_header_wins(self):
        rows = self.rows("Prescription", ["Lisinopril 20 mg - 1 x 1 Tablet Sehari"])
        rows[0]["Medicines"] = "Amlodipine 5 mg - 1 x 1 Tablet Sehari"
        sql = self.run_file(rows)
        self.assertEqual(len(sql), 1)
        self.assertIn("Amlodipine 5 mg", sql[0])

    def test_reimport_is_the_same_sql(self):
        rows = self.rows("Medicines", ["Amlodipine 5 mg - 1 x 1 Tablet Sehari", None])
        first = self.run_file(rows, "a.xlsx")
        second = self.run_file(rows, "b.xlsx")
        self.assertEqual(first, second)



FILEPROC_NO_MARKER = r"""
d=$(mktemp -d)
python3 -c "import pandas as pd, sys; pd.DataFrame([{'Patient ID': 'T1', 'Visit Time': '01-02-2026 10:00:00'}]).to_excel(sys.argv[1], index=False)" "$d/up.xlsx"
POSTGRES_HOST=unreachable.invalid H360TK_INGEST_STATE="$d/state" bash /scripts/fileproc.sh t "$d/" TEST up.xlsx >/dev/null 2>&1
echo "status=$? markers=$(ls "$d/state" | grep -c '[.]done$')"
rm -rf "$d"
"""


class FailedLoadTest(unittest.TestCase):
    """A failed load must exit non-zero, or fileproc.sh marks the file done and never retries it."""

    def ingest_exit_code(self, path):
        with self.assertRaises(SystemExit) as ctx, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            self.ingest.ingest_and_execute(path)
        return ctx.exception.code

    def setUp(self):
        self.ingest = load_ingest()

    def test_unreadable_file_exits_1(self):
        self.assertEqual(self.ingest_exit_code("/nonexistent/upload.xlsx"), 1)

    def test_unreachable_database_exits_1(self):
        def refuse(**kw):
            raise self.ingest.psycopg2.OperationalError("connection refused")
        self.ingest.psycopg2.connect = refuse
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "upload.xlsx")
            pd.DataFrame([dict(BASE, **{"Visit Time": "01-02-2026 10:00:00"})]).to_excel(path, index=False)
            self.assertEqual(self.ingest_exit_code(path), 1)

    @unittest.skipUnless(os.environ.get("H360_PG_CONTAINER"), "source scripts/h360_env.sh to run in the container")
    def test_fileproc_writes_no_marker_when_database_is_down(self):
        container = os.environ.get("H360_CONTAINER_PREFIX", "") + "file-upload-trigger"
        proc = subprocess.run(["docker", "exec", "-i", container, "bash", "-s"], input=FILEPROC_NO_MARKER,
                              capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            self.skipTest(f"{container} not running: {proc.stderr.strip()}")
        self.assertEqual(proc.stdout.strip(), "status=1 markers=0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
