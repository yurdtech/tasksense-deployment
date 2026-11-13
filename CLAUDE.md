# Claude Code instructions for tasksense-deployment

This repository is **public**. Anyone can read, and git history keeps:

- every file;
- commit messages, author names and author emails;
- branch names, PR titles and descriptions;
- release notes and release assets.

Write each of them as if a stranger will read it, because one will.

## No customer specifics, ever

Nothing here may identify a customer, a pilot, or the people and systems behind an installation:

- **Who they are:**
  - a customer's organisation, brand or subsidiary names;
  - the ticket keys of their trackers.
- **Their systems:**
  - hostnames, domains and IP addresses;
  - cluster, namespace and registry project names;
  - certificate file names.
- **Their email addresses**, including a commit's author email.
- **Their data:**
  - Jira and Confluence sizes;
  - issue, user and seat counts;
  - backup sizes;
  - licence terms.
- **Their people:** names and staff ids.
- **Anything that points to one installation:**
  - its region or time zone;
  - wording that gives the customer or their sector away, such as "for the pilot at <company>".

Use neutral placeholders:

- `Example Corp`, `example.com`, `*.corp.internal`, `admin@corp.internal`;
- `*.acme.invalid` in tests;
- `Europe/Berlin`;
- round example numbers ("a 10 GB backup").

A lesson from a real installation is written as the general case, without that installation's names or numbers. Write "a CA path with a leading space", not the file a customer used.

## Commit identity

Commit as `memmedov-karim <71795994+memmedov-karim@users.noreply.github.com>`, set with `git config --local`. Never commit with a corporate address. Before the first commit in a clone, check `git config user.email`.

## Before every commit and push

- Read `git diff --cached` and the commit message as a stranger would.
- The clone may have a local term check (`.git/hooks/pre-commit`, `.git/hooks/commit-msg`). Never bypass it with `--no-verify`. If it fires, rewrite the text; do not work around the check.
- PR descriptions and release notes follow the same rule.
