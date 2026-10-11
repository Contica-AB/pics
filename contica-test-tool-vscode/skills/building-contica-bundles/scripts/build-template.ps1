<#
Build script for one Contica Test Tool bundle (an INT#### folder).

HOW TO USE THIS TEMPLATE
  The building-contica-bundles skill copies this file to build-INT####.ps1
  next to the bundle and fills in the CONFIG section only. The functions
  below stay as they are.

WHAT IT DOES, EVERY RUN
  1. Brings each source up to date: git clone/pull into a local cache at
     %LOCALAPPDATA%\ConticaBundleSources\INT####\; synced folders are read
     in place.
  2. Copies the declared files into the bundle (never moves, never edits the
     originals). UTF-16 text files are rewritten as UTF-8 on the way in.
  3. Writes the integration manifest and one manifest per entity from the
     CONFIG section, as UTF-8 without a byte-order mark.
  4. Puts freshly fetched example messages in an inbox OUTSIDE the bundle
     (the cache's _inbox\ folder). A message enters the bundle only after
     the tester has checked it and listed it under $KeptFiles.
  5. Runs check-bundle.ps1 when it sits next to this script.

CHANGING THE BUNDLE
  Change the CONFIG section and run the script again; do not edit the
  manifests by hand. What the Contica Test Tool itself adds to a manifest
  (the Azure resource it tests against, an example added with Add Example,
  the format) is kept, as are entries for files that still exist in the
  bundle. A file taken out of the CONFIG is removed from the manifest, and
  the copy this script made earlier is deleted from the bundle (the list of
  copied files is kept in the integration manifest's sourceProvenance).

Re-run any time the sources change. Works in Windows PowerShell 5.1 and
PowerShell 7. Sign-in is always the person's own (Git Credential Manager,
az login); no secrets live in this file.
#>
[CmdletBinding()]
param(
    # Show what would change in the bundle without writing to it. Git
    # sources are still cloned or updated in the source cache, because the
    # comparison needs them.
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Recorded in the manifests as "fetchedBy".
$scriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path

# ============================== CONFIG ======================================
# Filled in by the skill.

# The integration: INT followed by four digits, in capitals.
$Integration = @{
    Id   = 'INT0000'
    Name = 'Integration name'
    # JiraEpic = 'ABC-123'   # only when known; never invented
}

# One entry per entity. Id is i### (inbound) or o### (outbound), optionally
# followed by a capital T. Direction comes from the first letter.
# Format: 'xml' or 'json' only when you are sure; the declared format wins
# over what the example messages contain. Leave it out otherwise.
$Entities = @(
    # @{ Id = 'i001'; Name = 'Incoming order'; SourceSystem = 'Webshop'; TargetSystem = $null }
    # @{ Id = 'o001'; Name = 'Order to warehouse'; SourceSystem = $null; TargetSystem = 'Warehouse' }
)

# Where the bundle's integration folder is. Usually next to this script.
$BundleRoot = Join-Path $here $Integration.Id

# Where git sources are cloned, and where fetched example messages wait for
# the tester (its _inbox folder). Outside the bundle repo on purpose; safe to
# delete, the next run clones again. Keep the path short: Windows PowerShell
# 5.1 cannot open files whose full path passes 260 characters.
$SourceCache = Join-Path $env:LOCALAPPDATA "ConticaBundleSources\$($Integration.Id)"

# One entry per source. Kind: 'git' (cloned into the local cache) or
# 'folder' (a local or OneDrive-synced folder read in place).
$Sources = @(
    # @{ Name = 'code'; Kind = 'git'; Url = 'https://dev.azure.com/{org}/{project}/_git/{repo}'; Branch = 'main' }
    # @{ Name = 'wiki'; Kind = 'git'; Url = 'https://dev.azure.com/{org}/{project}/_git/{Project}.wiki'; Branch = 'wikiMain' }
    # @{ Name = 'mappings'; Kind = 'folder'; Path = "$env:USERPROFILE\Company\Site - Documents\INT0000" }
)

# What to copy. From is the path inside the source; give it a list to join
# several text files into one (entity page first). To is the path inside the
# integration folder: 'INT0000.i001/...' belongs to that entity, anything
# else is shared by all entities. Category and Purpose go into the manifest.
$Files = @(
    # @{ Source = 'code'; From = 'LogicApp/my-wf/workflow.json'; To = 'INT0000.i001/code/my-wf/workflow.json'; Category = 'code'; Purpose = 'workflow-definition' }
    # The integration page once, shared: the tool adds it after each entity's own page.
    # @{ Source = 'wiki'; From = 'INT0000-Name.md'; To = 'documentation/INT0000 Name.md'; Category = 'documentation'; Purpose = 'main-documentation' }
    # @{ Source = 'wiki'; From = 'INT0000-Name/INT0000.i001-Entity.md'; To = 'INT0000.i001/documentation/main_documentation.md'; Category = 'documentation'; Purpose = 'main-documentation' }
    # Approved test messages that live in a folder source are copied like any file:
    # @{ Source = 'messages'; From = 'order-ok.xml'; To = 'INT0000.i001/examples/INT0000.i001 happy-path.xml'; Category = 'examples'; Purpose = 'happy-path' }
    # @{ Source = 'mappings'; From = 'INT0000.i001 mapping.xlsx'; To = 'INT0000.i001/mappings/INT0000.i001 mapping.xlsx'; Category = 'mappings'; Purpose = 'source-to-canonical' }
)

# Whole folders to copy (for example C# mapper folders). Every copied file
# gets the same Category and Purpose. Exclude is a list of wildcard patterns
# matched against the path inside the folder.
$Folders = @(
    # @{ Source = 'code'; From = 'Function/MyMapper'; To = 'INT0000.i001/code/MyMapper'; Include = '*.cs'; Exclude = @('Models\*', 'bin\*', 'obj\*'); Category = 'code'; Purpose = 'custom-code' }
)

# Files that are already in the bundle and that this script does not fetch:
# example messages the tester approved, scrubbed copies, hand-written notes.
# They go into the manifest; the script never creates or overwrites them.
$KeptFiles = @(
    # @{ Path = 'INT0000.i001/examples/INT0000.i001 happy-path.json'; Category = 'examples'; Purpose = 'happy-path'; Note = 'test run 08585..., approved by the tester' }
)

# Optional: example messages from Logic App run history (Standard), saved to
# the inbox for the tester to review. Needs az login and Logic Apps Standard
# Reader on the Logic App.
$RunHistory = @(
    # @{ Entity = 'i001'; Subscription = '...'; ResourceGroup = '...'; LogicApp = '...'; Workflow = '...'; Extension = '.json'; Count = 3 }
)
# ============================ END CONFIG ====================================

# ----- Rules from the Contica Test Tool's bundle loader ----------------------
$AllowedPurposes = [ordered]@{
    documentation = @('main-documentation', 'trigger-documentation', 'architecture-note', 'business-rules')
    examples      = @('happy-path', 'edge-case', 'reference', 'trigger-format', 'archived')
    schemas       = @('source', 'target', 'canonical', 'shared-types')
    mappings      = @('source-to-canonical', 'canonical-to-target', 'end-to-end', 'overview', 'archived')
    standards     = @('error-handling', 'retry-policy', 'logic-apps-conventions', 'azure-functions-conventions', 'integration-standards')
    code          = @('workflow-definition', 'connection-config', 'transformation', 'infrastructure', 'custom-code')
}
$integrationId = $Integration.Id

$sourceCache = $SourceCache
# Outside the bundle on purpose: the extension's Sync shares everything in
# the bundle repo, and raw captured messages must not be shared before the
# tester has checked them.
$inbox = Join-Path $sourceCache '_inbox'
$changes = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
# Every file the manifests will list: @{ To; Category; Purpose }.
$declared = New-Object System.Collections.Generic.List[object]

# ----- Check the CONFIG before touching anything -------------------------------
function Test-Config {
    if ($integrationId -cnotmatch '^INT\d{4}$') { throw "Integration Id '$integrationId' must be INT followed by four digits, in capitals (for example INT0542)." }
    if (@($Entities).Count -eq 0) { throw 'List at least one entity under $Entities.' }
    foreach ($entity in $Entities) {
        if ($entity.Id -cnotmatch '^[io]\d{3}T?$') { throw "Entity Id '$($entity.Id)' must look like i001, o001 or i001T (lowercase i or o)." }
        if ($entity.Format -and @('xml', 'json') -notcontains $entity.Format) { throw "Entity $($entity.Id): Format must be 'xml' or 'json', or left out." }
    }
    $entityIds = @($Entities | ForEach-Object { $_.Id })
    $all = @($Files) + @($Folders) + @($KeptFiles)
    foreach ($item in $all) {
        if (-not $AllowedPurposes.Contains([string]$item.Category)) {
            throw "Category '$($item.Category)' is not one of: $($AllowedPurposes.Keys -join ', ')."
        }
        if ($AllowedPurposes[[string]$item.Category] -notcontains $item.Purpose) {
            throw "Purpose '$($item.Purpose)' is not allowed for $($item.Category). Use one of: $($AllowedPurposes[[string]$item.Category] -join ', ')."
        }
        # Folders are copied file by file; a single file has To, a kept file Path.
        $target = if ($item.Path) { $item.Path } elseif (-not $item.Include) { $item.To } else { $null }
        if ($item.Category -eq 'mappings' -and $target -and $target -notmatch '\.xlsx$') {
            throw "$($target): the mappings list only reads .xlsx spreadsheets. Put mapping code (.cs, .xslt, .liquid) under Category 'code' with Purpose 'transformation'."
        }
        $place = if ($item.Path) { $item.Path } else { $item.To }
        if (-not $place) { throw "An entry in Files, Folders or KeptFiles has no To or Path." }
        # The script writes only inside the integration folder: a rooted path
        # or one that climbs out with '..' could overwrite a file elsewhere.
        $rootFull = [System.IO.Path]::GetFullPath($BundleRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $placeFull = [System.IO.Path]::GetFullPath((Join-Path $BundleRoot $place))
        if ([System.IO.Path]::IsPathRooted($place) -or -not $placeFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$($place): To and Path must be a path inside the integration folder ($BundleRoot), like 'INT0000.i001/code/my-wf/workflow.json'."
        }
        if ($place -match "^$integrationId\.([io]\d{3}T?)/" -and $entityIds -cnotcontains $Matches[1]) {
            throw "$($place) belongs to entity $($Matches[1]), which is not listed under `$Entities."
        }
    }
}

# ----- Sources ------------------------------------------------------------------
function Get-SourceRoot([string]$name) {
    $source = $Sources | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $source) { throw "No source named '$name' in the CONFIG section." }
    if ($source.Kind -eq 'git') { return (Join-Path $sourceCache $name) }
    return $source.Path
}

function Update-Sources {
    foreach ($source in $Sources) {
        if ($source.Kind -eq 'git') {
            $target = Join-Path $sourceCache $source.Name
            # core.longpaths: integration repos are deep, and Windows refuses
            # paths over 260 characters unless git is told to allow them.
            if (Test-Path (Join-Path $target '.git')) {
                Write-Host "Updating $($source.Name) ..."
                git -C $target -c core.longpaths=true fetch --quiet origin
                if ($LASTEXITCODE -eq 0) { git -C $target -c core.longpaths=true checkout --quiet $source.Branch }
                if ($LASTEXITCODE -eq 0) { git -C $target -c core.longpaths=true pull --quiet --ff-only }
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not update '$($source.Name)'. If you changed files in $target, delete that folder and run again; it is only a cache."
                }
            } else {
                Write-Host "Cloning $($source.Name) (a browser sign-in may open) ..."
                New-Item -ItemType Directory -Force -Path $sourceCache | Out-Null
                git -c core.longpaths=true clone --quiet --config core.longpaths=true --branch $source.Branch $source.Url $target
                if ($LASTEXITCODE -ne 0) {
                    # A half-finished clone would confuse the next run.
                    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
                    throw "Could not clone '$($source.Name)' from $($source.Url). Check the URL, the branch '$($source.Branch)', and that you have Read access to the repository."
                }
            }
        } elseif (-not (Test-Path $source.Path)) {
            throw "Folder for source '$($source.Name)' not found: $($source.Path). If it is a SharePoint folder, check that OneDrive has synced it."
        }
    }
}

# ----- Copying files ------------------------------------------------------------
# Reads a text file honouring a byte-order mark, so UTF-16 schemas exported
# from older tools come out as readable text.
function Read-TextWithBom([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    return $null  # not UTF-16; copy the bytes as they are
}

function Copy-IntoBundle([string]$from, [string]$to) {
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Source file missing: $from" }
    $text = Read-TextWithBom $from
    if ($null -ne $text) {
        # UTF-16 in, UTF-8 out. An XML declaration that still says utf-16
        # would contradict the new bytes, so it is corrected too, however it
        # is written (UTF-16, utf-16le, single or double quotes).
        $text = [regex]::Replace($text, '(<\?xml[^>]*?encoding\s*=\s*)(["''])utf-16(?:le|be)?\2', '${1}${2}utf-8${2}', 'IgnoreCase')
    }
    Write-IntoBundle $from $text $to
}

# Joins several text files (for example the entity's wiki page and the
# integration page) into one bundle file, entity page first.
function Join-IntoBundle([string[]]$froms, [string]$to) {
    $parts = foreach ($from in $froms) {
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Source file missing: $from" }
        $text = Read-TextWithBom $from
        if ($null -eq $text) { $text = [System.IO.File]::ReadAllText($from, [System.Text.Encoding]::UTF8) }
        $text.Trim()
    }
    Write-IntoBundle $null (($parts -join "`n`n") + "`n") $to
}

# Writes $text (or copies $from as bytes when $text is $null) to the bundle,
# skipping files that have not changed.
# $text is deliberately untyped: a [string] parameter would turn $null into
# an empty string, and every binary file would be written out empty.
function Write-IntoBundle([string]$from, $text, [string]$to) {
    $dest = Join-Path $BundleRoot $to
    $isSame = $false
    if (Test-Path -LiteralPath $dest) {
        if ($null -eq $text) {
            $isSame = (Get-FileHash -LiteralPath $from).Hash -eq (Get-FileHash -LiteralPath $dest).Hash
        } else {
            $isSame = [System.IO.File]::ReadAllText($dest) -eq $text
        }
    }
    if ($isSame) { return }
    $changes.Add($to)
    if ($WhatIf) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if ($null -ne $text) {
        [System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Copy-Item -LiteralPath $from -Destination $dest -Force
    }
}

function Copy-Files {
    foreach ($file in $Files) {
        $root = Get-SourceRoot $file.Source
        $froms = @($file.From)
        if ($froms.Count -gt 1) {
            Join-IntoBundle ($froms | ForEach-Object { Join-Path $root $_ }) $file.To
        } else {
            Copy-IntoBundle (Join-Path $root $froms[0]) $file.To
        }
        $declared.Add(@{ To = $file.To; Category = $file.Category; Purpose = $file.Purpose })
    }
}

function Copy-Folders {
    foreach ($folder in $Folders) {
        $root = Join-Path (Get-SourceRoot $folder.Source) $folder.From
        if (-not (Test-Path $root)) { throw "Source folder missing: $root" }
        $include = if ($folder.Include) { $folder.Include } else { '*' }
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter $include | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $excluded = $false
            foreach ($pattern in $folder.Exclude) { if ($relative -like $pattern) { $excluded = $true } }
            if (-not $excluded) {
                $to = $folder.To + '/' + $relative.Replace([char]92, [char]47)
                Copy-IntoBundle $_.FullName $to
                $declared.Add(@{ To = $to; Category = $folder.Category; Purpose = $folder.Purpose })
            }
        }
    }
}

function Add-KeptFiles {
    foreach ($kept in $KeptFiles) {
        $full = Join-Path $BundleRoot $kept.Path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $notes.Add("$($kept.Path) is listed under KeptFiles but is not in the bundle, so it is left out of the manifest.")
            continue
        }
        $declared.Add(@{ To = $kept.Path; Category = $kept.Category; Purpose = $kept.Purpose; Kept = $true })
    }
}

# ----- Example messages from run history -----------------------------------
# Saves the trigger body of the newest successful runs to the inbox.
function Get-RunHistoryExamples {
    if (@($RunHistory).Count -eq 0) { return }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Warning 'Azure CLI (az) is not installed, so run history was skipped.'
        return
    }
    foreach ($entry in $RunHistory) {
        $base = "https://management.azure.com/subscriptions/$($entry.Subscription)/resourceGroups/$($entry.ResourceGroup)" +
                "/providers/Microsoft.Web/sites/$($entry.LogicApp)/hostruntime/runtime/webhooks/workflow/api/management" +
                "/workflows/$($entry.Workflow)"
        $json = az rest --method get --url "$base/runs?api-version=2018-11-01&`$top=50" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not read run history for $($entry.Workflow). Run 'az login' and check you have Logic Apps Standard Reader on $($entry.LogicApp). Details: $json"
            continue
        }
        $runs = ($json | Out-String | ConvertFrom-Json).value |
            Where-Object { $_.properties.status -eq 'Succeeded' -and $_.properties.trigger.outputsLink } |
            Select-Object -First $entry.Count
        $outDir = Join-Path $inbox "examples\$($entry.Entity)"
        if (-not $WhatIf) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
        foreach ($run in $runs) {
            # outputsLink is pre-signed: no Authorization header.
            $outputs = Invoke-RestMethod -Uri $run.properties.trigger.outputsLink.uri
            $body = $outputs.body
            if ($body -is [string]) { $text = $body } else { $text = $body | ConvertTo-Json -Depth 50 }
            $name = "$integrationId.$($entry.Entity) run $($run.name)$($entry.Extension)"
            $changes.Add("(inbox) examples/$($entry.Entity)/$name")
            if (-not $WhatIf) {
                [System.IO.File]::WriteAllText((Join-Path $outDir $name), $text, (New-Object System.Text.UTF8Encoding($false)))
            }
        }
    }
}

