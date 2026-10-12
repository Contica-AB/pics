# What testing needs

Everything a tester needs to test a Logic App integration with the
Contica Test Tool (version 2.0.0), beyond the bundle files. Taken from the
tool's code. `check-bundle.ps1` prints, per entity, whether Run in Azure
and Run locally will work, using the same rules.

## The order of the work

1. **Analyse** reads the bundle and proposes a test plan.
2. **Approve** the plan. It cannot be approved while it has blocking gaps.
   A gap is something the tool could not prove from the bundle. In the
   Analyse tab, confirm each blocking gap or mark it not applicable; or add
   the missing material to the bundle and run Analyse again.
3. **Generate** builds the test pack: the broken messages.
4. **Test** sends them, in Azure or on the tester's own computer.

Analyse and Generate need no Azure access. Test needs a generated pack.

## What the bundle must have for testing

| Need | Why |
|---|---|
| `code/{workflow name}/workflow.json`, purpose `workflow-definition` | The folder name is how the tool finds the workflow in Azure. Without any `workflow.json` nothing can be sent, and Run locally is not offered. |
| The workflow that receives messages from outside | Test messages go to it. A workflow that only another bundle workflow calls is never sent to directly. When the first workflow starts on a schedule, the messages go to the workflows it calls (as a child workflow, through their HTTP trigger address, or through the queue or container they listen on), so those must be in the bundle too. `check-bundle.ps1` names the workflow the messages will go to. |
| A trigger the tool can send to | HTTP (Request), Service Bus (queue or topic), or Blob. A schedule cannot be sent to. |
| Queue, topic or container the bundle can name | Written out in the trigger, or written as exactly `@parameters('name')` with a plain value for that parameter in the Logic App's `parameters.json`, included in the bundle's code (versions after 2.0.0; 2.0.0 refuses parameters too). A name from an app setting (`@appsetting(...)`), a parameter with no plain value, or one that two `parameters.json` files give differently, makes Run in Azure refuse to send: the bundle cannot say which one is right. Run locally still works. |
| Logic App maps (`.xslt`, `.liquid`) under `code`, purpose `transformation`, original file name | Run locally runs the maps the workflow calls only when they are in the bundle under that name. |
| `parameters.json` (optional, no secrets) | Run locally uses it, with addresses and secrets replaced; without it every parameter is "placeholder". |

Only **Logic Apps Standard** is supported. Consumption Logic Apps, Function
Apps and API Management are not test targets. A Consumption integration can
still be analysed and get a generated test pack; the messages then have to be
sent some other way.

## Azure access (Run in Azure)

Everything runs as the tester's own Azure account; the tool has no identity
of its own. Roles, on the resources tests are sent to:

| Resource | Role | Needed for |
|---|---|---|
| Logic App (Standard) | **Logic Apps Standard Operator** | Always: listing workflows and triggers, getting the trigger address, reading run history. Reader is not enough: getting the trigger address is an action. |
| Service Bus queue or topic | **Azure Service Bus Data Sender** | Sending to a Service Bus trigger. |
| Blob container | **Storage Blob Data Contributor** | Uploading to a Blob trigger. |
| Service Bus namespace or storage account | **Reader** | Picking it and checking it before each run (Service Bus and Blob only). |

An HTTP-triggered workflow needs only the first row.

Two different "Reader" roles, for two jobs: **Logic Apps Standard Reader**
is enough to *read run history* when collecting example messages for the
bundle (`sources.md`), but *running tests* needs Logic Apps Standard
Operator, because getting the trigger address is an action.

Logic Apps Standard Operator also allows starting, stopping and updating the
Logic App, which the tool never does. Teams that want the exact minimum can
create this custom role instead and assign it on the same resources
(replace the subscription id; try it on one test resource first):

```json
{
  "Name": "Contica Test Tool Tester",
  "Description": "Send test messages and read the results with the Contica Test Tool. Nothing else.",
  "Actions": [
    "Microsoft.Web/sites/read",
    "Microsoft.Web/sites/workflows/read",
    "Microsoft.Web/sites/hostruntime/webhooks/api/workflows/triggers/read",
    "Microsoft.Web/sites/hostruntime/webhooks/api/workflows/triggers/listCallbackUrl/action",
    "Microsoft.Web/sites/hostruntime/webhooks/api/workflows/runs/read",
    "Microsoft.Web/sites/hostruntime/webhooks/api/workflows/runs/*/read",
    "Microsoft.ServiceBus/namespaces/read",
    "Microsoft.ServiceBus/namespaces/queues/read",
    "Microsoft.ServiceBus/namespaces/topics/read",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/blobServices/containers/read"
  ],
  "NotActions": [],
  "DataActions": [
    "Microsoft.ServiceBus/*/send/action",
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write"
  ],
  "NotDataActions": [],
  "AssignableScopes": ["/subscriptions/00000000-0000-0000-0000-000000000000"]
}
```

The tool reads each step's status and error from the run history; it never
reads the steps' inputs or outputs.

## Signing in

