#!/usr/bin/env python3
"""Unit tests for the wide Form sheet puller. No network."""

import json
import os
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import pull

WIDE_PATH = HERE / "fixture_wide_form.json"
LONG_PATH = HERE / "fixture_long_rows.json"
EPOCH = datetime(1899, 12, 30)


def record(org, month, code, stock, submitted, email, sheet_row):
    return {
        "org_unit_id": org,
        "reporting_month": month,
        "drug_code": code,
        "in_stock": stock,
        "submitted_at": submitted,
        "submitter_email": email,
        "sheet_row": sheet_row,
    }


def load_wide():
    with WIDE_PATH.open(encoding="utf-8") as handle:
        return pull.records_from_loaded(json.load(handle))


class FakeRequest:
    def __init__(self, payload):
        self.payload = payload

    def execute(self):
        return self.payload


class FakeSheets:
    def __init__(self, values):
        self.values_payload = values
        self.meta_kwargs = None
        self.value_kwargs = None

    def spreadsheets(self):
        return self

    def values(self):
        return self

    def get(self, **kwargs):
        if "range" in kwargs:
            self.value_kwargs = kwargs
            return FakeRequest({"values": self.values_payload})
        self.meta_kwargs = kwargs
        return FakeRequest({"properties": {"timeZone": "Africa/Addis_Ababa"}})


class LongFormatTests(unittest.TestCase):
    def test_header_and_positional_rows_stay_unchanged(self):
        rows = pull.rows_from_sheet_values(
            [
                ["drug_code", "in_stock", "org_unit_id", "submitted_at", "reporting_month"],
                ["329528", "", "11", "2026-09-20T01:00:00Z", "2026-09-18"],
                ["", "", "", "", ""],
            ]
        )
        bare = pull.rows_from_sheet_values(
            [
                ["12", "2026-08", "329526", "0"],
            ]
        )
        self.assertEqual(
            rows,
            [
                {
                    "org_unit_id": "11",
                    "reporting_month": "2026-09-18",
                    "drug_code": "329528",
                    "in_stock": "",
                    "submitted_at": "2026-09-20T01:00:00Z",
                }
            ],
        )
        self.assertEqual(
            bare,
            [
                {
                    "org_unit_id": "12",
                    "reporting_month": "2026-08",
                    "drug_code": "329526",
                    "in_stock": "0",
                    "submitted_at": "",
                }
            ],
        )

    def test_long_fixture_passes_through(self):
        with LONG_PATH.open(encoding="utf-8") as handle:
            raw = json.load(handle)
        self.assertEqual(pull.records_from_loaded(raw), raw)
        with patch.dict(
            os.environ,
            {
                "DRUG_STOCK_FIXTURE_PATH": str(LONG_PATH),
                "DRUG_STOCK_SHEET_ID": "sheet-1",
                "DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS": "/no/such-sa.json",
            },
        ):
            def explode(_sheet_id):
                raise AssertionError("sheet fetch was called for a fixture")

            self.assertEqual(pull.load_rows(sheet_fetcher=explode), raw)


