# Vendor integration checklist for aggregate JSON ingest

Use this checklist before first production-like submission.

## 1) Access and identity

- [ ] We received ingest endpoint URL and environment (dev, uat, prod).
- [ ] We received authentication method and token or credential.
- [ ] We agreed the `reporter.identifier.value` source key for our system.
- [ ] We know retry policy and rate limits.

## 2) Org-unit mapping

- [ ] We have central `org_units.id` list or approved external code map.
- [ ] Every facility we report can resolve to one central org unit.
- [ ] We tested at least one intentionally bad org unit and confirmed rejection reason.

## 3) Payload contract

- [ ] We send `resourceType=AggregateIndicatorSubmission`.
- [ ] We send unique `identifier.value` per submission.
- [ ] We send monthly `period.start` and `period.end`.
- [ ] We send `bp_controlled`, `bp_uncontrolled`, and `missed_visit`.
- [ ] Indicator values are non-negative numbers.
- [ ] We preserve semantic meaning of `missed_visit` used by our source.

## 4) Idempotency and replay

- [ ] We can resend the same submission without creating duplicates.
- [ ] We tested corrected resubmission for one org unit and saw value replacement.
- [ ] We log submission IDs and timestamps on our side.

## 5) Validation and error handling

- [ ] We parse row-level rejection reasons.
- [ ] We can fix and resend only affected rows.
- [ ] We alert our team when submission status is `partially_accepted` or `rejected`.

## 6) Sign-off sample

- [ ] One full-month payload accepted for at least 3 org units.
- [ ] Core indicators visible in central reporting tables.
- [ ] Joint data check with central admin completed.
