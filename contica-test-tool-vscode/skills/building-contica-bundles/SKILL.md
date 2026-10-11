---
name: building-contica-bundles
description: Use when someone needs to prepare, build, refresh or fix a bundle (an INT#### folder with manifest.json files) for the Contica Test Tool VS Code extension, when they ask where to find an integration's documentation, mappings, schemas, example messages or Logic App code for it, or when the tool reports NO_EXAMPLE_MESSAGE, THIN_COVERAGE, a missing entity or a thin/partial bundle.
---

# Building Contica bundles

## Overview

A bundle is the `INT####/` folder the Contica Test Tool reads: a manifest
for the integration and one per entity, plus the documentation, example
messages, schemas, mapping spreadsheets and code those manifests list. The
test plan is only as good as the bundle.

**Your job is to leave the person with one re-runnable build script and a
bundle that passes `check-bundle.ps1`.** They tell you where their material
lives; you write `build-INT####.ps1`, which fetches the files, copies them in
and writes every manifest. Next time their sources change, they run the
script again. No hand-made manifests, no one-off copying.

The person is usually a tester, not a developer. Talk about their
integration, not about loaders and enums.

Files in this skill (read them when the step says so):
- `reference.md`: layout, manifest fields, purposes, and exactly how the
  tool (version 2.0.0) reads each file.
- `sources.md`: per source (DevOps repo, DevOps wiki, Confluence,
  SharePoint, run history, Service Bus) the fetch route and the **access
  needed**.
- `scripts/build-template.ps1`: the build script you copy and fill in.
- `scripts/check-bundle.ps1`: the checker. Read-only, no install needed.

## Workflow

### 1. Pin down the integration

Ask, in one message:
- Integration id and name (`INT0542 Order intake`) and its entities
  (`i001`, `o001` ...). The id must be INT plus four digits. If they do not
  know the entities, find them in the documentation or the workflow names,
  then confirm.
- Where the bundle should live: normally their local clone of the team's
  bundle repo (the one the tool's Connect and Sync use). The build script
  goes in that repo's root, next to the `INT####` folder.

Azure Data Factory pipelines are not built with this skill: the tool has
its own "Import Data Factory" command for them.

### 2. Ask where each kind of material lives

Ask about all of these at once, offering the usual answers as choices (use
the question tool when available). "I don't know" is a valid answer:

| Material | Usual places |
|---|---|
| Logic App workflows, connections, maps, schemas | Azure DevOps repo, GitHub repo, local folder |
| C# Function / mapper code | The same repo |
| Documentation | Azure DevOps wiki, Confluence, Markdown in the repo, Word file |
| Mapping spreadsheets (.xlsx) | SharePoint/Teams library, the repo, local folder |
| Example messages | Logic App run history (test), Service Bus (test), the test team's files |
| Error-handling standard | Team wiki or Confluence page, another bundle |

For "I don't know": start from the code repo, which often holds docs,
schemas and sometimes mappings. If Atlassian, SharePoint or Azure DevOps
tools are connected in this session, search them by the integration id and
show what you found.

### 3. Tell them the route and the access before running anything

Look each source up in `sources.md` and present one table:

| Source | How the script fetches it | Access you need | How to check you have it |
|---|---|---|---|

Prefer, in order: a scripted route (git clone/pull, `az rest`), a synced
folder, an MCP connector, and only then a manual copy. Check access for real
before writing the script:
- git: `git ls-remote <url>` (a browser sign-in may open; that is fine)
- Azure: `az account show`, then one `az rest` GET on the Logic App
- folders: `Test-Path`

When a check fails, say exactly which role or group to ask for and who
usually grants it, and carry on with the sources that work.

### 4. Write the build script

Copy `scripts/build-template.ps1` to `build-INT####.ps1` in the bundle repo
root, and `scripts/check-bundle.ps1` next to it. Fill in **only the CONFIG
section**:

- `$Integration` and `$Entities`: names, systems (`$null` for the side an
  entity does not have: an inbound entity's target, an outbound entity's
  source). Leave `Format` out unless sure; never invent a Jira key.
- `$Sources`: one entry per repo or folder. A git source's `Url` can also be
  a local folder path. `$SourceCache` (default under `%LOCALAPPDATA%`) is
  where clones and the example inbox live; tell the person, and change it
  only if they ask.
- `$Files`, `$Folders`: what to copy, where to, and each file's `Category`
  and `Purpose` (tables in `reference.md`). The rules that matter most:
  - each workflow goes to `code/{exact workflow name in Azure}/workflow.json`
    (the folder name is how the tool finds the workflow to test);
  - Logic App maps (.xslt, .liquid) go under `code` with purpose
    `transformation`, keeping the **file name the workflow uses**; C# mapper
    code goes under `code` with purpose `custom-code`;
  - only `.xlsx` files go under `mappings`;
  - schemas: an inbound entity's message schema is `source`, an outbound
    entity's is `target`; a canonical schema both sides use goes in once,
    shared, as `canonical`, and counts for every entity;
  - documentation: the integration's page goes in **once**, as shared
    `main-documentation` (a `To` outside the entity folders); the tool adds
    it after each entity's own page, and uses it alone for an entity that
    has no page of its own. Each entity's own page is its
    `main-documentation`. Join several files into one only when an entity's
    own text is split over several pages (`From = @(...)`);
  - leave out `host.json`, deployment files and anything holding secrets.
    `parameters.json` may go in as `infrastructure` when it holds only
    references (`@appsetting(...)`), no secrets.
- `$RunHistory` when examples come from a Logic App's run history.

Show the person the source-to-bundle table and ask about anything unclear
before running: which spreadsheet is current, which workflow belongs to
which entity, whether a `.docx` should be converted. They decide; you do not
guess silently.

While reading the sources, note where they disagree (a retry count in the
standard versus the workflow, a field required in the docs but optional in
the schema). Do not resolve it; tell the person. Each one is a test question.

The script and `check-bundle.ps1` sit in the bundle repo, so Sync shares
them with the team. Paths in the CONFIG are this person's: prefer
`$env:USERPROFILE` and `$env:LOCALAPPDATA` over fixed paths, and add a
comment above each path a teammate must change to run it.

Run it with `-WhatIf` first, then for real. `-WhatIf` writes nothing to the
bundle, but it does clone or update git sources in the source cache (a
browser sign-in may open). The script ends by running the checker.

Things the script cannot fetch (Service Bus peeks, a Word document that
needs converting, a page behind a source they cannot reach): give them the
exact manual steps from `sources.md` and the target path, and list the
result under `$KeptFiles`.

### 5. Example messages: the tester decides

Candidates come from run history (the script puts them in the inbox under
the source cache) or from a folder the test team keeps. For each entity,
show the candidates and ask which one is the happy path (a normal,
successful message) and which, if any, are edge cases.

**Production messages are never used**, not even scrubbed, however
realistic someone says they are: they hold real customer data, and Sync
shares the bundle with the whole team. Say so, and pick a test-environment
message instead. If there is none, the entity waits for one.

Before a test message enters `examples/`, check it for personal data (rules
in `reference.md`). Test data sometimes holds a real-looking name, email or
number. Do not copy it as is and do not quietly edit it: offer a scrubbed
copy (emails at `example.com`, made-up numbers) and let them approve it, or
pick another message.

Getting an approved message into the bundle:
- from a folder source, unchanged: add it to `$Files` with `Category =
  'examples'`, so every run refreshes it;
- from the inbox, or a scrubbed copy: copy it into the entity's `examples/`
  folder yourself and list it under `$KeptFiles` with its purpose and a note
  on where it came from.

Then run the script again so the manifest lists it.

Outbound entities often have no message of their own. Look at the entity's
workflow trigger first: it names the queue, topic or address the message
arrives on (for example a Service Bus queue the inbound entity writes to).
Show the person that evidence and ask whether the upstream entity's output
is what this one receives; a peek on that queue in test is the usual way to
get the real message. If they are not sure,
**leave the entity's examples empty**: every example that is not `archived`
is used, and the happy-path one is the baseline for every generated test, so
a wrong message is worse than none. Analyse will stop with
NO_EXAMPLE_MESSAGE for that entity until they add the message it receives.

### 6. Check, fix, report

The script runs `check-bundle.ps1`. To run it yourself:

```powershell
powershell -ExecutionPolicy Bypass -File check-bundle.ps1 -BundleRoot .\INT0542
```

(`pwsh -File ...` when PowerShell 7 is installed.) Fix every BLOCKING and FIX
item you can by changing the CONFIG and re-running the script, never by
editing a manifest by hand. An entity you deliberately left without an
example stays BLOCKING, and the script then ends with exit code 1: the
bundle is still built, the entity just cannot be analysed yet. Say that
plainly. Ask about the rest. Then report to the person in their words:
- per entity: whether Analyse can run, and the readiness the sidebar will
  show (the sidebar counts files only, so it can say "ready" for an entity
  that is BLOCKING);
- what is missing and which tests that costs them ("no workflow.json, so no
  Run locally and nothing to find in Azure");
- the disagreements between sources you noted in step 4;
- how to refresh later: run `build-INT####.ps1`, then **Sync** in the
  tool's sidebar to share it with the team. Do not commit for them.

## Rules

- Copy, never move or edit the person's original files.
- No passwords, PATs or keys in scripts, manifests or the bundle. Sign-in is
  the person's own (Git Credential Manager, `az login`, MCP connectors).
- Test environments only for example messages.
- Read-only on every source. Never use Service Bus Receive mode; peek only.
- Change the bundle through the script's CONFIG. The script keeps what the
  tool itself adds to a manifest (the Azure workflow it tests, an example
  added with Add Example).

## Common mistakes

| Mistake | Effect | Instead |
|---|---|---|
| Workflow saved as `code/workflow.json` or under a folder not named like the Azure workflow | The tool cannot find the workflow to test; Run locally is not available | `code/{workflow name}/workflow.json` |
| C# mapper marked `transformation` | Not counted as mapper code | `custom-code` |
| XSLT/Liquid map marked `custom-code`, or renamed | Run locally cannot find the map the workflow calls | `transformation`, original file name |
| Mapping code listed under `mappings` | Not read (only .xlsx is) | List it under `code` |
| Copying the whole `Function/` folder | Generated `Models/` floods the AI's budget | Entry class, mappers, helpers only (`Exclude = @('Models\*')`) |
| Taking a mapping from an `Archive` folder, or a sheet named "Old ..." | Wrong or no rules | Ask which file is current; rename the sheet |
| Declaring `format: xml` for a JSON entity | Tests in the wrong dialect | Leave `Format` out |
| Production message as happy path, even scrubbed | Real customer data shared with the whole team | A test-environment message; scrubbed copy only of test data, approved by the tester |
| Guessing the happy path for an outbound entity | Generate changes the wrong message | Ask; if unsure, leave examples empty |
| Editing a manifest by hand | Overwritten on the next run | Change the CONFIG, re-run |
