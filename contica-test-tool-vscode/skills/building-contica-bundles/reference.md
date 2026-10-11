# Bundle format reference

What the Contica Test Tool (version 2.0.0) does with a bundle, taken from
its loader code. `check-bundle.ps1` checks the same rules, and
`build-template.ps1` writes manifests that follow them.

## Layout

```
INT0542/                                   integration folder: INT + 4 digits, capitals
  manifest.json                            scope "integration" (shared files)
  documentation/INT0542 Order intake.md    shared main documentation (optional)
  standards/Error handling guide.md
  schemas/                                 shared: canonical schema, type library
  code/connections.json
  INT0542.i001/                            entity: INT####.{i|o}NNN[T]; i/o lowercase, T capital
    manifest.json                          scope "entity"
    documentation/main_documentation.md
    examples/INT0542.i001 happy-path.json
    schemas/OrderHubOrder.json             the entity's own schema
    mappings/INT0542.i001 - Incoming order.xlsx
    code/order-intake-wf/workflow.json     folder = the workflow's name in Azure
    code/maps/OrderToCanonical.xslt        map file, name as the workflow uses it
    code/OrderMapper/OrderMapper.cs        C# mapper code
```

Folder names inside an entity are conventions; the manifest `path` values
are what the tool follows. A file not listed in a manifest is never read.
The build script writes both manifests from its CONFIG.

## Manifests

Integration (`INT0542/manifest.json`), as the build script writes it:

```json
{
  "manifestVersion": 1,
  "scope": "integration",
  "integrationId": "INT0542",
  "integrationName": "Order intake",
  "fetchedAt": "2026-10-11T09:30:00Z",
  "fetchedBy": "build-INT0542.ps1",
  "sourceProvenance": { "kind": "scripted", "rootPath": "" },
  "sharedFiles": {
    "documentation": [ { "path": "documentation/INT0542 Order intake.md", "purpose": "main-documentation" } ],
    "standards":     [ { "path": "standards/Error handling guide.md", "purpose": "error-handling" } ],
    "code":          [ { "path": "code/connections.json", "purpose": "connection-config" } ]
  },
  "entities": ["i001"]
}
```

Entity (`INT0542/INT0542.i001/manifest.json`):

```json
{
  "manifestVersion": 1,
  "scope": "entity",
  "integrationId": "INT0542",
  "entityId": "i001",
  "entityName": "Incoming order - Webshop",
  "direction": "inbound",
  "sourceSystem": "Webshop",
  "targetSystem": null,
  "fetchedAt": "2026-10-11T09:30:00Z",
  "fetchedBy": "build-INT0542.ps1",
  "inheritsFrom": "../manifest.json",
  "entityFiles": {
    "documentation": [ { "path": "documentation/main_documentation.md", "purpose": "main-documentation" } ],
    "examples":      [ { "path": "examples/INT0542.i001 happy-path.json", "purpose": "happy-path" } ],
    "schemas":       [ { "path": "schemas/OrderHubOrder.json", "purpose": "source" } ],
    "mappings":      [ { "path": "mappings/INT0542.i001 - Incoming order.xlsx", "purpose": "source-to-canonical" } ],
    "code": [
      { "path": "code/order-intake-wf/workflow.json", "purpose": "workflow-definition" },
      { "path": "code/maps/OrderToCanonical.xslt", "purpose": "transformation" },
      { "path": "code/OrderMapper/OrderMapper.cs", "purpose": "custom-code" }
    ]
  }
}
```

What the tool needs at minimum: an entity manifest with `"scope": "entity"`
and an `entityFiles` object. The folder names, not `integrationId` and
`entityId`, decide which integration and entity it is. `direction` follows
the i/o letter when left out. The integration manifest is optional, but
without it nothing is shared.

The tool writes to entity manifests too: `resource` (the Azure workflow it
tests against), examples added with **Add Example**, and `format`. The build
script keeps all of these.

Manifests may be saved with or without a byte-order mark; the tool reads
both.

## Purpose values

| Category | Allowed purposes |
|---|---|
| documentation | `main-documentation`, `trigger-documentation`, `architecture-note`, `business-rules` |
| examples | `happy-path`, `edge-case`, `reference`, `trigger-format`, `archived` |
| schemas | `source`, `target`, `canonical`, `shared-types` |
| mappings | `source-to-canonical`, `canonical-to-target`, `end-to-end`, `overview`, `archived` |
| standards | `error-handling`, `retry-policy`, `logic-apps-conventions`, `azure-functions-conventions`, `integration-standards` |
| code | `workflow-definition`, `connection-config`, `transformation`, `infrastructure`, `custom-code` |

## How the tool reads each category

