# RULE: Git Branching & Pull Requests — MANDATORY (Developer)

The Developer never commits directly to `main`. All implementation work happens on a
feature branch and lands via a Pull Request for human review.

## 1. Branch before you build
Before creating or editing ANY file under `force-app/**`:
```
git checkout main
git pull --ff-only origin main      # start from up-to-date main
git checkout -b feature/<feature-slug>
```
- Branch name: `feature/<feature-slug>` — the **same slug** used for the spec and log
  folders. Use `fix/<slug>` for defect work, `chore/<slug>` for non-functional changes.
- If the working tree is dirty before branching, STOP and ask the user — never stash or
  discard their in-progress work.
- If the branch already exists, ask the user whether to reuse or branch fresh.

## 2. Commit as you go
- Small, coherent commits with imperative messages: `Add InvoiceService and trigger handler`.
- Never commit secrets, org-specific IDs, `.sfdx/`, or `node_modules/` (see `.gitignore`).
- Commit the spec/implementation-log updates along with the code they describe.
- Footer on every commit:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```

## 3. Open a PR at the end
Only after validate → deploy → tests pass and acceptance criteria are verified:
```
git push -u origin feature/<feature-slug>
gh pr create --base main --head feature/<feature-slug> --title "<Feature Name>" --body "..."
```
The PR body must include:
- **Summary** — what was built, in plain language.
- **Spec links** — `docs/specs/<feature-slug>/research-spec.md` and `technical-spec.md`.
- **Metadata changed** — objects/fields, Apex, LWC, permission sets.
- **Validation evidence** — validate id, deploy id, target sandbox alias, Apex test
  results and coverage % (per `metadata-deployment.md`).
- **Acceptance criteria** — checklist with each item confirmed.
- **Reviewer notes / risks** — anything a human should scrutinize; out-of-scope items.
- Footer: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

## 4. Rules of engagement
- **Never** merge the PR yourself — a human reviews and merges.
- **Never** force-push to `main` or to a shared branch.
- Record the branch name and the PR URL in `docs/implementation-log/<feature-slug>.md`.
- If `gh` is not authenticated or the push fails, STOP and report it — do not work around
  it by committing to `main`.
