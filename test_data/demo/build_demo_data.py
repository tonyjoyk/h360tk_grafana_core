#!/usr/bin/env python3
"""Deterministic demo upload data for HEARTS360: one patient-visit file with medicines."""

from __future__ import annotations

import argparse
import calendar
import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd

RNG_SEED = 42
DEFAULT_AS_OF = datetime(2026, 10, 13)

DATE_FMT = "%d-%m-%Y %H:%M:%S"
DATE_FMT_SHORT = "%d-%m-%Y"

COLUMNS = [
    "Registration Date",
    "Patient ID",
    "First Name",
    "Middle Name",
    "Last Name",
    "Date of Birth",
    "Gender",
    "Phone Number",
    "Region",
    "District",
    "Facility",
    "Sub Facility",
    "Systolic",
    "Diastolic",
    "Visit Time",
    "Blood Sugar Type",
    "Blood Sugar Value",
    "Diagnosis 1",
    "Diagnosis 2",
    "Medicines",
]

FACILITY_REGISTRY: list[dict[str, str]] = [
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-A", "Sub Facility": "SHC-A"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-A", "Sub Facility": "SHC-B"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-A", "Sub Facility": "SHC-C"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-A", "Sub Facility": "SHC-D"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-B", "Sub Facility": "SHC-E"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-B", "Sub Facility": "SHC-F"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-B", "Sub Facility": "SHC-G"},
    {"Region": "Region-A", "District": "District-A", "Facility": "PHC-B", "Sub Facility": "SHC-H"},
    {"Region": "Region-A", "District": "District-B", "Facility": "PHC-C", "Sub Facility": "SHC-I"},
    {"Region": "Region-A", "District": "District-B", "Facility": "PHC-C", "Sub Facility": "SHC-J"},
    {"Region": "Region-A", "District": "District-B", "Facility": "PHC-C", "Sub Facility": "SHC-K"},
    {"Region": "Region-A", "District": "District-B", "Facility": "PHC-C", "Sub Facility": "SHC-L"},
    {"Region": "Region-B", "District": "District-C", "Facility": "PHC-D", "Sub Facility": "SHC-M"},
    {"Region": "Region-B", "District": "District-C", "Facility": "PHC-D", "Sub Facility": "SHC-N"},
    {"Region": "Region-B", "District": "District-C", "Facility": "PHC-D", "Sub Facility": "SHC-O"},
    {"Region": "Region-B", "District": "District-C", "Facility": "PHC-D", "Sub Facility": "SHC-P"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-E", "Sub Facility": "SHC-Q"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-E", "Sub Facility": "SHC-R"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-E", "Sub Facility": "SHC-S"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-E", "Sub Facility": "SHC-T"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-F", "Sub Facility": "SHC-U"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-F", "Sub Facility": "SHC-V"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-F", "Sub Facility": "SHC-W"},
    {"Region": "Region-B", "District": "District-D", "Facility": "PHC-F", "Sub Facility": "SHC-X"},
]

def parse_upload_datetime(value) -> datetime | None:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return None
    if isinstance(value, datetime):
        return value
    text = str(value).strip()
    if not text or text.lower() == "nan":
        return None
    for fmt in (DATE_FMT, DATE_FMT_SHORT, "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def format_upload_datetime(dt: datetime) -> str:
    return dt.strftime(DATE_FMT)


def add_months(dt: datetime, months: int) -> datetime:
    month_index = dt.month - 1 + months
    year = dt.year + month_index // 12
    month = month_index % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


# ---------------------------------------------------------------------------
# Synthetic demo cohort: one upload file with every visit and its medicines.
# ---------------------------------------------------------------------------
#
# Six PHCs, PATIENTS_PER_FACILITY patients each, registered from HISTORY_START to the as-of date.
# Every visit row carries a BP reading and the visit's medicines (Indonesian Obat format, parsed by
# parse_obat). The rows plant the stories of CLINICAL-RULES section 7 for the reporting month (the
# as-of month, 2026-10 by default) and the BP Fudging PRD's quarterly rule:
#   * every PHC: medicines stepped up at about 46% of high-BP visits, in every month of the
#     history (PHC-E about 28%); statin lines for about 31% of eligible patients (PHC-F about 21%);
#     new-patient loss about 27%; control below the 60% "high control" line;
#   * PHC-C: about 56% of new patients have no phone number;
#   * PHC-D: about 38% of new patients never come back for a second visit within 90 days;
#   * PHC-E: high control (about 75%) with readings bunched under 140 from 2026-Q2: the ratio of
#     systolic 130-139 to 140-149 visits is about 2.2 in 2026-Q2 and 2.45 in 2026-Q3 (flagged at 2.0),
#     while every other PHC stays between 1.2 and 1.55 in each of the last four completed quarters.
# Every random choice comes from a numpy generator seeded with (RNG_SEED, patient number) or from
# md5 of a fixed key, so the same as-of date always gives the same rows.

PATIENTS_PER_FACILITY = 1200
HISTORY_START = datetime(2025, 1, 2)
FACILITIES = ["PHC-A", "PHC-B", "PHC-C", "PHC-D", "PHC-E", "PHC-F"]

# Per-facility plan. step_up: share of high-BP visits where medicines go up. statin: share of
# statin-eligible patients with a statin line. loss: share of new patients with no second visit
# within 90 days. phoneless_new: share of the reporting month's new patients with no phone.
# control: HTN-tab control to land on for the reporting month (None = as generated, kept in
# CONTROL_BAND). bunching: readings bunch under 140 from two quarters before the last completed one.
FACILITY_PLAN: dict[str, dict] = {
    "PHC-A": {"step_up": 0.46, "statin": 0.315, "loss": 0.27, "phoneless_new": 0.0, "control": None, "bunching": False},
    "PHC-B": {"step_up": 0.46, "statin": 0.315, "loss": 0.27, "phoneless_new": 0.0, "control": None, "bunching": False},
    "PHC-C": {"step_up": 0.46, "statin": 0.315, "loss": 0.27, "phoneless_new": 0.555, "control": None, "bunching": False},
    "PHC-D": {"step_up": 0.46, "statin": 0.315, "loss": 0.385, "phoneless_new": 0.0, "control": None, "bunching": False},
    "PHC-E": {"step_up": 0.28, "statin": 0.315, "loss": 0.27, "phoneless_new": 0.0, "control": 0.75, "bunching": True},
    "PHC-F": {"step_up": 0.46, "statin": 0.215, "loss": 0.27, "phoneless_new": 0.0, "control": None, "bunching": False},
}
CONTROL_BAND = (0.45, 0.57)          # other PHCs: as generated, nudged back inside this band
RATIO_BAND = (1.2, 1.55)             # 130-139 / 140-149 for quarters that are not flagged
RATIO_BUNCHED = {-2: 2.20, -1: 2.45}  # PHC-E: the second-last and last completed quarter

# Regimen start mix (share of patients per facility), as the earlier prescription seed.
REGIMEN_MIX = [("step12", 0.70), ("step34", 0.12), ("nonproto", 0.06), ("other", 0.04),
               ("unreadable", 0.03), ("nohtn", 0.05)]

TRAJECTORY_PROFILES: list[dict[str, float | str]] = [
    {"name": "improver", "weight": 0.40, "start_controlled_p": 0.25, "end_controlled_p": 0.80},
    {"name": "stable_controlled", "weight": 0.25, "start_controlled_p": 0.75, "end_controlled_p": 0.88},
    {"name": "persistent_uncontrolled", "weight": 0.20, "start_controlled_p": 0.15, "end_controlled_p": 0.30},
    {"name": "intermittent", "weight": 0.15, "start_controlled_p": 0.45, "end_controlled_p": 0.60},
]

STATIN_TEXT = ["Atorvastatin 20 mg - 1 x 1 Tablet Sehari", "Simvastatin 20 mg - 1 x 1 Tablet Sehari"]
METFORMIN_TEXT = "Metformin 500 mg - 2 x 1 Tablet Sehari"
PARACETAMOL_TEXT = "Paracetamol 500 mg - 3 x 1 Tablet Sehari"
LADDER_TEXT = {
    1: "Amlodipine 5 mg - 1 x 1 Tablet Sehari",
    2: "Amlodipine 10 mg - 1 x 1 Tablet Sehari",
    3: "Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari",
    4: "Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari",
    5: "Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Chlorthalidone 12.5 mg - 1 x 1 Tablet Sehari",
    6: "Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 20 mg - 1 x 1 Tablet Sehari; Chlorthalidone 25 mg - 1 x 1 Tablet Sehari",
}
OFF_LADDER_TEXT = {
    "nonproto": ["Losartan 50 mg - 1 x 1 Tablet Sehari",
                 "Losartan 100 mg - 1 x 1 Tablet Sehari",
                 "Losartan 100 mg - 1 x 1 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari",
                 "Losartan 100 mg - 1 x 1 Tablet Sehari; Amlodipine 10 mg - 1 x 1 Tablet Sehari"],
    "other": ["Lisinopril 10 mg - 1 x 1 Tablet Sehari",
              "Lisinopril 20 mg - 1 x 1 Tablet Sehari",
              "Lisinopril 20 mg - 1 x 1 Tablet Sehari; Amlodipine 5 mg - 1 x 1 Tablet Sehari",
              "Lisinopril 20 mg - 1 x 1 Tablet Sehari; Amlodipine 10 mg - 1 x 1 Tablet Sehari"],
    "nohtn": [None,  # the patient's non-HTN medicine only
              "Amlodipine 5 mg - 1 x 1 Tablet Sehari",
              "Amlodipine 10 mg - 1 x 1 Tablet Sehari",
              "Amlodipine 10 mg - 1 x 1 Tablet Sehari; Lisinopril 10 mg - 1 x 1 Tablet Sehari"],
    "unreadable": ["Obat herbal 2 x sehari"],
}


@dataclass
class Visit:
    at: datetime
    sys: int
    dia: int
    controlled: bool
    level: int = 0           # regimen rung; set by the regimen walk
    statin: bool = False
    bs_type: str = ""
    bs_value: float = float("nan")

    @property
    def day(self) -> datetime:
        return self.at.replace(hour=0, minute=0, second=0)


@dataclass
class Patient:
    index: int
    facility: dict[str, str]
    registration: datetime
    birth: datetime
    gender: str
    phone: str | None
    dm: bool
    profile: dict
    visits: list[Visit] = field(default_factory=list)
    bucket: str = "step12"
    start_level: int = 1
    statin_text: str = STATIN_TEXT[0]

    @property
    def pid(self) -> str:
        return f"DEMO-{self.index:05d}"

    @property
    def fac(self) -> str:
        return self.facility["Facility"]


@dataclass(frozen=True)
class Calendar:
    """Dates derived from the as-of date (2026-10-13 gives the CLINICAL-RULES section 7 dates)."""

    as_of: datetime

    @property
    def month_start(self) -> datetime:
        return self.as_of.replace(day=1, hour=0, minute=0, second=0)

    @property
    def window_end(self) -> datetime:
        return add_months(self.month_start, 1) - timedelta(days=1)

    @property
    def np_from(self) -> datetime:      # new-patient cohort, first visit from window_end - 179
        return self.window_end - timedelta(days=179)

    @property
    def np_to(self) -> datetime:        # ... to window_end - 90
        return self.window_end - timedelta(days=90)

    @property
    def titration_from(self) -> datetime:
        return self.window_end - timedelta(days=89)

    @property
    def titration_to(self) -> datetime:  # visits after data end - 30 days are too recent to judge
        return self.as_of.replace(hour=0, minute=0, second=0) - timedelta(days=30)

    @property
    def quarters(self) -> list[datetime]:
        """Starts of the last four completed quarters before the end of the reporting month."""
        q_month = ((self.window_end.month - 1) // 3) * 3 + 1
        current = datetime(self.window_end.year, q_month, 1)
        if add_months(current, 3) - timedelta(days=1) > self.window_end:
            current = add_months(current, -3)
        return [add_months(current, -3 * i) for i in (3, 2, 1, 0)]

    @property
    def bunching_from(self) -> datetime:
        return self.quarters[-2]


def md5_rank(key: str) -> str:
    return hashlib.md5(key.encode("utf-8")).hexdigest()


def md5_unit(key: str) -> float:
    return int(md5_rank(key)[:8], 16) / 0xFFFFFFFF


def pick_profile(rng: np.random.Generator) -> dict:
    weights = np.array([p["weight"] for p in TRAJECTORY_PROFILES], dtype=float)
    return TRAJECTORY_PROFILES[int(rng.choice(len(TRAJECTORY_PROFILES), p=weights / weights.sum()))]


def controlled_probability(profile: dict, months_in_care: float, fac: str) -> float:
    progress = min(1.0, months_in_care / 12.0)
    start = float(profile["start_controlled_p"])
    end = float(profile["end_controlled_p"])
    p = start + (end - start) * progress
    if fac == "PHC-E":
        p += 0.12
    return min(0.95, p)


def controlled_reading(rng: np.random.Generator, bunched: bool = False, high_share: float = 0.36) -> tuple[int, int]:
    if bunched or rng.random() < high_share:
        return int(rng.integers(130, 140)), int(rng.integers(70, 90))
    return int(rng.integers(105, 130)), int(rng.integers(62, 88))


def uncontrolled_reading(rng: np.random.Generator) -> tuple[int, int]:
    u = rng.random()
    if u < 0.06:   # high diastolic only
        return int(rng.integers(126, 140)), int(rng.integers(90, 99))
    if u < 0.38:
        return int(rng.integers(140, 150)), int(rng.integers(78, 100))
    return int(rng.integers(150, 186)), int(rng.integers(82, 110))


def make_reading(rng: np.random.Generator, controlled: bool, bunch: bool,
                 high_share: float = 0.36) -> tuple[int, int, bool]:
    """A visit's BP. With bunching, most 140-149 readings are written down as 130-139."""
    if controlled:
        sys_, dia = controlled_reading(rng, high_share=high_share)
        return sys_, dia, True
    sys_, dia = uncontrolled_reading(rng)
    if bunch and 140 <= sys_ < 150 and rng.random() < 0.35:
        return int(rng.integers(132, 140)), int(rng.integers(76, 90)), True
    return sys_, dia, False


def next_day(dt: datetime) -> datetime:
    """Clinics are closed on Sunday."""
    return dt + timedelta(days=1) if dt.weekday() == 6 else dt


def build_patients(cal: Calendar) -> list[Patient]:
    patients: list[Patient] = []
    span = (cal.as_of.replace(hour=0, minute=0, second=0) - HISTORY_START).days
    by_fac = {f: [r for r in FACILITY_REGISTRY if r["Facility"] == f] for f in FACILITIES}
    for k in range(PATIENTS_PER_FACILITY):
        for fi, fac in enumerate(FACILITIES):
            index = k * len(FACILITIES) + fi + 1
            rng = np.random.default_rng([RNG_SEED, index])
            day = int(span * (rng.random() ** 0.85))
            registration = next_day(HISTORY_START + timedelta(days=day))
            age = int(np.clip(rng.normal(55, 11), 30, 85))
            birth = registration - timedelta(days=age * 365 + int(rng.integers(0, 365)))
            dm = bool(rng.random() < (0.36 if age >= 45 else 0.18))
            phone = "9" + md5_rank(f"DEMO-{index:05d}:phone")[:12].translate(str.maketrans("abcdef", "012345"))[:9]
            patients.append(Patient(
                index=index,
                facility=by_fac[fac][int(rng.integers(0, len(by_fac[fac])))],
                registration=registration,
                birth=birth,
                gender="Female" if rng.random() < 0.56 else "Male",
                phone=phone,
                dm=dm,
                profile=pick_profile(rng),
            ))
    return patients


def in_np_cohort(p: Patient, cal: Calendar) -> bool:
    return cal.np_from <= p.registration <= cal.np_to


def quota(items: list, share: float, salt: str, key=lambda x: x) -> set:
    """The round(share * n) items with the lowest md5(key:salt): a fixed, reproducible pick."""
    ranked = sorted(items, key=lambda x: md5_rank(f"{key(x)}:{salt}"))
    return set(ranked[: int(round(share * len(ranked)))])


def build_visits(patients: list[Patient], cal: Calendar) -> None:
    # New-patient loss: an exact share of the reporting month's new-patient cohort, a random share
    # of everyone else.
    lost_np: set[int] = set()
    for fac in FACILITIES:
        cohort = [p.index for p in patients if p.fac == fac and in_np_cohort(p, cal)]
        lost_np |= quota(cohort, FACILITY_PLAN[fac]["loss"], "loss")

    for p in patients:
        rng = np.random.default_rng([RNG_SEED, p.index, 1])
        plan = FACILITY_PLAN[p.fac]
        drop_p = 0.01 if p.fac == "PHC-E" else 0.02

        def visit_at(day: datetime) -> Visit:
            at = day.replace(hour=int(rng.integers(8, 14)), minute=int(rng.integers(0, 60)), second=0)
            months = (day - p.registration).days / 30.4
            bunch = plan["bunching"] and day >= cal.bunching_from
            sys_, dia, ok = make_reading(rng, rng.random() < controlled_probability(p.profile, months, p.fac), bunch,
                                         high_share=0.27 if p.fac == "PHC-E" else 0.36)
            v = Visit(at=at, sys=sys_, dia=dia, controlled=ok)
            if p.dm and rng.random() < 0.6:
                v.bs_type = str(rng.choice(["FBS", "RBS", "HBA1C"]))
                v.bs_value = {"FBS": float(rng.integers(95, 240)), "RBS": float(rng.integers(120, 320)),
                              "HBA1C": round(float(rng.uniform(6.0, 11.0)), 1)}[v.bs_type]
            return v

        p.visits = [visit_at(p.registration)]
        end = cal.as_of.replace(hour=0, minute=0, second=0)

        # First gap: lost new patients come back after 90 days or never; the others within 31-85 days.
        if in_np_cohort(p, cal):
            lost = p.index in lost_np
        else:
            lost = rng.random() < plan["loss"]
        if lost:
            if rng.random() < 0.35:
                day = next_day(p.registration + timedelta(days=int(rng.integers(92, 240))))
                if day <= end:
                    p.visits.append(visit_at(day))
            if len(p.visits) == 1:
                continue
        else:
            room = min(85, (end - p.registration).days)
            if room < 31:
                continue
            p.visits.append(visit_at(next_day(p.registration + timedelta(days=int(rng.integers(31, room + 1))))))

        while True:
            last = p.visits[-1]
            gap = int(rng.integers(31, 63)) if not last.controlled else int(rng.integers(45, 96))
            if rng.random() < 0.07:
                gap += int(rng.integers(30, 121))
            day = next_day(last.day + timedelta(days=gap))
            if day > end or rng.random() < drop_p:
                break
            p.visits.append(visit_at(day))


# --- what the reports will show (mirrors the SQL closely enough to plant the targets) ----------

def control_cohort(p: Patient, cal: Calendar) -> tuple[bool, bool]:
    """(in the HTN-tab denominator, controlled) for the reporting month."""
    ref = cal.month_start
    if add_months(p.registration.replace(day=1), 3) > ref:
        return False, False
    seen = [v for v in p.visits if v.at < add_months(ref, 1)]
    if not seen:
        return False, False
    latest = seen[-1]
    if add_months(latest.day.replace(day=1), 12) <= ref:
        return False, False
    recent = add_months(latest.day.replace(day=1), 3) > ref
    return True, recent and latest.controlled


def control_pct(patients: list[Patient], cal: Calendar, fac: str) -> float:
    den = ctl = 0
    for p in patients:
        if p.fac != fac:
            continue
        d, c = control_cohort(p, cal)
        den += d
        ctl += c
    return ctl / den if den else 0.0


def adjust_control(patients: list[Patient], cal: Calendar) -> None:
    """Re-read the latest visit of a few patients so each PHC's control lands on its plan."""
    for fac in FACILITIES:
        target = FACILITY_PLAN[fac]["control"]
        pct = control_pct(patients, cal, fac)
        if target is None:
            lo, hi = CONTROL_BAND
            if lo <= pct <= hi:
                continue
            target = (lo + hi) / 2
        rows = [p for p in patients if p.fac == fac and control_cohort(p, cal)[0]
                and add_months(p.visits[-1].day.replace(day=1), 3) > cal.month_start]
        den = sum(1 for p in patients if p.fac == fac and control_cohort(p, cal)[0])
        need = int(round(target * den)) - int(round(pct * den))
        want_controlled = need > 0
        pool = sorted((p for p in rows if p.visits[-1].controlled != want_controlled),
                      key=lambda p: md5_rank(f"{p.pid}:control"))
        for p in pool[: abs(need)]:
            rng = np.random.default_rng([RNG_SEED, p.index, 2])
            v = p.visits[-1]
            if want_controlled:
                v.sys, v.dia = controlled_reading(rng, bunched=FACILITY_PLAN[fac]["bunching"])
            else:
                v.sys, v.dia = uncontrolled_reading(rng)
                if v.sys < 140 and v.dia < 90:
                    v.dia = 92
            v.controlled = want_controlled


def quarter_counts(patients: list[Patient], fac: str, q_start: datetime) -> tuple[int, int]:
    q_end = add_months(q_start, 3)
    a = b = 0
    for p in patients:
        if p.fac != fac:
            continue
        for v in p.visits:
            if q_start <= v.at < q_end:
                a += 130 <= v.sys < 140
                b += 140 <= v.sys < 150
    return a, b


def adjust_ratios(patients: list[Patient], cal: Calendar) -> None:
    """Move a few readings inside their own control state so each quarter's 130-139 / 140-149 ratio
    sits on plan. A controlled reading moves between 118-129 and 130-139; nothing changes state."""
    for fac in FACILITIES:
        for qi, q_start in enumerate(cal.quarters):
            q_end = add_months(q_start, 3)
            a, b = quarter_counts(patients, fac, q_start)
            bunched = FACILITY_PLAN[fac]["bunching"] and (qi - 4) in RATIO_BUNCHED
            if bunched:
                goal = RATIO_BUNCHED[qi - 4]
                if abs(a / max(b, 1) - goal) <= 0.03:
                    continue
            else:
                ratio = a / max(b, 1)
                if RATIO_BAND[0] <= ratio <= RATIO_BAND[1]:
                    continue
                goal = RATIO_BAND[1] - 0.08 if ratio > RATIO_BAND[1] else RATIO_BAND[0] + 0.1
            want_a = int(round(goal * b))
            moving_up = want_a > a
            pool = []
            for p in patients:
                if p.fac != fac:
                    continue
                for v in p.visits:
                    if not (q_start <= v.at < q_end and v.controlled):
                        continue
                    if (moving_up and v.sys < 130) or (not moving_up and 130 <= v.sys < 140):
                        pool.append((md5_rank(f"{p.pid}:{v.at:%Y%m%d}:ratio"), p.index, v))
            pool.sort(key=lambda x: (x[0], x[1]))
            for _, idx, v in pool[: abs(want_a - a)]:
                h = int(md5_rank(f"{idx}:{v.at:%Y%m%d}:sys")[:4], 16)
                v.sys = 130 + h % 10 if moving_up else 118 + h % 12


def titration_eligible(p: Patient, i: int, start: datetime, stop: datetime) -> bool:
    v = p.visits[i]
    return (i > 0 and not v.controlled and start <= v.day <= stop and p.bucket != "unreadable")


def max_level(bucket: str) -> int:
    return 6 if bucket in ("step12", "step34") else len(OFF_LADDER_TEXT[bucket]) - 1


def assign_regimens(patients: list[Patient], cal: Calendar) -> None:
    """Start regimen per patient, then walk the visits: at a high-BP visit the medicines go up one
    rung with the facility's step-up rate. In the reporting month's titration window the rate is a
    fixed share of the eligible visits, so the October number is exact."""
    for fac in FACILITIES:
        group = sorted((p for p in patients if p.fac == fac), key=lambda p: md5_rank(f"{p.pid}:mix"))
        n, edge = len(group), 0.0
        for bucket, share in REGIMEN_MIX:
            lo, edge = int(round(edge * n)), edge + share
            for p in group[lo:int(round(edge * n))]:
                p.bucket = bucket
        for p in group:
            pick = md5_unit(f"{p.pid}:which") < 0.5
            p.start_level = {"step12": 1 if pick else 2, "step34": 3 if pick else 4}.get(p.bucket, 0)
            p.statin_text = STATIN_TEXT[0] if md5_unit(f"{p.pid}:statin-drug") < 0.8 else STATIN_TEXT[1]

    start, stop = cal.titration_from, cal.titration_to
    for fac in FACILITIES:
        rate = FACILITY_PLAN[fac]["step_up"]
        group = [p for p in patients if p.fac == fac]
        eligible = [(p, i) for p in group for i in range(len(p.visits)) if titration_eligible(p, i, start, stop)]
        ranked = sorted(eligible, key=lambda pi: md5_rank(f"{pi[0].pid}:{pi[1]}:titrate"))
        goal = int(round(rate * len(eligible)))
        extra = 0
        for _ in range(20):
            chosen = {(p.index, i) for p, i in ranked[: goal + extra]}
            stepped = walk_regimens(group, start, stop, chosen)
            if stepped >= goal or goal + extra >= len(ranked):
                break
            extra += goal - stepped


def walk_regimens(group: list[Patient], start: datetime, stop: datetime, chosen: set) -> int:
    stepped = 0
    for p in group:
        level = p.start_level
        top = max_level(p.bucket)
        for i, v in enumerate(p.visits):
            if i > 0 and not v.controlled and p.bucket != "unreadable":
                if titration_eligible(p, i, start, stop):
                    up = (p.index, i) in chosen
                else:
                    up = md5_unit(f"{p.pid}:{v.at:%Y%m%d}:step") < FACILITY_PLAN[p.fac]["step_up"]
                if up and level < top:
                    level += 1
                    stepped += titration_eligible(p, i, start, stop)
            v.level = level
    return stepped


def statin_eligible(p: Patient, cal: Calendar) -> bool:
    if not p.dm or p.birth > cal.window_end.replace(year=cal.window_end.year - 40):
        return False
    seen = [v for v in p.visits if v.day <= cal.window_end]
    return bool(seen) and seen[-1].day >= cal.window_end - timedelta(days=364)


def assign_statins(patients: list[Patient], cal: Calendar) -> None:
    for fac in FACILITIES:
        rate = FACILITY_PLAN[fac]["statin"]
        group = [p for p in patients if p.fac == fac]
        eligible = [p.index for p in group if statin_eligible(p, cal)]
        on = quota(eligible, rate, "statin")
        for p in group:
            if p.index in on:
                take = True
            elif p.index in eligible:
                take = False
            elif p.dm:
                take = md5_unit(f"{p.pid}:statin") < rate
            else:
                take = md5_unit(f"{p.pid}:statin") < 0.03
            if not take:
                continue
            first = int(md5_unit(f"{p.pid}:statin-start") * len(p.visits))
            for v in p.visits[first:]:
                v.statin = True


def assign_phones(patients: list[Patient], cal: Calendar) -> None:
    """PHC-C: the reporting month's new patients mostly have no phone; later ones too."""
    for fac in FACILITIES:
        share = FACILITY_PLAN[fac]["phoneless_new"]
        if not share:
            continue
        group = [p for p in patients if p.fac == fac]
        phoneless = quota([p.index for p in group if in_np_cohort(p, cal)], share, "phone")
        for p in group:
            if p.index in phoneless or (p.registration > cal.np_to and md5_unit(f"{p.pid}:phone") < share):
                p.phone = None


def medicines_text(p: Patient, v: Visit) -> str:
    if p.bucket in ("step12", "step34"):
        parts = [LADDER_TEXT[v.level]]
    else:
        rung = OFF_LADDER_TEXT[p.bucket][min(v.level, max_level(p.bucket))]
        parts = [rung] if rung else []
    if p.bucket == "nohtn":
        parts.insert(0, METFORMIN_TEXT if p.dm else PARACETAMOL_TEXT)
    elif p.dm:
        parts.append(METFORMIN_TEXT)
    if v.statin:
        parts.append(p.statin_text)
    return "; ".join(parts)


def generate_cohort(cal: Calendar) -> list[Patient]:
    patients = build_patients(cal)
    build_visits(patients, cal)
    adjust_control(patients, cal)
    adjust_ratios(patients, cal)
    assign_regimens(patients, cal)
    assign_statins(patients, cal)
    assign_phones(patients, cal)
    return patients


def cohort_frame(patients: list[Patient]) -> pd.DataFrame:
    rows: list[dict] = []
    for p in patients:
        for v in p.visits:
            rows.append({
                "Registration Date": format_upload_datetime(p.registration),
                "Patient ID": p.pid,
                "First Name": "Demo",
                "Middle Name": np.nan,
                "Last Name": f"Patient {p.index:05d}",
                "Date of Birth": p.birth.strftime(DATE_FMT_SHORT),
                "Gender": p.gender,
                "Phone Number": p.phone if p.phone else np.nan,
                "Region": p.facility["Region"],
                "District": p.facility["District"],
                "Facility": p.facility["Facility"],
                "Sub Facility": p.facility["Sub Facility"],
                "Systolic": v.sys,
                "Diastolic": v.dia,
                "Visit Time": format_upload_datetime(v.at),
                "Blood Sugar Type": v.bs_type,
                "Blood Sugar Value": v.bs_value,
                "Diagnosis 1": "I10",
                "Diagnosis 2": "E11" if p.dm else "",
                "Medicines": medicines_text(p, v),
            })
    rows.sort(key=lambda r: (r["Patient ID"], parse_upload_datetime(r["Visit Time"])))
    return pd.DataFrame(rows, columns=COLUMNS)


def planted_numbers(patients: list[Patient], cal: Calendar) -> list[str]:
    """The numbers the reports should show, worked out from the rows (before the call seed)."""
    lines = [f"Planted for {cal.month_start:%Y-%m} (before seeds; the call seed moves loss and phone slightly):",
             f"{'Facility':<8}{'Control':>9}{'Titration':>11}{'NP loss':>9}{'Phone':>8}{'Statin':>8}"]
    out_q = []
    for fac in FACILITIES:
        group = [p for p in patients if p.fac == fac]
        elig = [(p, i) for p in group for i in range(len(p.visits))
                if titration_eligible(p, i, cal.titration_from, cal.titration_to)]
        up = sum(1 for p, i in elig if p.visits[i].level > p.visits[i - 1].level)
        coh = [p for p in group if in_np_cohort(p, cal)]
        lost = sum(1 for p in coh if not any(p.visits[0].at < v.at <= p.visits[0].at + timedelta(days=90)
                                             for v in p.visits[1:]))
        phone = sum(1 for p in coh if p.phone)
        st = [p for p in group if statin_eligible(p, cal)]
        on = sum(1 for p in st if [v for v in p.visits if v.day <= cal.window_end][-1].statin)
        lines.append(f"{fac:<8}{100 * control_pct(patients, cal, fac):>9.1f}{100 * up / max(len(elig), 1):>11.1f}"
                     f"{100 * lost / max(len(coh), 1):>9.1f}{100 * phone / max(len(coh), 1):>8.1f}"
                     f"{100 * on / max(len(st), 1):>8.1f}")
        cells = []
        for q in cal.quarters:
            a, b = quarter_counts(patients, fac, q)
            cells.append(f"{a}/{b}={a / max(b, 1):.2f}")
        out_q.append(f"{fac:<8}" + "".join(f"{c:>16}" for c in cells))
    lines.append("130-139 / 140-149 per quarter: " + ", ".join(f"{q.year}-Q{(q.month - 1) // 3 + 1}" for q in cal.quarters))
    lines.extend(out_q)
    lines.append("Stepping up per month (3-month window, visits up to 30 days before data end):")
    for fac in FACILITIES:
        group = [p for p in patients if p.fac == fac]
        cells = []
        for back in range(8, -1, -1):
            m_start = add_months(cal.month_start, -back)
            w_end = add_months(m_start, 1) - timedelta(days=1)
            stop = min(w_end, cal.as_of.replace(hour=0, minute=0, second=0)) - timedelta(days=30)
            elig = [(p, i) for p in group for i in range(len(p.visits))
                    if titration_eligible(p, i, w_end - timedelta(days=89), stop)]
            up = sum(1 for p, i in elig if p.visits[i].level > p.visits[i - 1].level)
            cells.append(f"{100 * up / max(len(elig), 1):.0f}")
        lines.append(f"{fac:<8}" + " ".join(f"{c:>4}" for c in cells))
    return lines


def summarize_dates(frames: Iterable[pd.DataFrame]) -> tuple[datetime | None, datetime | None]:
    parsed: list[datetime] = []
    for frame in frames:
        for col in ("Visit Time", "Registration Date"):
            if col not in frame.columns:
                continue
            for value in frame[col]:
                dt = parse_upload_datetime(value)
                if dt is not None:
                    parsed.append(dt)
    if not parsed:
        return None, None
    return min(parsed), max(parsed)


def default_as_of() -> datetime:
    today = datetime.now()
    if today.year == 2026 and today.month == 10:
        return today.replace(hour=23, minute=59, second=59)
    return DEFAULT_AS_OF


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--as-of",
        type=lambda s: datetime.strptime(s, "%Y-%m-%d").replace(hour=23, minute=59, second=59),
        default=None,
        help="As-of date for the cohort (YYYY-MM-DD)",
    )
    args = parser.parse_args()
    as_of = args.as_of or default_as_of()

    root = Path(__file__).resolve().parent
    demo_path = root / "demo_generated.xlsx"
    cal = Calendar(as_of.replace(hour=0, minute=0, second=0))
    patients = generate_cohort(cal)
    demo_df = cohort_frame(patients)
    demo_df.to_excel(demo_path, index=False)

    gen_min, gen_max = summarize_dates([demo_df])
    unique_patients = demo_df["Patient ID"].nunique()
    visit_rows = len(demo_df)

    print(f"as_of={as_of.date().isoformat()}")
    print(f"generated_patients={unique_patients}")
    print(f"generated_visit_rows={visit_rows}")
    print(f"generated_rows_with_medicines={int(demo_df['Medicines'].fillna('').ne('').sum())}")
    print(f"generated_date_range={gen_min} .. {gen_max}")
    print(f"output: {demo_path}")
    print("")
    print("\n".join(planted_numbers(patients, cal)))


if __name__ == "__main__":
    main()