class WideFormTests(unittest.TestCase):
    def test_submitter_field_is_the_one_line_sql_switch(self):
        self.assertEqual(pull.SUBMITTER_FIELD, "submitter_email")

    def test_fixture_covers_three_facilities_out_of_order(self):
        rows = load_wide()
        late = "2026-10-05T09:15:00+05:30"
        early = "2026-09-20T08:00:00+05:30"
        mid_b = "2026-10-01T11:00:00+05:30"
        phc_c = "2026-10-03T16:45:00+05:30"
        expected = [
            record("101", "2026-10-01", "329528", "40", late, "phc.a.late@example.org", 2),
            record("101", "2026-10-01", "316764", "n/a", late, "phc.a.late@example.org", 2),
            record("101", "2026-10-01", "197499", "0", late, "phc.a.late@example.org", 2),
            record("101", "2026-10-01", "blank-hctz", "15", late, "phc.a.late@example.org", 2),
            record("102", "2026-10-01", "329528", "7", mid_b, "phc.b.nurse@example.org", 3),
            record("102", "2026-10-01", "329526", "2", mid_b, "phc.b.nurse@example.org", 3),
            record("102", "2026-10-01", "316764", "4", mid_b, "phc.b.nurse@example.org", 3),
            record("102", "2026-10-01", "197499", "?", mid_b, "phc.b.nurse@example.org", 3),
            record("101", "2026-09-01", "329528", "10", early, "phc.a.early@example.org", 4),
            record("101", "2026-09-01", "329526", "3", early, "phc.a.early@example.org", 4),
            record("101", "2026-09-01", "316764", "5", early, "phc.a.early@example.org", 4),
            record("101", "2026-09-01", "197499", "8", early, "phc.a.early@example.org", 4),
            record("101", "2026-09-01", "blank-hctz", "4", early, "phc.a.early@example.org", 4),
            record("103", "2026-10-01", "329528", "1", phc_c, "phc.c.clerk@example.org", 5),
            record("103", "2026-10-01", "329526", "0", phc_c, "phc.c.clerk@example.org", 5),
            record("103", "2026-10-01", "316764", "9", phc_c, "phc.c.clerk@example.org", 5),
            record("103", "2026-10-01", "197499", "2", phc_c, "phc.c.clerk@example.org", 5),
            record("103", "2026-10-01", "blank-hctz", "6", phc_c, "phc.c.clerk@example.org", 5),
        ]
        self.assertEqual(rows, expected)
        facilities = {row["org_unit_id"] for row in rows}
        self.assertEqual(facilities, {"101", "102", "103"})
        phc_a_amlo = [
            row
            for row in rows
            if row["org_unit_id"] == "101" and row["drug_code"] == "329528"
        ]
        self.assertEqual([row["submitted_at"] for row in phc_a_amlo], [late, early])
        self.assertLess(rows.index(phc_a_amlo[0]), rows.index(phc_a_amlo[1]))
        self.assertFalse(
            any(row["sheet_row"] == 2 and row["drug_code"] == "329526" for row in rows)
        )
        self.assertFalse(any(row["sheet_row"] == 3 and row["drug_code"] == "blank-hctz" for row in rows))
        self.assertFalse(any(row["drug_code"] == "Notes" or "tablets on hand" in row["drug_code"] for row in rows))
        bad = [row for row in rows if row["in_stock"] == "n/a"]
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]["drug_code"], "316764")

    def test_spec_label_blank_question_and_month_name(self):
        values = [
            [
                "Timestamp",
                "Email Address",
                "Facility",
                "Reporting Month",
                "In-Stock Amlodipine 5 mg",
                "In-Stock Amlodipine 10 mg",
            ],
            ["2026-10-05T09:15:00Z", "nurse@example.org", "PHC-A (id 11)", "September 2026", "", "?"],
            ["", "", "", "", "", ""],
            ["2026-11-01 08:00:00", "nurse@example.org", 12, "2026-11-19", 6, ""],
        ]
        rows = pull.rows_from_sheet_values(values, time_zone="UTC")
        self.assertEqual(
            rows,
            [
                record("11", "2026-09-01", "329526", "?", "2026-10-05T09:15:00+00:00", "nurse@example.org", 2),
                record("12", "2026-11-01", "329528", "6", "2026-11-01T08:00:00+00:00", "nurse@example.org", 4),
            ],
        )

    def test_blank_strength_matches_and_ambiguous_strength_does_not(self):
        drugs = [
            {"drug_name": "Amlodipine", "dosage": "5 mg", "rxnorm_code": "329528", "label": ""},
            {"drug_name": "Amlodipine", "dosage": "10 mg", "rxnorm_code": "329526", "label": ""},
            {"drug_name": "Hydrochlorothiazide", "dosage": "", "rxnorm_code": "blank-hctz", "label": ""},
        ]
        values = [
            [
                "Timestamp",
                "Facility",
                "Reporting Month",
                "Amlodipine - tablets on hand",
                "Hydrochlorothiazide - tablets on hand",
                "Aspirin 10 mg - tablets on hand",
            ],
            ["2026-10-01 00:00:00", "5", "2026-10", 3, 8, "lots"],
        ]
        rows = pull.rows_from_sheet_values(values, drugs=drugs, time_zone="UTC")
        self.assertEqual(
            [row["drug_code"] for row in rows],
            ["Amlodipine - tablets on hand", "blank-hctz", "Aspirin 10 mg - tablets on hand"],
        )
        self.assertEqual([row["in_stock"] for row in rows], ["3", "8", "lots"])

    def test_serial_timestamp_uses_spreadsheet_zone(self):
        serial = (datetime(1970, 1, 1) - EPOCH).total_seconds() / 86400
        self.assertEqual(serial, 25569)
        self.assertEqual(pull.parse_timestamp(25569, "UTC"), "1970-01-01T00:00:00+00:00")
        self.assertEqual(pull.parse_timestamp(25569.5, "UTC"), "1970-01-01T12:00:00+00:00")
        wall = datetime(2026, 10, 5, 9, 15, 0)
        kolkata_serial = (wall - EPOCH).total_seconds() / 86400
        self.assertEqual(
            pull.parse_timestamp(kolkata_serial, "Asia/Kolkata"),
            "2026-10-05T09:15:00+05:30",
        )

    def test_us_form_timestamp_and_unresolved_facility(self):
        values = [
            ["Timestamp", "Email address", "Facility", "Reporting Month", "Amlodipine 5 mg - tablets on hand"],
            ["10/5/2026 9:15:00 AM", "a@example.org", "PHC-A", "10/2026", "many"],
        ]
        drugs = [{"drug_name": "Amlodipine", "dosage": "5 mg", "rxnorm_code": "329528", "label": ""}]
        rows = pull.rows_from_sheet_values(values, drugs=drugs, time_zone="Asia/Kolkata")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["org_unit_id"], "PHC-A")
        self.assertEqual(rows[0]["reporting_month"], "2026-10-01")
        self.assertEqual(rows[0]["in_stock"], "many")
        self.assertEqual(rows[0]["submitted_at"], "2026-10-05T09:15:00+05:30")
        self.assertEqual(rows[0]["submitter_email"], "a@example.org")

    def test_blank_row_does_not_renumber_later_rows(self):
        drugs = [{"drug_name": "Amlodipine", "dosage": "5 mg", "rxnorm_code": "329528", "label": ""}]
        values = [
            ["Timestamp", "Facility", "Reporting Month", "Amlodipine 5 mg - tablets on hand"],
            ["2026-10-01 00:00:00", "1", "2026-10", 1],
            ["", "", "", ""],
            ["2026-10-02 00:00:00", "2", "2026-10", 2],
        ]
        rows = pull.rows_from_sheet_values(values, drugs=drugs, time_zone="UTC")
        self.assertEqual([row["sheet_row"] for row in rows], [2, 4])
        self.assertEqual([row["org_unit_id"] for row in rows], ["1", "2"])


