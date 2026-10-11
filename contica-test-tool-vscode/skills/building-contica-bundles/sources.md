# Where bundle data lives, and how to fetch it

One section per kind of source. Each section says what to ask, the scripted
route (best first), the MCP route if a connector is connected, the manual
fallback, and the **access the person needs**. Tell them the access before
they run anything, so a 403 is not the first thing they see.

Sign-in rule for every script: use the person's own interactive sign-in
(`az login`, Git Credential Manager). Never put a password, PAT or key in the
script or in the bundle. If a PAT is unavoidable, read it from an environment
variable the person sets in their own session.

## Quick map: category to usual source

| Bundle category | Usually lives in | Fallback |
|---|---|---|
| `code/` workflow.json, connections.json, C# mappers | Azure DevOps repo (sometimes GitHub) | Portal: workflow > Code view, copy |
| `schemas/` | Same code repo (`LogicApp/Artifacts/Schemas/`) | Hand-over folder, vendor library |
| `documentation/` | Azure DevOps wiki, Confluence, or a Markdown file in the code repo | Copy the page text into a `.md` |
| `mappings/` `.xlsx` | SharePoint / Teams document library, sometimes the repo | Download from the browser |
| `examples/` | Logic App run history, Service Bus (test env), test team's files | Paste from the portal into a file |
| `standards/` | Contica standards pages (wiki or Confluence) | Copy from another bundle |

Ask "where is X?" per row. If they do not know, ask where the integration's
code repo is first: repos often hold the docs (`README`, `docs/`), schemas and
sometimes the mappings too, so one clone can answer several rows.

---

## Azure DevOps repo (code, schemas, sometimes docs and mappings)

**Ask:** organisation, project, repo name (or the clone URL
`https://dev.azure.com/{org}/{project}/_git/{repo}`), and the branch that
matches what is deployed to test (often `main` or `develop`).

**Script (best):** clone once into a source cache outside the bundle, then
`git pull` on every run; copy only the needed files into the bundle.

```powershell
git clone https://dev.azure.com/{org}/{project}/_git/{repo} .sources/{repo}
git -C .sources/{repo} pull --ff-only
```

Git for Windows ships Git Credential Manager, which opens a browser sign-in
the first time. No PAT needed.

**Access needed:**
- Member of the Azure DevOps project, **Basic** access level (Stakeholder
  cannot use Repos in a private project).
- **Read** on the repository (the project's Readers or Contributors group
  gives this).
- Only if they cannot use the browser sign-in: a PAT with scope
  **Code (Read)**, kept in an environment variable.

**A repo that is only on disk** (a local clone, a folder from a colleague): use its folder path as the `Url`; `git clone` accepts it.

**GitHub instead:** `git clone https://github.com/{owner}/{repo}` with
`gh auth login` or Git Credential Manager; needs Read on the repo.

**What to take:** see the include/exclude lists in `reference.md` (workflow
folders, the mapper's entry class, `Mappers/`, helpers; never `Models/`,
`Deployment/`, `APIM/`, `Tests/`).

## Azure DevOps wiki (documentation, standards)

Two kinds; ask which, or check the wiki's URL:
- **Project wiki:** its own Git repo named `{Project}.wiki`.
- **Code wiki:** a folder inside a normal repo (then treat it as the repo
  above).

**Ask:** organisation, project, wiki name, and the page path(s) for the
integration (e.g. `/Integrations/INT0542 Order intake`).

**Script (best):** clone the wiki repo; pages are already Markdown, which is
exactly what `documentation/main_documentation.md` needs.

```powershell
git clone https://dev.azure.com/{org}/{project}/_git/{Project}.wiki .sources/wiki
git -C .sources/wiki pull --ff-only
```

Page files are named after the page title with spaces as `-` and special
characters percent-encoded (e.g. `INT0542-Order-intake.md`); subpages sit in a
folder with the parent page's name.

**Alternative script (one page, no clone):** the wiki REST API with an Entra
token from `az login`:

```powershell
$tok = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
$url = "https://dev.azure.com/{org}/{project}/_apis/wiki/wikis/{wiki}/pages?path=" +
       [uri]::EscapeDataString('/Integrations/INT0542 Order intake') +
       "&includeContent=true&api-version=7.1"
$page = Invoke-RestMethod $url -Headers @{ Authorization = "Bearer $tok" }
[IO.File]::WriteAllText("$PWD\INT0542\INT0542.i001\documentation\main_documentation.md",
  $page.content, (New-Object Text.UTF8Encoding($false)))
```

**Access needed:**
- Project member. To **clone** the wiki repo: **Basic** access and Read on
  the wiki repo (Contributors and Readers have it by default).
- **Stakeholder** access can read a *project* wiki in the browser but cannot
  use Repos, so the clone route fails; ask for Basic or copy the page by hand.
  Stakeholders cannot read *code* wikis in private projects at all.

## Confluence (documentation, standards)

