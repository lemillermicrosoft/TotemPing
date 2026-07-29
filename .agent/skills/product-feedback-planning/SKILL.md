# Product Feedback Planning for WoW Addons

## Overview

Use this skill when the user wants a product-manager style process for turning player comments into high-impact feature plans.

Goal:

- review community comments consistently
- identify the highest-value problems to solve next
- convert feedback into scoped implementation plans
- communicate decisions back to players so they feel heard

Primary channels for TalonTracker:

- CurseForge comments
- GitHub issues (if used)
- in-game tester notes
- Discord or direct user notes

## When to use this skill

Use this skill when asked to:

- summarize user feedback for planning
- decide what to build next from comments
- create a roadmap or release priorities
- improve ratings, retention, and user trust

## PM operating principles

- Bias toward fixing real pain over adding novelty features.
- Prioritize reliability and clarity before expansion.
- Convert vague feedback into concrete user jobs.
- Keep implementation increments small and releasable.
- Close the loop publicly: players should see their feedback reflected.

## Weekly feedback loop

1. Collect feedback
- Pull all new comments and issue reports since last review.
- Normalize into a single list with source and date.

2. Triage each item
- Label by type: bug, UX friction, feature request, performance, docs.
- Label by scope: single-player, group play, setup/deploy, telemetry.
- Label by severity: blocker, major annoyance, minor polish.

3. Quantify signal
- Count duplicates and similar requests.
- Note affected user segment: new users, power users, all users.
- Estimate confidence from evidence quality (clear repro vs ambiguous).

4. Prioritize for next release
- Use simple score: Impact x Frequency x Confidence / Effort.
- Auto-prioritize:
  - blocker bugs
  - broken core loops (timers, session updates, visibility)
  - data-loss or persistence issues

5. Plan delivery
- Convert top items into roadmap phases with acceptance criteria.
- Define test checklist for each planned item.
- Identify dependencies and risks early.

6. Communicate back
- Post a concise changelog and "you asked, we shipped" notes.
- Reference which feedback themes were addressed.
- Ask one focused question for next iteration.

## Comment-to-plan template

For each feedback cluster, produce:

- Problem statement: what user pain is happening
- User value: why it matters in real gameplay
- Proposed solution: smallest useful implementation
- Acceptance criteria: objective pass/fail checks
- Telemetry (optional): what to log to validate improvement
- Rollout risk: what could regress

## Prioritization rubric (lightweight)

Score 1-5 each:

- Impact: how much better gameplay becomes
- Frequency: how often users hit this issue
- Confidence: clarity of evidence and repro
- Effort: implementation and test complexity

Suggested formula:

- Priority score = (Impact x Frequency x Confidence) / max(Effort, 1)

## Release quality gates

Do not ship a feature plan without:

- explicit acceptance criteria
- verification steps in PLAN.md checklist
- rollback strategy for risky behavior
- user-facing release note line

## What to tell a product manager directly

- Read every comment, but prioritize repeated pain and broken core behavior.
- Keep a visible "Now / Next / Later" roadmap tied to user feedback.
- Ship small fixes fast, then measure and refine.
- Over-communicate what changed and why.
- Build trust by resolving known annoyances before adding flashy features.

## TalonTracker-specific focus areas

Current high-value themes to monitor in comments:

- timer correctness and persistence
- session timer reliability and control UX
- anti-grief safety behavior
- layer detection clarity
- telemetry export/copy usability for reporting issues

## Output format for planning updates

When updating plans from comments, provide:

1. Top feedback themes (3-5 bullets)
2. Priority decisions (what ships now vs later)
3. Planned implementation items (scoped and testable)
4. Risks and mitigation
5. Draft release notes preview
