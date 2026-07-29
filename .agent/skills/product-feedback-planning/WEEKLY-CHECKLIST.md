# Weekly PM Checklist for Feedback-Driven Planning

Use this as a fast weekly operating checklist for TalonTracker.

## 1) Collect

- Gather new feedback from CurseForge comments, issues, and tester notes.
- Merge into one list with source and date.
- Remove exact duplicates (keep duplicate count).

## 2) Triage

For each item, tag:

- Type: bug, UX friction, feature request, performance, docs
- Severity: blocker, major, minor
- Scope: core timer, session, layer, anti-grief, telemetry, deploy, other

## 3) Score

Score each feedback cluster 1-5:

- Impact
- Frequency
- Confidence
- Effort

Priority score:

- (Impact x Frequency x Confidence) / max(Effort, 1)

## 4) Decide

- Ship now: top 1-3 highest-value items
- Next: validated but lower score items
- Later: speculative or high-effort/low-signal items

Always prioritize:

- Broken core behavior
- Data loss/persistence issues
- Repeated friction affecting many users

## 5) Plan

For each "Ship now" item, define:

- Problem statement
- Smallest implementation
- Acceptance criteria
- Test checklist rows for PLAN.md
- Risk + rollback note

## 6) Build and Validate

- Implement smallest shippable change.
- Verify against acceptance criteria.
- Confirm no regressions in timers/session/layer basics.

## 7) Communicate

- Publish short release notes:
  - "You asked"
  - "We shipped"
  - "What we need feedback on next"
- Ask one focused question for next cycle.

## 8) Close the Loop

- Link shipped changes back to original feedback themes.
- Mark completed roadmap items in PLAN.md.
- Archive this cycle's feedback snapshot for trend tracking.

## Release Readiness Gate (must pass)

- Acceptance criteria exist and are testable.
- Verification checklist updated.
- Risky changes have fallback behavior.
- Changelog entry prepared.
