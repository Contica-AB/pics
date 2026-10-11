<#
Checks one Contica Test Tool bundle (an INT#### folder) the way the
extension (version 2.0.0) reads it, and explains every problem in plain
words.

  powershell -ExecutionPolicy Bypass -File check-bundle.ps1 -BundleRoot .\INT0542

Results come in three levels:
  BLOCKING  Analyse or Generate will stop, or the entity will not load.
  FIX       It loads, but something is silently ignored or wrong.
  IMPROVE   It works; this would make the test plan richer.

Exit code 1 when anything is BLOCKING. Read-only: it never changes a file.
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleRoot
)
$ErrorActionPreference = 'Stop'

# ----- Rules taken from the extension's loader ------------------------------
# Kept here, not looked up, so the check runs without the extension installed.
$AllowedPurposes = @{
    examples      = @('happy-path', 'edge-case', 'archived', 'reference', 'trigger-format')
    schemas       = @('source', 'target', 'canonical', 'shared-types')
    mappings      = @('source-to-canonical', 'canonical-to-target', 'end-to-end', 'overview', 'archived')
    documentation = @('main-documentation', 'trigger-documentation', 'architecture-note', 'business-rules')
    standards     = @('error-handling', 'retry-policy', 'logic-apps-conventions', 'azure-functions-conventions', 'integration-standards')
    code          = @('workflow-definition', 'connection-config', 'transformation', 'infrastructure', 'custom-code')
}
$SchemaExtensions = @('.xsd', '.json', '.jschema')
$CodeExtensions = @('.md', '.json', '.cs', '.xsd', '.xml', '.txt', '.jschema', '.yaml', '.yml', '.liquid', '.xslt', '.sql', '.py', '.scala', '.js', '.ts', '.mjs', '.cjs')
$BinaryExtensions = @('.doc', '.docx', '.pdf', '.xls', '.xlsx', '.xlsm', '.drawio', '.png', '.jpg', '.vsdx', '.zip')
# This file stays plain ASCII so Windows PowerShell 5.1 reads it correctly;
# Swedish letters are written as character codes.
$ae = [char]0xE4; $aa = [char]0xE5
# Sheet names the mapping parser skips: these anywhere in the name...
$SkippedSheetFragments = @('archiv', 'deprecat', 'obsolete', 'legacy', 'history', 'version control', 'change record')
# ...'old' at the start or end of a word ("Old mapping", "Mapping_old", also
# "Threshold"), and 'prior' at the start of a word unless it is "priorit...".
# "Golden" and "Holder" are read.
# Column header words. 'to' must be a whole word; the others may sit inside
# a longer header ("Datasource").
$SourceHeaderWords = @('source', 'src', 'from', "k$($ae)llf$($ae)lt", 'kallfalt', 'property (sending', 'sending system property')
$TargetHeaderWords = @('target', 'tgt', 'destination', "m$($aa)lf$($ae)lt", 'malfalt', 'property (receiving', 'receiving system property')
# Email domains the personal-data check accepts as test data.
$TestEmailDomain = '(^|\.)(example\.(com|org|net)|example|test|invalid|localhost)$'

# ----- Result collection ----------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$level, [string]$where, [string]$what, [string]$todo) {
    $results.Add([pscustomobject]@{ Level = $level; Where = $where; What = $what; Todo = $todo })
}

