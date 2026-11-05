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
- Run `bundle exec rake verify` before handing off. Shared release safeguards
  and fixtures live in [Gemkit](https://github.com/ethos-link/ethos-gemkit).

## Git Standards

- Use `main` as the canonical integration branch.
- Never commit directly to `main` or `master`.
- Gemkit prepares releases on conventional branches; workflow publication
  follows the reviewed release PR merge.
- Use branches for all development work.
- Use Conventional Commits with a concise body explaining why the change
  exists, the approach, and relevant constraints.
- Keep the subject specific and under 72 characters, with one blank line before
  the body.
- Follow the `git-standards` skill for the full validation checklist.
