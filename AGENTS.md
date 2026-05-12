# AI Agent Playbook

Repository-specific rules for code-generation agents. Keep changes minimal,
validated, and aligned with this gem's public API.

## Core Workflow

- Prefer surgical edits. Do not reformat unrelated code or shuffle files.
- Read actual files, signatures, call sites, and tests before changing code.
- Preserve public APIs unless the requested change requires a contract update.
- Keep the gem reusable; do not add host-app-specific routes, models, or copy.
- Add or update focused tests when behavior changes.
- Do not commit secrets, credentials, tokens, or decrypted values.

## Release And Upgrade

- Release changes must preserve existing `CHANGELOG.md` history.
- Use the release task instead of hand-editing version files and tags.
- Changelog pull request references must link to PRs, not issues.
- When a change breaks or changes a public contract, update `UPGRADE.md` in
  the same change with explicit host-app migration steps.
- Before finishing release-harness changes, run the focused release tests and
  a `git-cliff` smoke check.

## Commit Messages

- Use Conventional Commits: `feat`, `fix`, `docs`, `test`, `refactor`, or
  `chore`.
- Keep the subject imperative, specific, and under 72 characters.
- Leave a blank line between the subject and body.
- Write one coherent reason per commit; split unrelated work first.
- Use the body when the reasoning matters. Explain why the change exists,
  what approach was taken, and what constraints or side effects matter.
- Wrap body lines at 72 characters so commit hooks and terminal tools stay
  readable.
- Avoid vague subjects such as `misc fixes`, `updates`, or `cleanup` unless
  the cleanup is the actual scoped purpose.
- Mention verification in the body when it materially helps future readers.