| Category | What counts | Traps |
|---|---|---|
| documentation | The entity's `main-documentation` file (else its first), then the integration's shared `main-documentation` file, joined. Over 10,000 bytes together, only the first 8,000 reach the AI. Under 500 bytes, Analyse reports THIN_COVERAGE. | Shared documentation is read only from `.md`/`.txt` and only with purpose `main-documentation`. A `.docx`/`.pdf` as the entity's documentation is read as garbage text. |
| examples | Every entry that is not `archived`. The `happy-path` one (else the first listed) is the baseline for every generated test; only its content goes to the AI. | No example: Analyse stops with NO_EXAMPLE_MESSAGE. XML and JSON mixed, or a message that is neither: the entity is "unsupported" and nothing is generated. Fewer than 10 distinct fields (innermost fields and attributes, across all examples): THIN_COVERAGE. A `.txt` holding JSON is labelled XML; save it as `.json`. `reference` does not keep an example out of the baseline. |
| format | A manifest `format` of `xml` or `json` wins over what the examples contain; otherwise the tool detects it. | A wrong `format` makes the tests come out in the wrong dialect. Leave it out unless sure. |
| schemas | `.xsd`, `.json`, `.jschema`. `shared-types` counts as canonical. Each file is read on its own: `xs:include`/`xs:import` are not followed, so list every schema file you want read. | Other extensions are skipped with a warning. A big schema is cut to an outline for the AI; prefer the entity's own schema over a whole type library. |
| mappings | Only the entity's `.xlsx` files become rules, whatever their purpose (`archived` ones too). The parser looks in the first 8 rows of each sheet for header cells like "Source field" and "Target field" (also `src`, `from`, `target`, `tgt`, `destination`, `to`, `källfält`, `målfält`, "sending/receiving system property"). At most 500 rows per sheet. | Shared and end-to-end mappings are listed to the AI by name only, with no rules. `.xls`, `.csv` and mapping code are skipped with a warning. Sheets whose name contains archiv, deprecat, obsolete, legacy, history, version control or change record are skipped, as are names with "old" at the start or end of a word ("Old mapping", "Threshold") and "prior" at the start of a word (not "Priority"). "Golden" and "Holder" are read. |
| code | Text files only: `.json .cs .xml .xsd .xslt .liquid .md .txt .jschema .yaml .yml .sql .py .scala .js .ts .mjs .cjs`. | See "Code purposes" below. |
| standards | Shared and entity standards are both read; the entity's wins on the same file name. The content is used to check what the AI quotes; only file names go to the AI. | `.doc`, `.docx`, `.pdf` are skipped with a warning. |
| paths | Relative to the manifest. Must stay inside the `INT####` folder (`..` within it is fine). | Anything outside, or a link pointing outside, is refused and counts as missing. |
| names | Integration `INT####` in capitals; entity suffix lowercase `i`/`o`, optional capital `T`. | Other folder names are ignored. Wrong letter case works on Windows but fails on Mac and Linux. |

## Code purposes

| Purpose | Use it for | Why it matters |
|---|---|---|
| `workflow-definition` | Each `workflow.json`, saved as `code/{workflow name}/workflow.json` | The folder name is the workflow name the tool looks for in Azure, and the workflow Run locally starts. Without any code, the analysis notes that workflow, retry and routing ideas have little to go on. |
| `transformation` | Logic App maps (`.xslt`, `.liquid`) the workflow calls | Run locally puts these in the Logic App's Maps folder under their file name, so keep the name the workflow uses. |
| `custom-code` | C# Function / mapper code | Counted as mapper code by the analysis. |
| `connection-config` | `connections.json` | Sent to the AI in full (up to 20 KB). |
| `infrastructure` | `parameters.json`, host settings | Run locally uses a `parameters.json` from the bundle (addresses and secrets replaced). Only include it when it holds no secrets. |

**Run locally** needs one workflow that receives messages, with one HTTP or
Service Bus trigger. Steps the local runtime cannot run send the tester to
Run in Azure instead.

## Personal data

Before anything goes to the AI, and before Sync shares the bundle, the tool
scans for:
- email addresses outside `example.com/.org/.net`, `.example`, `.test`,
  `.invalid` and `localhost` (`@example.se` **is** flagged);
- Swedish personal identity numbers (including coordination numbers) that
  pass the date and check-digit tests; Norwegian, Finnish and Danish ID
  numbers;
- card numbers that pass the network prefix and Luhn checks (the common test
  card 4111 1111 1111 1111 **is** flagged);
- IBANs;
- international phone numbers;
- names, phone numbers, addresses, birth dates and ID numbers, found by
  field name (also Swedish field names). Obvious placeholders like "Test"
  are ignored.

The tool then asks the tester before going on. Use test data; never copy
production messages into a bundle. `check-bundle.ps1` checks the first four
kinds only, so a clean result there is necessary, not sufficient.

## Readiness, in the tool's terms

The sidebar gives each entity one point each for: documentation, an entity
mapping spreadsheet, a schema, code, and an example. 4 or 5 points is
**ready**, 2 or 3 **partial**, fewer **thin**. `check-bundle.ps1` prints the
same score.

Analyse separately rates the material as rich, adequate, thin or
unsupported, and reports THIN_COVERAGE when the documentation is under 500
bytes, the examples hold fewer than 10 fields, or there are fewer than 3
schemas, readable mapping spreadsheets and examples together.

## What to take from a code repo

Take: each entity's `workflow.json` (all of them if an entity has several),
`connections.json`, the maps under `Artifacts/Maps/`, the schemas under
`Artifacts/Schemas/`, the C# mapper's entry class, `Mappers/*.cs`, helpers
specific to that mapper, custom serializers, trigger classes.

Leave out: `Function/Models/` (generated classes), `Deployment/`, `APIM/`,
`Tests/`, `bin/`, `obj/`, repo-wide `README.md`/`.gitignore`/`.editorconfig`,
`.drawio`, `.docx`, `.pdf`, archived or go-live snapshot mappings, trigger
configuration spreadsheets, and any file holding secrets.