# ----- Writing manifests --------------------------------------------------------
# A small JSON writer, so the manifests look the same from Windows PowerShell
# 5.1 and PowerShell 7 (their ConvertTo-Json output differs), and a re-run
# that changes nothing leaves the file byte for byte the same.
function ConvertTo-JsonText($value, [string]$indent = '') {
    $inner = $indent + '  '
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) { return [string]$value }
    if ($value -is [string]) {
        $escaped = $value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return '"' + $escaped + '"'
    }
    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Count -eq 0) { return '{}' }
        $parts = foreach ($key in $value.Keys) { $inner + '"' + $key + '": ' + (ConvertTo-JsonText $value[$key] $inner) }
        return "{`n" + ($parts -join ",`n") + "`n$indent}"
    }
    if ($value -is [System.Collections.IEnumerable]) {
        $items = @($value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $inner + (ConvertTo-JsonText $item $inner) }
        return "[`n" + ($parts -join ",`n") + "`n$indent]"
    }
    return '"' + [string]$value + '"'
}

# Turns what ConvertFrom-Json returns into ordered dictionaries and arrays,
# so an existing manifest can be merged and written back.
function ConvertTo-Plain($value) {
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($prop in $value.PSObject.Properties) { $result[$prop.Name] = ConvertTo-Plain $prop.Value }
        return $result
    }
    if ($value -is [System.Array]) { return , @($value | ForEach-Object { ConvertTo-Plain $_ }) }
    # PowerShell 7 reads date-like text ("2026-10-11T09:30:00Z") as a date.
    # Turn it back into the text it was, or every run would look changed.
    if ($value -is [DateTime]) {
        $utc = $value.ToUniversalTime()
        if ($utc.Millisecond -eq 0) { return $utc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        return $utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    return $value
}

function Read-ExistingManifest([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{} }
    $text = [System.IO.File]::ReadAllText($path).TrimStart([char]0xFEFF)
    try { return ConvertTo-Plain ($text | ConvertFrom-Json) }
    catch { throw "$path is not valid JSON, so it cannot be updated safely. Fix or delete it, then run again." }
}

# Builds one file list (documentation, examples, ...) for a manifest: the
# CONFIG's entries first, then entries the manifest already had for files that
# still exist (for example an example added with the tool's Add Example).
function Get-FileSection($fromConfig, $existingSection, [string]$manifestDir, [string]$relPrefix) {
    $section = [ordered]@{}
    foreach ($category in $AllowedPurposes.Keys) {
        $list = New-Object System.Collections.Generic.List[object]
        $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in ($fromConfig | Where-Object { $_.Category -eq $category })) {
            if ($paths.Add($item.Path)) { $list.Add([ordered]@{ path = $item.Path; purpose = $item.Purpose }) }
        }
        if ($existingSection -and $existingSection.Contains($category)) {
            foreach ($old in @($existingSection[$category])) {
                if (-not $old -or -not $old.path -or $paths.Contains($old.path)) { continue }
                # Copied by an earlier run of this script but no longer in CONFIG.
                if ($staleManaged.Contains($relPrefix + $old.path)) { continue }
                if (Test-Path -LiteralPath (Join-Path $manifestDir $old.path) -PathType Leaf) {
                    [void]$paths.Add($old.path)
                    $list.Add($old)
                    $notes.Add("Kept $($old.path) in $(Split-Path -Leaf $manifestDir)'s manifest: it was added outside this script. List it under KeptFiles to make that permanent.")
                }
            }
        }
        if ($list.Count -gt 0) { $section[$category] = $list.ToArray() }
    }
    return $section
}