# ----- Helpers ---------------------------------------------------------------
function Get-Bom([string]$path) {
    $stream = [System.IO.File]::OpenRead($path)
    try {
        $head = New-Object byte[] 3
        $count = $stream.Read($head, 0, 3)
    } finally { $stream.Dispose() }
    if ($count -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { return 'utf-8-bom' }
    if ($count -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) { return 'utf-16-be' }
    if ($count -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) { return 'utf-16-le' }
    return 'none'
}

# Reads text the way the extension does: honour a byte-order mark, else UTF-8.
function Read-Text([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    switch (Get-Bom $path) {
        'utf-16-be' { return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
        'utf-16-le' { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
        'utf-8-bom' { return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
        default { return [System.Text.Encoding]::UTF8.GetString($bytes) }
    }
}

function Test-Inside([string]$root, [string]$candidate) {
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($candidate)
    return $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

# Guesses a message's wire format from its first character, as the loader does.
function Get-SniffedFormat([string]$text) {
    $trimmed = $text.TrimStart()
    if ($trimmed.StartsWith('<')) { return 'xml' }
    if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) { return 'json' }
    return 'flat'
}

# Counts the distinct field paths in an example the way the tool does: only
# the innermost fields (leaves) and attributes, the first 5 items of a JSON
# list. The analysis reports THIN_COVERAGE below 10 across all examples.
function Get-ExamplePaths([string]$text, [string]$format) {
    $paths = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($format -eq 'xml') {
        try { $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($text) } catch { return $paths }
        $stack = New-Object System.Collections.Stack
        $stack.Push(@($doc.DocumentElement, ('/' + $doc.DocumentElement.LocalName)))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop(); $node = $item[0]; $path = $item[1]
            $childElements = @($node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            $attributes = @($node.Attributes | Where-Object { $_.Prefix -ne 'xmlns' })
            # An element with only attributes counts through its attributes.
            if ($childElements.Count -eq 0 -and ($attributes.Count -eq 0 -or $node.InnerText.Trim())) { [void]$paths.Add($path) }
            foreach ($attr in $attributes) { [void]$paths.Add("$path/@$($attr.LocalName)") }
            foreach ($child in $childElements) { $stack.Push(@($child, "$path/$($child.LocalName)")) }
        }
    } elseif ($format -eq 'json') {
        try { $value = $text | ConvertFrom-Json } catch { return $paths }
        $stack = New-Object System.Collections.Stack
        $stack.Push(@($value, '$'))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop(); $node = $item[0]; $path = $item[1]
            if ($node -is [System.Management.Automation.PSCustomObject]) {
                $props = @($node.PSObject.Properties)
                if ($props.Count -eq 0) { [void]$paths.Add($path) }
                foreach ($prop in $props) { $stack.Push(@($prop.Value, "$path.$($prop.Name)")) }
            } elseif ($node -is [System.Array]) {
                if ($node.Count -eq 0) { [void]$paths.Add($path) }
                $i = 0
                foreach ($entry in ($node | Select-Object -First 5)) { $stack.Push(@($entry, "$path[$i]")); $i++ }
            } else {
                [void]$paths.Add($path)
            }
        }
    }
    return $paths
}

function Test-Luhn([string]$digits) {
    $sum = 0; $double = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $d = [int][string]$digits[$i]
        if ($double) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d; $double = -not $double
    }
    return ($sum % 10) -eq 0
}

# A short, honest version of the extension's personal-data check: emails
# outside test domains, Swedish personal identity numbers, card numbers,
# IBANs. The extension checks more (names, phones by field name), so a clean
# result here is necessary, not sufficient.
function Find-PersonalData([string]$text) {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, '[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})')) {
        if ($m.Groups[1].Value -notmatch $TestEmailDomain) { $found.Add("email address $($m.Value)") }
    }
    foreach ($m in [regex]::Matches($text, '(?<!\d)(\d{2})?(\d{2})(\d{2})(\d{2})[-+]?(\d{4})(?!\d)')) {
        $mm = [int]$m.Groups[3].Value; $dd = [int]$m.Groups[4].Value
        if ($dd -gt 60) { $dd -= 60 }  # samordningsnummer
        if ($m.Value -notmatch '[-+]' -and -not $m.Groups[1].Success) { continue }  # a bare 10-digit run is not matched
        if ($mm -ge 1 -and $mm -le 12 -and $dd -ge 1 -and $dd -le 31) {
            $ten = $m.Groups[2].Value + $m.Groups[3].Value + $m.Groups[4].Value + $m.Groups[5].Value
            if (Test-Luhn $ten) { $found.Add("Swedish personal identity number $($m.Value)") }
        }
    }
    foreach ($m in [regex]::Matches($text, '(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)')) {
        $digits = $m.Value -replace '[ -]', ''
        if ($digits -match '^(4|5[1-5]|2[2-7]|3[47]|6)' -and (Test-Luhn $digits)) { $found.Add("card number $($m.Value)") }
    }
    foreach ($m in [regex]::Matches($text, '\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b')) {
        $iban = $m.Value
        $moved = $iban.Substring(4) + $iban.Substring(0, 4)
        $numeric = -join ($moved.ToCharArray() | ForEach-Object { if ([char]::IsLetter($_)) { [int][char]$_ - 55 } else { $_ } })
        $remainder = 0
        foreach ($ch in $numeric.ToCharArray()) { $remainder = ($remainder * 10 + [int][string]$ch) % 97 }
        if ($remainder -eq 1) { $found.Add("IBAN $iban") }
    }
    return $found
}

# Reads sheet names and the words used in an .xlsx without Excel: an .xlsx
# is a zip of XML files.
function Get-XlsxInfo([string]$path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
    try {
        $sheets = @()
        $cells = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $zip.Entries) {
            # Cell text sits in sharedStrings.xml, or, for files written by
            # some tools, in the sheet itself: <is><t>...</t></is> for inline
            # strings, <v>...</v> for formula-string cells (t="str").
            $isSheet = $entry.FullName -like 'xl/worksheets/*.xml'
            if ($entry.FullName -eq 'xl/workbook.xml' -or $entry.FullName -eq 'xl/sharedStrings.xml' -or $isSheet) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($entry.FullName -eq 'xl/workbook.xml') {
                    $sheets = [regex]::Matches($xml, '<sheet [^>]*name="([^"]+)"') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }
                } else {
                    foreach ($match in [regex]::Matches($xml, '<([tv])(?:\s[^>]*)?>([^<]*)</\1>')) {
                        $cells.Add([System.Net.WebUtility]::HtmlDecode($match.Groups[2].Value).ToLowerInvariant())
                    }
                }
            }
        }
        return [pscustomobject]@{ Sheets = @($sheets); Cells = $cells }
    } finally { $zip.Dispose() }
}

