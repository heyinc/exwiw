# AGENTS.md

## This repository is public

Everything here is world-readable: code, comments, fixtures, commit messages,
PR and issue text, review comments, and their edit history. Deleting or editing
text after the fact does not unpublish it.

Do not include anything that comes from a private codebase:

- table, column, model, or system names from a private application
- references to private repositories or their PR / issue numbers
- internal terminology, internal links (chat, wiki, tickets), or any customer or production data

Describe motivating cases with invented, generic names, and keep planning and
tracking in the private repository that needs the change. Re-read the title,
body, and commit messages against this list before committing or opening a PR.

## Development

See [README.md](README.md) for usage and [CHANGELOG.md](CHANGELOG.md) for the
release history. `bundle exec rake` compiles the native extension and runs the
specs; the scripts under `e2e/` need the databases from `compose.yml`.
