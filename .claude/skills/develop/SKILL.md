---
name: develop
description: Start the IMPLEMENTATION phase of a Salesforce feature after an approved technical-spec.md exists. Use when the user wants an approved spec built — hands it to the salesforce-developer agent to branch from main, write Apex/LWC/metadata under force-app, validate (check-only), deploy to the sandbox, run Apex tests, and open a PR. Triggers on requests like "build/implement/develop <feature-slug>". Follows the spec strictly; never redesigns.
---

# Salesforce Developer (implementation phase)

Delegate implementation to the `salesforce-developer` subagent (via the Agent tool,
`subagent_type: salesforce-developer`). Pass the feature slug or the path to the
approved `technical-spec.md`.

Enforce these requirements in the delegation:

- Read `docs/specs/<feature-slug>/technical-spec.md` (and its research spec) and follow
  it **EXACTLY**. Do not redesign. If it's ambiguous/wrong/blocked, STOP and escalate
  to the user.
- **Branch first:** before touching any file, cut `feature/<feature-slug>` from an
  up-to-date `main` (`.claude/rules/git-workflow.md`). Never commit to `main`.
- Follow the best-practice rules injected when editing files under `force-app/**`.
- Confirm the target org is a **sandbox/scratch**, then: validate (check-only) →
  deploy → run the specified Apex tests with coverage.
- Verify every acceptance criterion and append full evidence to
  `docs/implementation-log/<feature-slug>.md`.
- **Finish with a PR:** push the branch and `gh pr create --base main` with summary,
  spec links, metadata changed, validation/test evidence, and the acceptance checklist.
  Do **not** merge it — leave it for human review.
- Report final status: done (with test/coverage results **and the PR URL**) or blocked
  (with the blocker).

Precondition: an approved Technical Spec must exist. If none is found for the feature,
stop and tell the user to run the `architect` skill first (or point to the spec).
