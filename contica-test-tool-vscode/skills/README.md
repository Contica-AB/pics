# Bundle builder skill for Claude Code

A [Claude Code](https://claude.com/claude-code) skill that gets an
integration's bundle ready for the
[Contica Test Tool](https://marketplace.visualstudio.com/items?itemName=ahmedbayoumy.contica-test-tool-vscode)
VS Code extension.

You tell Claude where your material lives: the code repo, the wiki or
Confluence page, the mapping spreadsheets, where test messages can be
found. Claude then writes one script, `build-INT####.ps1`, that fetches
everything, copies it into the right folders and writes all the
`manifest.json` files. When your sources change, run the script again.

Along the way it tells you which access you need for each source, asks you
which example message is the normal one, and checks the finished bundle the
same way the Contica Test Tool reads it.

## What is in the folder

| File | What it is |
|---|---|
| `building-contica-bundles/SKILL.md` | The steps Claude follows |
| `building-contica-bundles/reference.md` | How the Contica Test Tool (2.0.0) reads a bundle |
| `building-contica-bundles/sources.md` | Where material usually lives, and the access each source needs |
| `building-contica-bundles/scripts/build-template.ps1` | The build script Claude fills in for you |
| `building-contica-bundles/scripts/check-bundle.ps1` | A checker you can also run on its own |

## Install

You need Claude Code and Windows PowerShell 5.1 or PowerShell 7. In
PowerShell:

```powershell
$zip = "$env:TEMP\contica-pics.zip"
Invoke-WebRequest https://github.com/Contica-AB/pics/archive/refs/heads/main.zip -OutFile $zip
Expand-Archive $zip "$env:TEMP\contica-pics" -Force
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
Copy-Item -Recurse -Force "$env:TEMP\contica-pics\pics-main\contica-test-tool-vscode\skills\building-contica-bundles" "$env:USERPROFILE\.claude\skills\"
```

Run the same lines again to update to the newest version.

## Use

Open Claude Code in your local copy of the team's bundle repo and ask, for
example:

> Help me get the bundle ready for INT0542 Order intake.

When the script has run, open the Contica Test Tool and press **Sync** in
its sidebar to share the bundle with your team.

## Check a bundle without Claude

The checker works on any bundle, however it was made. It only reads files.

```powershell
powershell -ExecutionPolicy Bypass -File check-bundle.ps1 -BundleRoot .\INT0542
```

It sorts what it finds into three levels: **BLOCKING** (the tool cannot
analyse the entity), **FIX** (something is ignored or wrong) and
**IMPROVE** (it works, but the test plan would be richer). It also prints
the readiness the tool's sidebar will show.

## Good to know

- Use test data only. Never put production messages or real personal data
  in a bundle.
- No passwords or keys go into the script; it signs in as you (Git
  Credential Manager, `az login`).
- The script only reads your sources. It copies files and never changes or
  moves the originals.