# Mirrors the parser's sheet-name rules (see the word lists at the top).
function Test-SkipSheet([string]$name) {
    $lower = $name.ToLowerInvariant()
    foreach ($fragment in $SkippedSheetFragments) { if ($lower.Contains($fragment)) { return $true } }
    if ($lower -match '(^|[^\p{L}])old|old([^\p{L}]|$)') { return $true }
    if ($lower -match '(^|[^\p{L}])prior' -and $lower -notmatch '(^|[^\p{L}])priorit') { return $true }
    return $false
}

# True when some cell looks like a source (or target) column header.
function Test-HeaderWord($cells, $words, [bool]$allowTo) {
    foreach ($cell in $cells) {
        foreach ($word in $words) { if ($cell.Contains($word)) { return $true } }
        if ($allowTo -and $cell -match '(^|[^\p{L}])to([^\p{L}]|$)') { return $true }
    }
    return $false
}

# The tool reads manifests with or without a byte-order mark, in UTF-8 or
# UTF-16, so only the JSON itself is checked.
function Read-Manifest([string]$path, [string]$where) {
    try { return (Read-Text $path) | ConvertFrom-Json }
    catch {
        Add-Result 'BLOCKING' $where "manifest.json is not valid JSON: $($_.Exception.Message)" 'Fix the JSON (a missing comma or quote is the usual cause).'
        return $null
    }
}

# ----- Integration level -----------------------------------------------------
if (-not (Test-Path $BundleRoot -PathType Container)) { throw "Bundle folder not found: $BundleRoot" }
$BundleRoot = (Resolve-Path $BundleRoot).Path
$intName = Split-Path -Leaf $BundleRoot
if ($intName -cnotmatch '^INT\d{4}$') {
    Add-Result 'BLOCKING' $intName 'The integration folder must be named INT followed by four digits, in capitals (e.g. INT0542).' "Rename the folder to $($intName.ToUpperInvariant())."
}

$integrationManifest = $null
$intManifestPath = Join-Path $BundleRoot 'manifest.json'
if (Test-Path $intManifestPath) {
    $integrationManifest = Read-Manifest $intManifestPath $intName
} else {
    Add-Result 'FIX' $intName 'There is no integration manifest.json, so shared schemas, mappings, standards and connections are not loaded.' 'Create INT####/manifest.json with scope "integration" (see reference.md).'
}

