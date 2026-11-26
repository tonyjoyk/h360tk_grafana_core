#!/usr/bin/env python3
"""Prove the dashboard query collector sees HTN, DM and drug-stock SQL without a database."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import verify_dashboard_queries as v


class CollectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.queries, cls.skipped = v.collect_queries(v.DASHBOARDS, v.DATASOURCES)
        cls.tally = v.counts(cls.queries)

    def test_finds_htn_dm_and_drug_stock(self):
        self.assertGreater(self.tally["htn"], 0, self.tally)
        self.assertGreater(self.tally["dm"], 0, self.tally)
        self.assertGreater(self.tally["drug_stock"], 0, self.tally)

    def test_program_variables_and_drug_stock_panels(self):
        program_vars = [
            q for q in self.queries
            if q.dashboard_uid == "heart360_showcase" and q.kind == "variable"
        ]
        stock_panels = [
            q for q in self.queries
            if q.area == "drug_stock" and q.kind == "panel"
        ]
        self.assertGreater(len(program_vars), 0)
        self.assertGreater(len(stock_panels), 0)
        self.assertTrue(any(q.role == "heart360tk_reader" for q in program_vars))
        self.assertTrue(any(q.role == "heart360tk_cached" for q in stock_panels))

    def test_sample_substitution_clears_macros(self):
        self.assertEqual(v.REFERENCE_MONTH_MS, "1790812800000")
        unknown: set[str] = set()
        for query in self.queries:
            sql = v.substitute(query.sql, unknown)
            self.assertNotIn("${", sql, query.label)
            self.assertNotIn("$__time", sql, query.label)
            self.assertNotIn("$isAllowed", sql, query.label)
            self.assertNotIn("$org_unit", sql, query.label)
        self.assertIn(v.REFERENCE_MONTH_MS, v.substitute("to_timestamp(${reference_month}/1000.0)"))
        self.assertIn("BETWEEN '2025-11-01T00:00:00Z' AND '2026-11-01T00:00:00Z'",
                      v.substitute("WHERE $__timeFilter(ref_month)"))
        self.assertIn("'1'", v.substitute("NULLIF('$isAllowed', '')"))

    def test_every_rawsql_is_a_read_or_explicitly_skipped(self):
        collected = {q.sql for q in self.queries}
        skipped = set(self.skipped)
        missing = []
        for path in v.DASHBOARDS.rglob("*.json"):
            dashboard = json.loads(path.read_text())
            for pointer, raw in v.iter_rawsql(dashboard):
                key = f"{path.name}:{pointer}"
                if raw not in collected and key not in skipped:
                    missing.append(key)
                if raw in collected:
                    self.assertFalse(raw.lstrip().lower().startswith(("insert", "update", "delete")), key)
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