# Writes the manifest only when something besides fetchedAt changed, so a
# re-run with nothing new does not give Sync anything to share.
function Save-Manifest([string]$path, $manifest, $existing) {
    $manifest['fetchedAt'] = if ($existing.Contains('fetchedAt')) { $existing['fetchedAt'] } else { '' }
    $before = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path).TrimStart([char]0xFEFF) } else { '' }
    if ((ConvertTo-JsonText $manifest) + "`n" -eq $before) { return }
    $manifest['fetchedAt'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $rel = $path.Substring($BundleRoot.Length).TrimStart('\', '/')
    $changes.Add($rel.Replace('\', '/'))
    if ($WhatIf) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, (ConvertTo-JsonText $manifest) + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

# Top-level fields this script owns. Everything else in an existing manifest
# (for example "resource", which the tool writes when it finds the Azure
# workflow to test) is carried over untouched.
$IntegrationFields = @('manifestVersion', 'scope', 'integrationId', 'integrationName', 'jiraEpic', 'fetchedAt', 'fetchedBy', 'sourceProvenance', 'sharedFiles', 'entities')
$EntityFields = @('manifestVersion', 'scope', 'integrationId', 'entityId', 'entityName', 'direction', 'sourceSystem', 'targetSystem', 'format', 'jiraKey', 'inheritsFrom', 'entityFiles')

# What this run copied (paths inside the integration folder), and what an
# earlier run copied that this one did not.
$staleManaged = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

function Remove-StaleFiles([string[]]$previous, [string[]]$current) {
    foreach ($old in $previous) {
        if (-not $old -or $current -contains $old) { continue }
        [void]$staleManaged.Add($old)
        $full = Join-Path $BundleRoot $old
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $changes.Add("(removed, no longer in CONFIG) $old")
            if (-not $WhatIf) { Remove-Item -LiteralPath $full -Force }
        }
    }
}

function Write-Manifests {
    $intPath = Join-Path $BundleRoot 'manifest.json'
    $existing = Read-ExistingManifest $intPath
    $previous = @()
    if ($existing.Contains('sourceProvenance') -and $existing['sourceProvenance'] -is [System.Collections.IDictionary] -and $existing['sourceProvenance'].Contains('managedFiles')) {
        $previous = @($existing['sourceProvenance']['managedFiles'] | ForEach-Object { [string]$_ })
    }
    $managed = @($declared | Where-Object { -not $_.Kept } | ForEach-Object { $_.To } | Sort-Object -Unique)
    $keptPaths = @($declared | Where-Object { $_.Kept } | ForEach-Object { $_.To })
    Remove-StaleFiles $previous (@($managed) + $keptPaths)

    # Integration manifest: every declared file outside an entity folder.
    $sharedItems = foreach ($d in $declared) {
        if ($d.To -notmatch "^$integrationId\.[io]\d{3}T?/") { @{ Path = $d.To; Category = $d.Category; Purpose = $d.Purpose } }
    }
    $manifest = [ordered]@{
        manifestVersion  = 1
        scope            = 'integration'
        integrationId    = $integrationId
        integrationName  = $Integration.Name
    }
    if ($Integration.JiraEpic) { $manifest['jiraEpic'] = $Integration.JiraEpic }
    elseif ($existing.Contains('jiraEpic')) { $manifest['jiraEpic'] = $existing['jiraEpic'] }
    $manifest['fetchedAt'] = ''
    $manifest['fetchedBy'] = $scriptName
    $manifest['sourceProvenance'] = [ordered]@{ kind = 'scripted'; rootPath = ''; managedFiles = $managed }
    $existingShared = if ($existing.Contains('sharedFiles')) { $existing['sharedFiles'] } else { $null }
    $manifest['sharedFiles'] = Get-FileSection @($sharedItems) $existingShared $BundleRoot ''
    $manifest['entities'] = @($Entities | ForEach-Object { $_.Id })
    foreach ($key in $existing.Keys) { if ($IntegrationFields -notcontains $key) { $manifest[$key] = $existing[$key] } }
    Save-Manifest $intPath $manifest $existing

    foreach ($entity in $Entities) {
        $folder = "$integrationId.$($entity.Id)"
        $prefix = "$folder/"
        $items = foreach ($d in $declared) {
            if ($d.To.StartsWith($prefix)) { @{ Path = $d.To.Substring($prefix.Length); Category = $d.Category; Purpose = $d.Purpose } }
        }
        $entityDir = Join-Path $BundleRoot $folder
        $path = Join-Path $entityDir 'manifest.json'
        $existing = Read-ExistingManifest $path
        $direction = if ($entity.Id.StartsWith('i')) { 'inbound' } else { 'outbound' }
        $manifest = [ordered]@{
            manifestVersion = 1
            scope           = 'entity'
            integrationId   = $integrationId
            entityId        = $entity.Id
            entityName      = $entity.Name
            direction       = $direction
            sourceSystem    = $entity.SourceSystem
            targetSystem    = $entity.TargetSystem
        }
        # The tool's Add Example sets the format; keep it unless CONFIG says otherwise.
        if ($entity.Format) { $manifest['format'] = $entity.Format }
        elseif ($existing.Contains('format')) { $manifest['format'] = $existing['format'] }
        if ($entity.JiraKey) { $manifest['jiraKey'] = $entity.JiraKey }
        elseif ($existing.Contains('jiraKey')) { $manifest['jiraKey'] = $existing['jiraKey'] }
        $manifest['fetchedAt'] = ''
        $manifest['fetchedBy'] = $scriptName
        $manifest['inheritsFrom'] = '../manifest.json'
        $existingFiles = if ($existing.Contains('entityFiles')) { $existing['entityFiles'] } else { $null }
        $manifest['entityFiles'] = Get-FileSection @($items) $existingFiles $entityDir $prefix
        foreach ($key in $existing.Keys) { if ($EntityFields -notcontains $key) { $manifest[$key] = $existing[$key] } }
        Save-Manifest $path $manifest $existing
    }
}

# ----- Run ----------------------------------------------------------------------
Test-Config
Update-Sources
Copy-Files
Copy-Folders
Add-KeptFiles
Get-RunHistoryExamples
Write-Manifests

if ($changes.Count -eq 0) {
    Write-Host 'Nothing changed: the bundle already matches the sources.'
} else {
    $verb = if ($WhatIf) { 'Would update' } else { 'Updated' }
    Write-Host "$verb $($changes.Count) file(s):"
    $changes | ForEach-Object { Write-Host "  $_" }
}
foreach ($note in $notes) { Write-Host "Note: $note" }
if (Test-Path (Join-Path $inbox 'examples')) {
    Write-Host ''
    Write-Host "Example messages are waiting in $inbox\examples\. Check them for real personal data, pick the happy path, copy it into the entity's examples\ folder, list it under KeptFiles, and run this script again."
}

# The checker's result is this script's result: 1 means something is
# BLOCKING. An entity deliberately left without an example stays BLOCKING
# until its message is added; the files were still built.
$checker = Join-Path $here 'check-bundle.ps1'
if (-not $WhatIf -and (Test-Path $checker)) {
    Write-Host ''
    & $checker -BundleRoot $BundleRoot
    exit $LASTEXITCODE
}