if ($integrationManifest) {
    # Shared documentation is read only when it is the main documentation
    # and a .md or .txt file; it is then added after each entity's own text.
    foreach ($doc in @($integrationManifest.sharedFiles.documentation)) {
        if (-not $doc) { continue }
        $docExt = [System.IO.Path]::GetExtension([string]$doc.path).ToLowerInvariant()
        if ($doc.purpose -ne 'main-documentation') {
            Add-Result 'FIX' $intName "Shared documentation $($doc.path) has purpose '$($doc.purpose)'. Only the shared main-documentation file is read." 'Set its purpose to main-documentation, or move the text into the entities.'
        } elseif (@('.md', '.txt') -notcontains $docExt) {
            Add-Result 'FIX' $intName "Shared documentation $($doc.path) is a $docExt file. Shared documentation is read only from .md or .txt." 'Convert it to Markdown (.md).'
        }
    }
}

# ----- Entities --------------------------------------------------------------
$entityDirs = @(Get-ChildItem -LiteralPath $BundleRoot -Directory | Where-Object { $_.Name -match '^INT\d{4}\.[io]\d{3}T?$' })
if ($entityDirs.Count -eq 0) {
    Add-Result 'BLOCKING' $intName 'No entity folders found. The sidebar hides an integration without entities.' 'Create one folder per entity, named like INT0542.i001 or INT0542.o001.'
}

$readinessByEntity = [ordered]@{}

# Lists every file entry of a manifest section as (category, entry, base folder).
function Get-Entries($section, [string]$baseDir) {
    $list = @()
    if (-not $section) { return $list }
    foreach ($prop in $section.PSObject.Properties) {
        foreach ($entry in @($prop.Value)) {
            if ($entry) { $list += [pscustomobject]@{ Category = $prop.Name; Entry = $entry; Base = $baseDir } }
        }
    }
    return $list
}

