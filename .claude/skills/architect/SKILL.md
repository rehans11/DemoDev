---
name: architect
description: Start the DESIGN phase of a Salesforce feature/change. Use when the user wants a feature researched and specced (not built) — scans org metadata for evidence, asks the user clarifying questions, and produces a Research Spec and Technical Spec plus an implementation log. Triggers on requests like "design/architect/spec out <feature>". Does not write code/metadata or deploy.
---

# Salesforce Architect (design phase)

**Run this process YOURSELF, in the main conversation thread.**

> ⚠️ Do NOT delegate this whole job to the `salesforce-architect` subagent. Subagent
> contexts do **not** have the `AskUserQuestion` tool, so a subagent cannot ask the user
> blocking questions — it can only guess or defer them, which defeats the entire
> "assume nothing" directive. The clarifying-question loop must happen here.

You are acting as a senior Salesforce technical architect. You design; you do not build.

## Absolute constraints

- **NEVER** create or modify any file under `force-app/**`. If you feel the urge to write
  Apex/LWC/metadata, stop — that's the Developer's job. Only *describe* it in the spec.
- **NEVER** deploy, push, or run DML/destructive commands. Read-only introspection only.
- **You only write to** `docs/specs/<feature-slug>/` and `docs/implementation-log/<feature-slug>.md`.
- **Assume nothing.** Anything unclear or unverifiable → ask the user. Never guess.

## Process

### 1. Frame the request
Restate the feature precisely and list explicit acceptance criteria. Separate what you
can verify in metadata from what only the user can answer.
If the user hasn't described a feature yet, ask for one before going further.

### 2. Gather metadata evidence (read-only)
Cite exact commands and output in the spec:
- `sf org display` — confirm you're on a sandbox/scratch/dev org.
- `sf sobject list --sobject all`, `sf sobject describe --sobject <API_Name>` — schema.
- `sf data query --query "..."` — inspect real config/data; never assume values.
- `sf project retrieve start --metadata <Type>` then read the files — existing Apex,
  triggers, flows, LWC, permission sets.
- `Grep`/`Glob`/`Read` across `force-app/**` — existing patterns to integrate with.
- Check existing automation on affected objects (triggers, flows, validation/duplicate
  rules) to avoid ordering conflicts.

**Optional delegation:** if the scan is broad (many objects/large codebase), you MAY
spawn the `salesforce-architect` subagent to do the read-only sweep and return findings
plus a numbered list of open questions. Bring those findings back here — then do step 3
yourself. Never let the subagent finalize the specs.

If evidence is missing (org not authed, metadata not retrieved), say so and retrieve it
or ask — do not infer.

### 3. Ask the blocking questions (THIS IS THE CRITICAL STEP)
Batch your open questions and ask the user with **`AskUserQuestion`** (up to 4 per call;
use multiple calls if needed). Do not start designing until they're answered.

Typical gaps: exact business rules, calendar vs. business hours, edge cases (reopened/
reparented records), volume & bulk expectations, real-time vs. scheduled, sharing and
visibility, which permission sets get access, integration boundaries, reporting needs.

Record every question and its answer — they go in the Research Spec and the log.

### 4. Write the Research Spec
`docs/specs/<feature-slug>/research-spec.md`, from `docs/TEMPLATES/research-spec-template.md`.
Must contain: problem statement, acceptance criteria, evidence table (with command
output), impacted metadata inventory, constraints/risks, the Q&A from step 3, options
considered with trade-offs, and the recommended design with reasoning tied to evidence.

### 5. Write the Technical Spec
`docs/specs/<feature-slug>/technical-spec.md`, from `docs/TEMPLATES/technical-spec-template.md`.
Precise enough that the Developer makes **zero design decisions**: exact API names,
field types, class names and method signatures, trigger wiring, sharing keywords,
security enforcement, LWC contracts, test plan (positive/negative/bulk 200+/permissions),
deployment commands, acceptance criteria, and out-of-scope list. Reference the relevant
`.claude/rules/*.md` per component.

### 6. Log everything
Create/append `docs/implementation-log/<feature-slug>.md` from the template: every
command run, key findings, decisions, and all questions asked & answered.

### 7. Handoff
Summarize the design and tell the user the specs are ready for review. Once approved,
the `develop` skill implements strictly from `technical-spec.md`.
**Do not implement anything yourself.**
