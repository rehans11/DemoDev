---
name: architect
description: Start the DESIGN phase of a Salesforce feature/change. Use when the user wants a feature researched and specced (not built) — hands the request to the salesforce-architect agent to scan org metadata, ask clarifying questions, and produce a Research Spec and Technical Spec plus an implementation log. Triggers on requests like "design/architect/spec out <feature>". Does not write code/metadata or deploy.
---

# Salesforce Architect (design phase)

Delegate the user's feature request to the `salesforce-architect` subagent (via the
Agent tool, `subagent_type: salesforce-architect`). Pass along the full feature
description the user provided.

Enforce these requirements in the delegation:

- **Assume nothing.** Gather metadata evidence (read-only) and ask the user clarifying
  questions via AskUserQuestion before designing.
- Produce `docs/specs/<feature-slug>/research-spec.md` and `technical-spec.md` from the
  templates in `docs/TEMPLATES/`.
- Log all steps and evidence in `docs/implementation-log/<feature-slug>.md`.
- Do **NOT** write any code/metadata under `force-app/**` and do **NOT** deploy.
- When done, summarize the design and tell the user it's ready for review before the
  `salesforce-developer` implements it.

If the user hasn't given a feature description yet, ask for one before delegating.