foreach ($dir in $entityDirs) {
    $where = $dir.Name
    if ($dir.Name -cnotmatch '^INT\d{4}\.[io]\d{3}T?$') {
        $fixed = $dir.Name.Substring(0, 8).ToUpperInvariant() + $dir.Name.Substring(8, 4).ToLowerInvariant() + $dir.Name.Substring(12).ToUpperInvariant()
        Add-Result 'BLOCKING' $where 'The entity folder name has the wrong letter case. On a Mac or Linux machine the extension cannot load it.' "Rename it to $fixed."
    }
    if ($dir.Name.Substring(0, 7).ToUpperInvariant() -ne $intName.ToUpperInvariant()) {
        Add-Result 'FIX' $where "This entity's number does not match the integration folder $intName." 'Check the entity was filed under the right integration.'
    }

    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        Add-Result 'BLOCKING' $where 'There is no manifest.json, so the entity cannot be analysed.' 'Create one with scope "entity" (see reference.md).'
        continue
    }
    $m = Read-Manifest $manifestPath $where
    if (-not $m) { continue }
    if ($m.scope -ne 'entity') { Add-Result 'BLOCKING' $where "scope is '$($m.scope)', but an entity manifest must say 'entity'." 'Set "scope": "entity".' }
    if (-not $m.entityFiles) {
        Add-Result 'BLOCKING' $where 'The manifest has no entityFiles section; loading fails.' 'Add "entityFiles" with documentation, examples, schemas, mappings and code lists.'
        continue
    }
    $suffix = $dir.Name.Substring(8)
    $expectedDirection = if ($suffix.ToLowerInvariant().StartsWith('i')) { 'inbound' } else { 'outbound' }
    if ($m.direction -and $m.direction -ne $expectedDirection) {
        Add-Result 'FIX' $where "direction is '$($m.direction)' but the id starts with '$($suffix.Substring(0,1))', which means $expectedDirection." "Set direction to $expectedDirection unless the id itself is wrong."
    }

    $entries = @(Get-Entries $m.entityFiles $dir.FullName)
    if ($integrationManifest -and $integrationManifest.sharedFiles) {
        $entries += @(Get-Entries $integrationManifest.sharedFiles $BundleRoot | ForEach-Object { $_ | Add-Member -NotePropertyName Shared -NotePropertyValue $true -PassThru })
    }

    $examples = @(); $mappingFilesWithRules = 0; $schemaCount = 0; $hasWorkflow = $false; $docDeclared = $false
    $codeCount = 0; $standardsCount = 0; $hasMapCode = $false
    # Bytes of the entity's own main documentation and of the shared one;
    # the tool joins the two, and its size limits apply to the joined text.
    $entityDocBytes = -1; $sharedDocBytes = 0
    $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $entries) {
        $category = $item.Category; $entry = $item.Entry
        # Shared documentation counts only as the main .md/.txt file (any
        # other is reported at the integration level above).
        if ($item.Shared -and $category -eq 'documentation') {
            $sharedExt = [System.IO.Path]::GetExtension([string]$entry.path).ToLowerInvariant()
            if ($entry.purpose -ne 'main-documentation' -or @('.md', '.txt') -notcontains $sharedExt) { continue }
        }
        $label = if ($item.Shared) { "$where (shared $category)" } else { "$where ($category)" }
        if (-not $AllowedPurposes.ContainsKey($category) -and $category -ne 'endToEndMappings') {
            Add-Result 'FIX' $label "Unknown category '$category'; the extension ignores it." 'Use documentation, examples, schemas, mappings, code or standards.'
            continue
        }
        $allowed = if ($category -eq 'endToEndMappings') { $AllowedPurposes['mappings'] } else { $AllowedPurposes[$category] }
        if ($entry.purpose -and $allowed -notcontains $entry.purpose) {
            Add-Result 'FIX' $label "purpose '$($entry.purpose)' is not one of: $($allowed -join ', ')." 'Pick the closest allowed value.'
        }
        if (-not $entry.path) { Add-Result 'BLOCKING' $label 'An entry has no "path".' 'Add the file path or remove the entry.'; continue }
        $full = Join-Path $item.Base ($entry.path -replace '/', '\')
        if (-not (Test-Inside $BundleRoot $full)) {
            Add-Result 'BLOCKING' $label "$($entry.path) points outside $intName. The extension refuses it, so the file counts as missing." "Copy the file into the $intName folder and point at the copy."
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            if ($full.Length -ge 248 -and $PSVersionTable.PSVersion.Major -lt 6) {
                # Windows PowerShell 5.1 cannot open paths this long; the
                # extension can, so this is the checker's limit, not the bundle's.
                Add-Result 'FIX' $label "$($entry.path) could not be checked: its full path is $($full.Length) characters, too long for Windows PowerShell 5.1." 'Run this check with PowerShell 7 (pwsh), or keep the bundle in a shorter folder such as C:\bundles.'
                continue
            }
            Add-Result 'BLOCKING' $label "$($entry.path) does not exist on disk." 'Fix the path, or run the build script again.'
            continue
        }
        [void]$declared.Add([System.IO.Path]::GetFullPath($full))
        $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
        $bom = Get-Bom $full

        switch ($category) {
            'documentation' {
                $docDeclared = $true
                if ($item.Shared) {
                    $sharedDocBytes = [System.Text.Encoding]::UTF8.GetByteCount((Read-Text $full))
                } elseif ($BinaryExtensions -contains $ext) {
                    Add-Result 'BLOCKING' $label "$($entry.path) is a $ext file. The extension reads it as text and the AI gets garbage." 'Convert the page to Markdown (.md).'
                } elseif ($entry.purpose -eq 'main-documentation' -or $entityDocBytes -lt 0) {
                    $entityDocBytes = [System.Text.Encoding]::UTF8.GetByteCount((Read-Text $full))
                }
            }
            'schemas' {
                if ($SchemaExtensions -notcontains $ext) { Add-Result 'FIX' $label "$($entry.path): only .xsd, .json and .jschema schemas are read; this one is skipped." 'Use the .xsd or JSON Schema file.' }
                else { $schemaCount++ }
            }
            { $_ -eq 'mappings' -or $_ -eq 'endToEndMappings' } {
                if (@('.cs', '.xslt', '.xsl', '.liquid', '.js', '.ts', '.lml', '.json', '.xml') -contains $ext) {
                    $codePurpose = if ($ext -eq '.cs') { 'custom-code' } else { 'transformation' }
                    Add-Result 'FIX' $label "$($entry.path) is mapping code. The mappings list only reads .xlsx spreadsheets, so this file is not read." "Move the entry to code with purpose `"$codePurpose`"."
                } elseif ($ext -ne '.xlsx') {
                    Add-Result 'FIX' $label "$($entry.path) is not .xlsx, so the tool skips it (with a warning)." 'Save it as .xlsx (Excel workbook).'
                } elseif (-not $item.Shared) {
                    try { $info = Get-XlsxInfo $full } catch { Add-Result 'FIX' $label "$($entry.path) could not be opened as an Excel workbook." 'Re-save it from Excel as .xlsx.'; break }
                    $usable = @($info.Sheets | Where-Object { -not (Test-SkipSheet $_) })
                    if ($usable.Count -eq 0) {
                        Add-Result 'FIX' $label "Every sheet in $($entry.path) has a name containing a word like old, legacy, history or archive, so the parser skips them all (names: $($info.Sheets -join ', '))." 'Rename the current mapping sheet (e.g. "Mapping").'
                    } else {
                        $hasSource = Test-HeaderWord $info.Cells $SourceHeaderWords $false
                        $hasTarget = Test-HeaderWord $info.Cells $TargetHeaderWords $true
                        if (-not $hasSource -or -not $hasTarget) {
                            Add-Result 'FIX' $label "$($entry.path) has no recognisable source and target column headers, so it probably yields no mapping rules." 'Within the first 8 rows, use headers such as "Source field" and "Target field".'
                        } else { $mappingFilesWithRules++ }
                        $skipped = @($info.Sheets | Where-Object { $usable -notcontains $_ })
                        if ($skipped.Count -gt 0) { Add-Result 'IMPROVE' $label "These sheets are skipped because of their names: $($skipped -join ', '). Check none of them is the current mapping." 'Rename a sheet if it holds current rules.' }
                    }
                    if ($entry.purpose -eq 'archived') { Add-Result 'FIX' $label "$($entry.path) is marked archived but is still parsed as a current mapping." 'Remove old mappings from the bundle instead of marking them archived.' }
                }
            }
            'examples' {
                if ($entry.purpose -eq 'archived') { break }
                if ($BinaryExtensions -contains $ext) { Add-Result 'BLOCKING' $label "$($entry.path) is a $ext file, not a message." 'Save the message body as .xml or .json.'; break }
                $text = Read-Text $full
                $sniffed = Get-SniffedFormat $text
                if ($bom -like 'utf-16*') { Add-Result 'IMPROVE' $label "$($entry.path) is UTF-16. Analyse reads it, but Add Example would reject it." 'Save it as UTF-8.' }
                if ($ext -eq '.txt' -and $sniffed -eq 'json') { Add-Result 'IMPROVE' $label "$($entry.path) holds JSON but ends in .txt, so the file itself is labelled XML." 'Rename it to .json.' }
                $pii = @(Find-PersonalData $text)
                foreach ($hit in $pii) { Add-Result 'BLOCKING' $label "$($entry.path) contains what looks like real personal data: $hit. The tool stops and asks before sending it to the AI or sharing it with Sync." 'Replace it with test data (emails at example.com, made-up numbers that fail the check digit).' }
                $examples += [pscustomobject]@{ Path = $entry.path; Purpose = $entry.purpose; Format = $sniffed; Text = $text }
            }
            'code' {
                $codeCount++
                if ($CodeExtensions -notcontains $ext) { Add-Result 'FIX' $label "$($entry.path): $ext files are skipped." 'Include only source files (.json, .cs, .xslt, .liquid ...).' }
                if ($entry.purpose -eq 'workflow-definition') {
                    $hasWorkflow = $true
                    if ([System.IO.Path]::GetFileName($full) -ne 'workflow.json') { Add-Result 'FIX' $label "$($entry.path) is marked workflow-definition but is not named workflow.json, so the tool cannot tell which workflow it is." 'Save it as code/{workflow name}/workflow.json.' }
                }
                # Run locally copies "transformation" files into the Logic App's
                # Maps folder; C# counts as mapper code only as "custom-code".
                if ($entry.purpose -eq 'transformation' -and $ext -eq '.cs') { Add-Result 'FIX' $label "$($entry.path) is C# code marked transformation. The analysis counts mapper code only when it is marked custom-code." 'Set its purpose to custom-code.' }
                if ($entry.purpose -eq 'custom-code' -and @('.xslt', '.xsl', '.liquid') -contains $ext) { Add-Result 'FIX' $label "$($entry.path) is a Logic App map marked custom-code. Run locally only uses maps marked transformation." 'Set its purpose to transformation, and keep the file name the workflow uses.' }
                if ($entry.purpose -eq 'transformation' -and @('.xslt', '.xsl', '.liquid') -contains $ext) { $hasMapCode = $true }
            }
            'standards' {
                $standardsCount++
                if (@('.doc', '.docx', '.pdf') -contains $ext) { Add-Result 'FIX' $label "$($entry.path) is a $ext file and is skipped." 'Convert it to Markdown.' }
            }
        }
        if (@('documentation', 'code', 'standards') -contains $category -and $ext -ne '.xlsx') {
            $hits = @(Find-PersonalData (Read-Text $full))
            foreach ($hit in $hits) { Add-Result 'FIX' $label "$($entry.path) contains what looks like personal data: $hit." 'Remove or replace it before sharing the bundle.' }
        }
    }

    # ----- Entity-wide judgements ------------------------------------------
    $docBytes = [Math]::Max($entityDocBytes, 0) + $sharedDocBytes
    if ($entityDocBytes -lt 0 -and $sharedDocBytes -eq 0) {
        if (-not $docDeclared) { Add-Result 'FIX' $where 'No documentation is declared. The AI has no business context.' "Export the integration's page to documentation/main_documentation.md." }
    } elseif ($docBytes -lt 500) {
        Add-Result 'IMPROVE' $where "The documentation is only $docBytes bytes; under 500 the analysis reports THIN_COVERAGE." 'Add the real description, rules and non-functional requirements.'
    } elseif ($docBytes -gt 10000) {
        Add-Result 'IMPROVE' $where "The documentation (the entity's own plus the shared one) is $docBytes bytes; only the first 8,000 reach the AI." 'Trim change logs and appendices so the business rules come first.'
    }

    if ($examples.Count -eq 0) {
        Add-Result 'BLOCKING' $where 'No usable example message. Analyse stops with NO_EXAMPLE_MESSAGE and no tests can be generated.' 'Add one successful message from a test environment, exactly as this entity receives it (see sources.md: run history or Service Bus peek).'
    } else {
        $happy = @($examples | Where-Object { $_.Purpose -eq 'happy-path' })
        if ($happy.Count -eq 0) { Add-Result 'FIX' $where "No example is marked happy-path, so '$($examples[0].Path)' is used as the baseline for every test." 'Mark the best normal message as "happy-path".' }
        if ($happy.Count -gt 1) { Add-Result 'FIX' $where "$($happy.Count) examples are marked happy-path; only the first listed is used." 'Keep one happy-path; mark the others edge-case.' }
        $formats = @($examples | ForEach-Object { $_.Format } | Sort-Object -Unique)
        if ($formats -contains 'flat') { Add-Result 'BLOCKING' $where 'An example is neither XML nor JSON, so the entity is marked unsupported.' 'Use the message body exactly as the integration receives it.' }
        elseif ($formats.Count -gt 1) { Add-Result 'BLOCKING' $where 'Examples mix XML and JSON, so the entity is marked unsupported.' 'Keep only examples in the wire format this entity receives.' }
        if ($m.format -and ($m.format -eq 'xml' -or $m.format -eq 'json') -and $formats.Count -eq 1 -and $formats[0] -ne $m.format) {
            Add-Result 'BLOCKING' $where "The manifest says format '$($m.format)' but the examples are $($formats[0]). The declared format wins, and tests come out in the wrong dialect." "Set format to $($formats[0])."
        }
        $allPaths = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($ex in $examples) { foreach ($p in (Get-ExamplePaths $ex.Text $ex.Format)) { [void]$allPaths.Add($p) } }
        if ($formats -notcontains 'flat' -and $allPaths.Count -lt 10) { Add-Result 'IMPROVE' $where "The examples hold only $($allPaths.Count) distinct fields; under 10 the analysis reports THIN_COVERAGE." 'Use a fuller message from a test environment, or add an edge-case test message with the optional blocks filled in.' }
    }

    $entityMappings = @($entries | Where-Object { -not $_.Shared -and $_.Category -eq 'mappings' })
    if ($entityMappings.Count -eq 0) { Add-Result 'FIX' $where 'No entity mapping spreadsheet. Shared and end-to-end mappings are not turned into rules, so there are no mapping tests.' "Add this entity's current mapping .xlsx under entityFiles.mappings." }
    if (($schemaCount + $mappingFilesWithRules + $examples.Count) -lt 3) {
        $have = "$schemaCount schema(s), $mappingFilesWithRules readable mapping spreadsheet(s), $($examples.Count) example(s)"
        Add-Result 'IMPROVE' $where "Fewer than 3 schemas, readable mapping spreadsheets and examples together ($have); the analysis reports THIN_COVERAGE." 'Add whichever of these is missing: an example, the entity schema, a mapping spreadsheet.'
    }
    if ($schemaCount -eq 0) { Add-Result 'IMPROVE' $where 'No schema, so no required-field, length or pattern tests.' 'Add the source (inbound) or target (outbound) schema.' }
    if (-not $hasWorkflow) { Add-Result 'IMPROVE' $where 'No workflow.json, so the tool cannot find the workflow to test in Azure, Run locally is not available, and workflow, retry and routing tests have less to go on.' 'Add code/{workflow name in Azure}/workflow.json with purpose workflow-definition.' }
    if ($standardsCount -eq 0) { Add-Result 'IMPROVE' $where 'No standards (for example an error-handling guide). Retry and error-handling tests have nothing to quote.' 'Add the guide under sharedFiles.standards in the integration manifest.' }

    # The same score the sidebar shows: documentation, a mapping spreadsheet,
    # a schema, code and an example each count one point.
    $points = [ordered]@{
        'documentation'       = $docDeclared
        'mapping spreadsheet' = $entityMappings.Count -gt 0
        'schema'              = $schemaCount -gt 0
        'code'                = $codeCount -gt 0
        'example'             = $examples.Count -gt 0
    }
    $present = @($points.Keys | Where-Object { $points[$_] })
    $missing = @($points.Keys | Where-Object { -not $points[$_] })
    $score = $present.Count
    $readiness = if ($score -ge 4) { 'ready' } elseif ($score -ge 2) { 'partial' } else { 'thin' }
    $detail = "has $($present -join ', ')"
    if ($missing.Count -gt 0) { $detail += "; missing $($missing -join ', ')" }
    $detail += "; $mappingFilesWithRules spreadsheet(s) with source and target column headers"
    $readinessByEntity[$where] = "$readiness, $score of 5 ($detail)"

    # Files that sit in the entity folder but are not in the manifest are never read.
    Get-ChildItem -LiteralPath $dir.FullName -Recurse -File | Where-Object { $_.Name -ne 'manifest.json' -and -not $declared.Contains($_.FullName) } | ForEach-Object {
        $rel = $_.FullName.Substring($dir.FullName.Length + 1)
        $noise = ($rel -match '(^|\\)(Models|Deployment|APIM|Tests|Archive|Archived)\\') -or ($BinaryExtensions -contains $_.Extension.ToLowerInvariant() -and $_.Extension -ne '.xlsx')
        if ($noise) { Add-Result 'IMPROVE' $where "$rel does not belong in a bundle." 'Delete it from the bundle (the original stays in its source).' }
        else { Add-Result 'IMPROVE' $where "$rel is in the folder but not in the manifest, so it is never read." 'Add it to entityFiles, or remove it.' }
    }
}

# ----- Report ----------------------------------------------------------------
$order = @{ 'BLOCKING' = 0; 'FIX' = 1; 'IMPROVE' = 2 }
$sorted = $results | Sort-Object @{ Expression = { $order[$_.Level] } }, Where
foreach ($r in $sorted) {
    Write-Host ("[{0}] {1}" -f $r.Level, $r.Where)
    Write-Host ("    {0}" -f $r.What)
    Write-Host ("    What to do: {0}" -f $r.Todo)
}
$blocking = @($results | Where-Object { $_.Level -eq 'BLOCKING' }).Count
$fix = @($results | Where-Object { $_.Level -eq 'FIX' }).Count
$improve = @($results | Where-Object { $_.Level -eq 'IMPROVE' }).Count
Write-Host ''
foreach ($key in $readinessByEntity.Keys) {
    # The sidebar score counts files; it does not know about BLOCKING items.
    $blocked = @($results | Where-Object { $_.Level -eq 'BLOCKING' -and $_.Where -like "$key*" }).Count -gt 0
    $suffix = if ($blocked) { ' - but BLOCKING above: Analyse cannot run yet' } else { '' }
    Write-Host "Sidebar readiness ${key}: $($readinessByEntity[$key])$suffix"
}
Write-Host "$($entityDirs.Count) entities checked: $blocking blocking, $fix to fix, $improve to improve."
if ($blocking -gt 0) { exit 1 }
exit 0