- **Azure:** the Microsoft account in VS Code (Accounts menu). The tool asks
  on the first Azure action of each session. A tenant can be set per
  environment.
- **GitHub:** only to connect and Sync a GitHub bundle repo. Testing makes no
  GitHub call.
- **AI:** GitHub Copilot in VS Code, for Analyse, Generate and the result
  summaries. Running tests needs no AI.

## Environments and test subscriptions

An environment is one bundle repo (or branch) the tester works in. Each can
list the **Test subscriptions** tests may be sent to (the sidebar row of
that name). With no list, any subscription is allowed and the row says so in
yellow. Only allowed subscriptions are offered when the tester picks where to
send.

## Before anything is sent

The tester picks the target with **Discover from Azure**: subscription, then
the way in (HTTP, Service Bus or Blob), then the Logic App that runs the
bundle's workflow. The tool then checks, and refuses to send when:

- the workflow is not one of the bundle's, or not the receiving one;
- the way in does not match the workflow's trigger (trigger name, queue,
  topic or container);
- the queue, topic or container comes from an app setting, or from a parameter the bundle cannot resolve (see above);
- the subscription is not allowed in this environment;
- the Logic App, workflow, namespace or account cannot be found in Azure.

The tester then confirms. Typing the Logic App's name is required when the
target is new on this computer, has changed since last confirmed, or anything
looks like production (`prod`, `prd`, `production` in a name, or a workflow
that calls a production-looking address).

## Run in Azure

- **HTTP:** the tool asks Azure for the trigger address at the start of every
  run and never stores it; each message is posted with a 30-second time-out.
- **Service Bus:** each message is sent with only its body and content type
  (no session id or custom properties).
- **Blob:** each message is uploaded as a new file.
- The tool then waits for the workflow run to appear and finish:
  **Run Wait Seconds**, 60 by default (10 to 600). It is in VS Code's
  Settings under Contica Test Tool (setting id
  `conticaTestTool.test.runWaitSeconds`). Raise it for slow workflows when
  results say no matching run appeared in time.
- A message the HTTP trigger refuses before the workflow starts (unreadable
  JSON, trigger schema validation) is shown as refused, with no run.

## Run locally (Preview)

Runs the workflow on the tester's computer with Microsoft's Logic Apps test
SDK. Nothing is sent to Azure.

- **Install:** the **.NET 10 SDK** (the SDK, not only the runtime). The tool
  checks and offers the download link. The first run downloads packages from
  nuget.org, so that must be reachable.
- **Supported:** one receiving workflow with exactly one trigger, HTTP or
  Service Bus.
- **Not supported:** Blob and schedule triggers, more than one trigger,
  AI agent steps, integration account lookups, X12, EDIFACT and AS2 steps.
  Use Run in Azure for those.
- **Faked as successful:** calls to other systems and code (connectors,
  Service Bus, HTTP calls, Azure Functions, child workflows, inline C# and
  PowerShell). Maps run for real when they are in the bundle; maps stored in
  an integration account do not run.
- **Not checked:** the trigger's own schema validation, the real app
  settings, and the deployed Logic App with its connections and network. Run
  in Azure as well before signing off.
- On Windows the folder the tool builds the runner in must be at most 120
  characters long. It is VS Code's storage for the extension, normally
  `%APPDATA%\Code\User\globalStorage\ahmedbayoumy.contica-test-tool-vscode\runner`,
  so it only goes over with a very long user profile path. The error message
  shows the folder.

## Results

- Every test that ran is **Needs review**: the tool never decides pass or
  fail. The tester marks each one **Looks right** or **Not right**.
- Each result shows the reply, the workflow run, and each step's status and
  error. An AI summary explains them in plain words.
- Azure and local runs of the same pack can be compared side by side.
- Results are saved in the bundle repo, in
  `{INT}/{entity}/test-results/{time}/test-run.json`, and shared with Sync.

## Common reasons a test cannot run

| What the tester sees | What to do |
|---|---|
| "No generated pack found" | Analyse, approve and Generate first. |
| "None of your Azure subscriptions is allowed for ..." | Add the subscription under Test subscriptions. |
| "No matching Logic App" | No Logic App in that subscription runs a workflow named like the bundle's folder. Check the folder name, or the subscription. |
| "Could not get the trigger address" | The tester lacks Logic Apps Standard Operator (Reader is not enough). |
| "... reads its Service Bus queue or topic from an app setting, or from a parameter ..." (2.0.0: "... from a setting ...") | Add the Logic App's `parameters.json` to the bundle's code when the name is `@parameters('...')` (versions after 2.0.0). Otherwise use Run locally, or ask the developers to write the name into the trigger. |
| ".NET 10 SDK" message | Install the .NET 10 SDK. |
| "The extension's storage folder is too long ..." | The Windows user profile path is very long; see Run locally above. |
| "Cannot approve ...: N blocking gap(s) must be resolved first." | Resolve the blocking gaps in the Analyse tab, see "The order of the work". |
| "no matching run appeared" | Raise Run Wait Seconds; check the workflow ran in the portal. |