class FetchTests(unittest.TestCase):
    def test_fetch_sheet_requests_serial_numbers(self):
        service = FakeSheets(
            [
                ["org_unit_id", "reporting_month", "drug_code", "in_stock", "submitted_at"],
                ["11", "2026-09-01", "329528", "3", ""],
            ]
        )
        fetched = pull.fetch_sheet(service, "sheet-1", "A:ZZ")
        self.assertEqual(fetched["timeZone"], "Africa/Addis_Ababa")
        self.assertEqual(service.meta_kwargs["fields"], "properties.timeZone")
        self.assertEqual(service.value_kwargs["valueRenderOption"], "UNFORMATTED_VALUE")
        self.assertEqual(service.value_kwargs["dateTimeRenderOption"], "SERIAL_NUMBER")
        self.assertEqual(service.value_kwargs["range"], "A:ZZ")
        self.assertNotIn("http", json.dumps(service.value_kwargs))

    def test_load_sheet_uses_the_injected_fetcher(self):
        seen = []

        def fetcher(sheet_id):
            seen.append(sheet_id)
            return {
                "timeZone": "UTC",
                "protocol_drugs": [
                    {"drug_name": "Amlodipine", "dosage": "5 mg", "rxnorm_code": "329528", "label": ""}
                ],
                "values": [
                    ["Timestamp", "Email address", "Facility", "Reporting Month", "Amlodipine 5 mg - tablets on hand"],
                    ["2026-10-05 09:15:00", "a@example.org", "PHC-A (id 11)", "2026-10", 4],
                ],
            }

        rows = pull.load_sheet("sheet-abc", "/no/such/creds.json", fetcher=fetcher, range_name="A:ZZ")
        self.assertEqual(seen, ["sheet-abc"])
        self.assertEqual(rows[0]["drug_code"], "329528")
        self.assertEqual(rows[0]["in_stock"], "4")
        self.assertEqual(rows[0]["sheet_row"], 2)
        self.assertFalse(Path("/no/such/creds.json").exists())

    def test_range_start_shifts_sheet_row(self):
        def fetcher(_sheet_id):
            return {
                "timeZone": "UTC",
                "values": [
                    ["Timestamp", "Facility", "Reporting Month", "Amlodipine 5 mg - tablets on hand"],
                    ["2026-10-01 00:00:00", "11", "2026-10", 1],
                ],
                "protocol_drugs": [
                    {"drug_name": "Amlodipine", "dosage": "5 mg", "rxnorm_code": "329528", "label": ""}
                ],
            }

        rows = pull.load_sheet("sheet-abc", "/no/such/creds.json", fetcher=fetcher, range_name="'Form Responses 1'!A10:ZZ")
        self.assertEqual(rows[0]["sheet_row"], 11)

    def test_wide_fixture_via_env_does_not_fetch(self):
        with patch.dict(
            os.environ,
            {
                "DRUG_STOCK_FIXTURE_PATH": str(WIDE_PATH),
                "DRUG_STOCK_SHEET_ID": "sheet-1",
                "DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS": "/no/such/creds.json",
                "DRUG_STOCK_SHEET_RANGE": "",
            },
        ):
            def explode(_sheet_id):
                raise AssertionError("sheet fetch was called")

            rows = pull.load_rows(sheet_fetcher=explode)
        self.assertEqual(len(rows), 18)
        self.assertEqual(rows[0]["submitter_email"], "phc.a.late@example.org")

    def test_load_rows_sheet_fetcher_is_the_only_io(self):
        def fetcher(sheet_id):
            self.assertEqual(sheet_id, "sheet-9")
            return [
                ["drug_code", "in_stock", "org_unit_id", "submitted_at", "reporting_month"],
                ["329528", "3", "11", "", "2026-09-01"],
            ]

        with patch.dict(
            os.environ,
            {
                "DRUG_STOCK_FIXTURE_PATH": "",
                "DRUG_STOCK_SHEET_ID": "sheet-9",
                "DRUG_STOCK_GOOGLE_APPLICATION_CREDENTIALS": "",
                "DRUG_STOCK_SHEET_RANGE": "A:E",
            },
        ):
            rows = pull.load_rows(sheet_fetcher=fetcher)
        self.assertEqual(rows[0]["drug_code"], "329528")
        self.assertEqual(rows[0]["in_stock"], "3")
        self.assertNotIn("submitter_email", rows[0])

    def test_missing_and_invalid_service_account_never_call_google(self):
        with self.assertRaises(pull.SourceError) as missing:
            pull.build_sheets_service("/no/such/sa.json")
        self.assertEqual(str(missing.exception), "service account file not found")
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write("{}")
            path = handle.name
        try:
            with self.assertRaises(pull.SourceError) as invalid:
                pull.build_sheets_service(path)
            self.assertEqual(str(invalid.exception), "service account file is not valid")
        finally:
            os.remove(path)


if __name__ == "__main__":
    unittest.main()