**Ask:** the site (`https://{site}.atlassian.net`), and the page URL for the
integration and for each entity page if there are separate ones. The page id
is the number in the URL.

**MCP (best when connected):** if Atlassian tools are available
(`getConfluencePage`, `searchConfluenceUsingCql`), fetch the page with them
and write the body to `main_documentation.md`. Search by the integration id
(`INT0542`) to find entity pages the person forgot to mention.

**Script:** REST with an API token (created by the person at
id.atlassian.com, kept in an environment variable):

```powershell
$pair = "$env:ATLASSIAN_EMAIL:$env:ATLASSIAN_API_TOKEN"
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
$page = Invoke-RestMethod "https://{site}.atlassian.net/wiki/api/v2/pages/{pageId}?body-format=storage" -Headers @{ Authorization = $auth }
```

The body is Confluence HTML, not Markdown. If `pandoc` is installed, convert
with `pandoc -f html -t gfm`; otherwise strip tags and keep headings and
paragraphs. Check the result reads well: it is what the AI quotes.

**Access needed:** **View** permission on the space; an Atlassian API token
for scripts.

## SharePoint / Teams document library (mappings, sometimes examples)

**Ask:** the library or folder link, and which file is the *current* mapping
per entity (libraries often hold old go-live copies next to it).

**Best for scripts: sync the folder.** In the browser, open the folder and
choose **Sync** (or **Add shortcut to My files**). OneDrive then keeps a local
copy, usually under `%USERPROFILE%\{Company}\{Site} - {Library}\...`, and the
build script copies from that path like any local folder. No tokens, always
current.

**Script via Microsoft Graph** (when syncing is not allowed): the
`Microsoft.Graph` PowerShell module, `Connect-MgGraph -Scopes Files.Read.All`,
then download by path. The scope may need an admin's consent in some
tenants; if the sign-in asks for approval, fall back to syncing.

**MCP:** if a SharePoint/Microsoft 365 connector is connected, use it to
*find* the current files (search by entity id); downloading is still easiest
through the synced folder.

**Access needed:** **Read** on the library or folder.

## Logic App run history (example messages)

The best happy-path example is the trigger input of a recent **successful**
run in the **test** environment.

**Ask:** subscription, resource group, Logic App name, workflow name per
entity, and whether it is Standard or Consumption.

**Script (Standard):** list runs, take the newest successful one, follow the
trigger's `outputsLink`, save the body.

```powershell
$base = "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}" +
        "/providers/Microsoft.Web/sites/{app}/hostruntime/runtime/webhooks/workflow/api/management" +
        "/workflows/{workflow}"
$runs = az rest --method get --url "$base/runs?api-version=2018-11-01&`$top=50" | ConvertFrom-Json
$run  = $runs.value | Where-Object { $_.properties.status -eq 'Succeeded' } | Select-Object -First 1
$link = $run.properties.trigger.outputsLink.uri      # pre-signed, no auth header
$out  = Invoke-RestMethod $link
$out.body                                             # the message the trigger received
```

For Consumption the base is
`/providers/Microsoft.Logic/workflows/{workflow}` with `api-version=2016-06-01`.
The build script's `$RunHistory` reads Standard only; for Consumption, run
the lines above by hand and save the body into the inbox.

The build script writes fetched messages to an **inbox outside the bundle**
(`%LOCALAPPDATA%\ConticaBundleSources\INT####\_inbox\`), never straight into
`examples/`: the tool's Sync shares everything in the bundle repo, so the
person picks the happy path and checks for personal data first (see
SKILL.md step 5).

If the run shows "secured inputs/outputs", the content is hidden by design;
use another source.

**Access needed:**
- Standard: **Logic Apps Standard Reader** on the Logic App (reading run
  history is a read; listing trigger URLs is not needed here). This is only
  for collecting examples: running tests needs more (see `testing.md`).
- Consumption: **Logic App Operator** (or Reader) on the Logic App.
- `az login` with the account that has the role.

## Service Bus (example messages)

**Ask:** namespace, queue or topic/subscription, environment (test only).

**Route:** Azure portal > namespace > queue > **Service Bus Explorer** >
**Peek Mode** > **Peek from start**, open a message, copy the body into a
file in the inbox (see above). Peek is non-destructive. Never use **Receive**
mode with ReceiveAndDelete: it removes the message from the queue.

There is no `az` command for peeking; a script would need the Service Bus SDK.
For a handful of examples the portal is the honest answer.

**Access needed:** **Azure Service Bus Data Receiver** on the queue/topic (or
namespace). Data Sender alone cannot peek.

## Local folders and hand-over packs

Ask for the path. The build script copies from it like any other source.
Hand-over packs often contain `.docx`/`.pdf`; those cannot be read by the
tool and must be converted to `.md` (docs) or left out (PDF copies of
spreadsheets).

## Jira (optional metadata)

`jiraEpic`/`jiraKey` are optional. If Atlassian tools are connected, search
for the integration id to fill them; otherwise leave them out.
