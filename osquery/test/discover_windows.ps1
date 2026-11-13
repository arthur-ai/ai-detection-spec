# Exercise bin/discover.ps1, the Windows writer, against the shipped pack and against the
# inputs that break a writer: a branch whose table is missing, a branch that never
# answers, a document outside ASCII, and a cache that is missing or cut short.
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File osquery\test\discover_windows.ps1
#
# Runs in about a minute, most of it the 30s bound, and needs osquery on a real Windows:
# the shipped pack's Windows branches name tables no other platform has.
#
# CMDLETS AND CORE TYPES ONLY, like the script under test. ci.yml runs this file a second
# time with __PSLockdownPolicy=4, which puts it and every runner it starts in
# ConstrainedLanguage mode: the mode an unsigned script gets under AppLocker or WDAC.

$ErrorActionPreference = 'Stop'

$Osq = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path (Join-Path $Osq 'bin') 'discover.ps1'
$ShippedPack = Join-Path (Join-Path $Osq 'dist') 'ai-detection-spec.conf'
# The PowerShell running this file, so the runner is tested under the same one.
$Shell = (Get-Process -Id $PID).Path
$Fail = 0

$Work = Join-Path $env:TEMP "discover-test.$(Get-Random)"
# The runner's TEMP for the whole suite, so "left nothing behind" can be asserted.
$RunnerTemp = Join-Path $Work 'temp'
New-Item -ItemType Directory -Path $RunnerTemp | Out-Null
$HostTemp = $env:TEMP
$HostTmp = $env:TMP
$HostOsqi = $env:OSQI

function Check([string]$Label, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        Write-Host "    ok    $Label"
    } else {
        Write-Host "    FAIL  $Label  $Detail"
        $script:Fail = 1
    }
}

# The runner as a deployment starts it: a process of its own, by file. Returns the lines it
# printed; its exit status is in $LASTEXITCODE.
function Invoke-Runner {
    # Under 'Stop', 5.1 turns the first line a program writes to a redirected stderr into
    # a terminating error, and the line is wanted here as a line.
    $ErrorActionPreference = 'Continue'
    $env:TEMP = $RunnerTemp
    $env:TMP = $RunnerTemp
    try {
        $lines = & $Shell -NoProfile -ExecutionPolicy Bypass -File $Runner @args 2>&1 |
            ForEach-Object { "$_" }
    } finally {
        $env:TEMP = $HostTemp
        $env:TMP = $HostTmp
    }
    return , @($lines)
}

function Read-Rows([string]$Path) {
    return , @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
}

# 5.1's ConvertFrom-Json hands an array back as one object, and 7's unrolls it.
function Expand-Rows($Rows) {
    foreach ($item in $Rows) {
        if ($item -is [array]) { foreach ($row in $item) { $row } } else { $item }
    }
}

function Get-Scans($Rows) {
    $scans = @{}
    foreach ($row in (Expand-Rows $Rows)) {
        if ($row.kind -eq 'scan') { $scans[$row.id] = $row.extra }
    }
    return $scans
}

function Format-Scans($Scans) {
    return (($Scans.Keys | Sort-Object | ForEach-Object { "$_=$($Scans[$_])" }) -join ' ')
}

function Get-Leftovers {
    return , @(Get-ChildItem -LiteralPath $RunnerTemp -Force | ForEach-Object { $_.Name })
}

# A pack file from a hashtable of name -> query, every one a Windows branch. Written as
# the runner writes text, UTF-8 with no byte order mark.
function New-Pack([string]$Path, $Queries) {
    $entries = @{}
    foreach ($name in $Queries.Keys) {
        $entries[$name] = @{ query = $Queries[$name]; interval = 3600; platform = 'windows'; description = 'test' }
    }
    $json = ConvertTo-Json -InputObject @{ queries = $entries } -Depth 5
    New-Item -ItemType File -Path $Path -Value $json -Force | Out-Null
}

function Get-FirstBytes([string]$Path, [int]$Count) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return , @(Get-Content -LiteralPath $Path -AsByteStream -TotalCount $Count)
    }
    return , @(Get-Content -LiteralPath $Path -Encoding Byte -TotalCount $Count)
}

$Row = "SELECT '{0}' AS kind, '{1}' AS id, '{2}' AS ver, '{3}' AS loc, '{4}' AS extra, '' AS perms;"

try {
    Write-Host 'discover.ps1 on the shipped pack'
    $inventory = Join-Path (Join-Path $Work 'real') 'inventory.json'
    $status = Join-Path (Join-Path $Work 'real') 'status.txt'
    $printed = Invoke-Runner --write $inventory --status $status
    Check 'the writer exits 0' ($LASTEXITCODE -eq 0) "exit ${LASTEXITCODE}: $($printed -join ' | ')"
    $rows = @()
    $scans = @{}
    if (Test-Path -LiteralPath $inventory) {
        $rows = @(Expand-Rows (Read-Rows $inventory))
        $scans = Get-Scans $rows
    }
    # A runner always has programs, so a short payload is a branch that did not run.
    Check 'the payload is a JSON array of more than 100 rows' ($rows.Count -gt 100) "$($rows.Count) rows"

    # WHICH BRANCHES RAN, held two ways. Against the pack, so a query added upstream is run
    # here too; and against three names typed out, because a set derived from the pack on
    # both sides would still agree if the filter dropped every branch.
    $shipped = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ShippedPack -Raw -Encoding UTF8)
    $want = @($shipped.queries.PSObject.Properties |
        Where-Object { @('windows', 'all') -contains $_.Value.platform } |
        ForEach-Object { $_.Name }) + 'containers'
    $got = @($scans.Keys)
    $missing = @($want | Where-Object { $got -notcontains $_ })
    $extra = @($got | Where-Object { $want -notcontains $_ })
    Check 'every Windows branch of the pack left a scan row, and no other did' `
        ($missing.Count -eq 0 -and $extra.Count -eq 0) "missing: $missing; unexpected: $extra"
    $typed = @('filesystem-windows', 'programs-windows', 'runtime-windows')
    Check 'programs, filesystem and runtime each ran' `
        (@($typed | Where-Object { $scans[$_] -eq 'ok' }).Count -eq 3) (Format-Scans $scans)
    Check 'no branch failed on a healthy machine' `
        (@($scans.Keys | Where-Object { $scans[$_] -eq 'error' }).Count -eq 0) (Format-Scans $scans)

    $line = ''
    if (Test-Path -LiteralPath $status) { $line = Get-Content -LiteralPath $status -Raw -Encoding UTF8 }
    Check 'the status is one line that ends in a newline, with no carriage return' `
        ($line -match '^[^\r\n]+\n$') "got: $line"
    $counted = -1
    if ($line -match '^(ok|degraded) \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ rows=(\d+) ') { $counted = [int]$Matches[2] }
    Check 'the status counts the rows the payload holds' ($counted -eq $rows.Count) "status: $line payload: $($rows.Count)"
    Check 'the status names a branch and its outcome' ($line -match ' programs-windows=ok( |\n)') "got: $line"
    # 0x6F and 0x64 are `o` and `d`, of ok and degraded: the line was written with no byte
    # order mark, which Get-Content would have taken off without a word.
    $first = Get-FirstBytes $status 1
    Check 'the status starts with its first word: no byte order mark' `
        ($first.Count -eq 1 -and ($first[0] -eq 0x6F -or $first[0] -eq 0x64)) "first byte: $first"
    # 0x5B is `[`: no byte order mark, and not UTF-16.
    $first = Get-FirstBytes $inventory 2
    Check 'the payload starts with its bracket: UTF-8, no byte order mark' `
        ($first.Count -eq 2 -and $first[0] -eq 0x5B -and $first[1] -ne 0) "first bytes: $first"
    Check '--write prints no payload' (@($printed | Where-Object { $_ -match '^\s*[\[{]' }).Count -eq 0) `
        "printed: $(@($printed | Select-Object -First 3) -join ' | ')"
    Check 'the writer left nothing in TEMP' ((Get-Leftovers).Count -eq 0) "left: $(Get-Leftovers)"
    Check 'and nothing beside the files it wrote' `
        (@(Get-ChildItem -LiteralPath (Split-Path -Parent $inventory) -Force).Count -eq 2) `
        "holds: $(Get-ChildItem -LiteralPath (Split-Path -Parent $inventory) -Force | ForEach-Object { $_.Name })"

    Write-Host '  a relative path is written under the working directory'
    Push-Location -LiteralPath $Work
    try {
        $printed = Invoke-Runner --write 'relative\inventory.json'
    } finally {
        Pop-Location
    }
    Check 'the payload is where the path says' `
        ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path (Join-Path $Work 'relative') 'inventory.json'))) `
        "exit ${LASTEXITCODE}: $($printed -join ' | ')"

    Write-Host '  one broken branch costs one branch'
    # THE RELIABILITY CLAIM the independent writer exists for. Composed, one unavailable
    # table returns zero rows for the whole inventory; apart, it costs its own branch.
    $packPath = Join-Path $Work 'broken.conf'
    New-Pack $packPath @{
        'filesystem-windows' = $shipped.queries.'filesystem-windows'.query
        'programs-windows'   = $shipped.queries.'programs-windows'.query
        # A table that cannot exist, which is what an older osquery presents for a real one.
        'broken'             = 'SELECT 1 AS kind, 2 AS id, 3 AS ver, 4 AS loc, 5 AS extra, 6 AS perms FROM table_that_does_not_exist;'
    }
    $inventory = Join-Path (Join-Path $Work 'broken') 'inventory.json'
    $status = Join-Path (Join-Path $Work 'broken') 'status.txt'
    $env:DISCOVER_PACK = $packPath
    $printed = Invoke-Runner --write $inventory --status $status
    $code = $LASTEXITCODE
    $scans = @{}
    $rows = @()
    if (Test-Path -LiteralPath $inventory) {
        $rows = @(Expand-Rows (Read-Rows $inventory))
        $scans = Get-Scans $rows
    }
    Check 'a branch that could not look is not a failed run' ($code -eq 0) "exit $code"
    Check 'the good branches still reported' `
        ($scans['programs-windows'] -eq 'ok' -and $scans['filesystem-windows'] -eq 'ok' -and $rows.Count -gt 10) `
        "$($rows.Count) rows, $(Format-Scans $scans)"
    Check 'the broken branch reports its own failure, not silence' ($scans['broken'] -eq 'error') (Format-Scans $scans)
    Check 'and its message says why, in osqueryi''s words' `
        (@($printed | Where-Object { $_ -match "branch 'broken' did not complete \(exit [1-9]" }).Count -eq 1 -and
         @($printed | Where-Object { $_ -match 'osqueryi: .*table_that_does_not_exist' }).Count -ge 1) `
        "printed: $($printed -join ' | ')"
    $line = ''
    if (Test-Path -LiteralPath $status) { $line = Get-Content -LiteralPath $status -Raw -Encoding UTF8 }
    Check 'the status says degraded, and which branch' ($line -match '^degraded .* broken=error') "got: $line"
    Check 'the writer left nothing in TEMP' ((Get-Leftovers).Count -eq 0) "left: $(Get-Leftovers)"

    Write-Host '  a document outside ASCII reaches the payload as it left osqueryi'
    # A home directory is named by its user, in any script. Every hop is on the path: the
    # pack, the branch statement, osqueryi, the merge statement, the payload. Built from
    # code points, because this file is ASCII.
    $name = "caf$([char]0xE9)-$([char]0x65E5)$([char]0x672C)"
    New-Pack $packPath @{
        'unicode' = ($Row -f 'app', $name, '%s', "C:\Users\$name\it''s", '')
    }
    $inventory = Join-Path (Join-Path $Work 'unicode') 'inventory.json'
    $printed = Invoke-Runner --write $inventory
    $found = $null
    if (Test-Path -LiteralPath $inventory) {
        $found = Expand-Rows (Read-Rows $inventory) | Where-Object { $_.kind -eq 'app' } | Select-Object -First 1
    }
    Check 'the id comes back character for character' ($found -and $found.id -ceq $name) "exit ${LASTEXITCODE}, got: $($found.id)"
    Check 'and so do a quote, a backslash and a percent sign' `
        ($found -and $found.loc -ceq "C:\Users\$name\it's" -and $found.ver -ceq '%s') "got: $($found.loc) / $($found.ver)"

    # --cache PRINTS, and 5.1 encodes what a script prints in the console's code page. The
    # payload reaches this reader whole only because each character outside ASCII left as
    # its \u escape.
    $printed = Invoke-Runner --cache $inventory
    $code = $LASTEXITCODE
    $echoed = $null
    if ($code -eq 0) {
        $echoed = Expand-Rows (ConvertFrom-Json -InputObject ($printed -join "`n")) |
            Where-Object { $_.kind -eq 'app' } | Select-Object -First 1
    }
    Check '--cache prints that payload in ASCII' `
        ($code -eq 0 -and @($printed | Where-Object { $_ -cmatch '[^\x00-\x7F]' }).Count -eq 0) `
        "exit ${code}: $(@($printed | Where-Object { $_ -cmatch '[^\x00-\x7F]' } | Select-Object -First 1))"
    Check 'and a reader of what it printed gets the id and the path it wrote' `
        ($echoed -and $echoed.id -ceq $name -and $echoed.loc -ceq "C:\Users\$name\it's") "got: $($echoed.id) / $($echoed.loc)"

    Write-Host '  a branch that never answers is stopped, and costs one branch (30s)'
    # THE KILL DECIDES, NOT THE CHILD. A recursive count with no end holds osqueryi until
    # the bound fires; its output is discarded and its branch reads `error`.
    New-Pack $packPath @{
        'a-quick' = ($Row -f 'app', 'quick-1', '1', '', '')
        'b-never' = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT 'app' AS kind, CAST(count(*) AS TEXT) AS id, '' AS ver, '' AS loc, '' AS extra, '' AS perms FROM c;"
    }
    $inventory = Join-Path (Join-Path $Work 'never') 'inventory.json'
    $started = Get-Date
    $printed = Invoke-Runner --write $inventory
    $code = $LASTEXITCODE
    $took = [int]((Get-Date) - $started).TotalSeconds
    $scans = @{}
    if (Test-Path -LiteralPath $inventory) { $scans = Get-Scans (Read-Rows $inventory) }
    Check 'the run finished, soon after the bound' ($code -eq 0 -and $took -ge 29 -and $took -lt 90) "exit $code after ${took}s"
    Check 'the stopped branch reads error and the other ok' `
        ($scans['b-never'] -eq 'error' -and $scans['a-quick'] -eq 'ok') (Format-Scans $scans)
    Check 'and its message names the bound' `
        (@($printed | Where-Object { $_ -match "branch 'b-never' did not complete \(no answer in 30s\)" }).Count -eq 1) `
        "printed: $($printed -join ' | ')"
    # A stopped osqueryi holds its output file until it has gone, so an emptied TEMP is
    # also the proof that it went.
    Check 'the stopped osqueryi is gone, and its files with it' ((Get-Leftovers).Count -eq 0) "left: $(Get-Leftovers)"

    Write-Host '  a run that cannot write keeps the last payload'
    $inventory = Join-Path (Join-Path $Work 'real') 'inventory.json'
    $before = (Get-FileHash -LiteralPath $inventory -Algorithm SHA256).Hash
    # A pack with no Windows branch: nothing to run, so nothing to publish.
    New-Item -ItemType File -Path $packPath -Force `
        -Value '{"queries":{"apps":{"query":"SELECT 1;","interval":3600,"platform":"darwin","description":"t"}}}' | Out-Null
    $printed = Invoke-Runner --write $inventory
    Check 'the writer exits 1 and says the pack holds nothing for Windows' `
        ($LASTEXITCODE -eq 1 -and @($printed | Where-Object { $_ -match 'no queries in .* for platform windows' }).Count -eq 1) `
        "exit ${LASTEXITCODE}: $($printed -join ' | ')"
    Check 'the last payload is untouched, with nothing beside it' `
        ((Get-FileHash -LiteralPath $inventory -Algorithm SHA256).Hash -eq $before -and
         @(Get-ChildItem -LiteralPath (Split-Path -Parent $inventory) -Force).Count -eq 2) `
        "holds: $(Get-ChildItem -LiteralPath (Split-Path -Parent $inventory) -Force | ForEach-Object { $_.Name })"
    $env:DISCOVER_PACK = $null

    Write-Host '  --cache checks the file and runs no query'
    $printed = Invoke-Runner --cache $inventory
    $echoed = @()
    if ($LASTEXITCODE -eq 0) { $echoed = @(Expand-Rows (ConvertFrom-Json -InputObject ($printed -join "`n"))) }
    Check 'a good cache exits 0 and is printed whole' `
        ($echoed.Count -gt 100 -and $echoed.Count -eq @(Expand-Rows (Read-Rows $inventory)).Count) `
        "exit ${LASTEXITCODE}, $($echoed.Count) rows printed"

    # A missing cache is a fact about the deployment. Saying nothing would let it read as
    # nothing installed here.
    $absent = Join-Path $Work "no such cache $name.json"
    $printed = Invoke-Runner --cache $absent
    $code = $LASTEXITCODE
    $marker = $null
    $json = @($printed | Where-Object { $_ -match '^\[' })
    if ($json.Count -eq 1) { $marker = Expand-Rows (ConvertFrom-Json -InputObject $json[0]) | Select-Object -First 1 }
    Check 'a missing cache exits 1 with a no-cache row that names the path, outside ASCII or not' `
        ($code -eq 1 -and $marker -and $marker.kind -eq 'scan' -and $marker.id -eq 'inventory' -and
         $marker.extra -eq 'no-cache' -and $marker.loc -ceq $absent -and $marker.ver -match '^\d{10}$') `
        "exit ${code}: $($printed -join ' | ')"

    $cut = Join-Path $Work 'cut.json'
    $text = Get-Content -LiteralPath $inventory -Raw -Encoding UTF8
    New-Item -ItemType File -Path $cut -Value $text.Substring(0, 200) -Force | Out-Null
    $printed = Invoke-Runner --cache $cut
    $code = $LASTEXITCODE
    $marker = $null
    $json = @($printed | Where-Object { $_ -match '^\[' })
    if ($json.Count -eq 1) { $marker = Expand-Rows (ConvertFrom-Json -InputObject $json[0]) | Select-Object -First 1 }
    Check 'a cache cut short exits 1 with an error row' ($code -eq 1 -and $marker -and $marker.extra -eq 'error') `
        "exit ${code}: $($printed -join ' | ')"

    New-Item -ItemType File -Path $cut -Value '{"kind":"app"}' -Force | Out-Null
    $printed = Invoke-Runner --cache $cut
    Check 'a cache that is JSON and not an array is refused too' `
        ($LASTEXITCODE -eq 1 -and @($printed | Where-Object { $_ -match 'is not a JSON array' }).Count -eq 1) `
        "exit ${LASTEXITCODE}: $($printed -join ' | ')"

    # A BROKEN VALIDATOR IS NOT A BROKEN CACHE. whoami answers, and not with a verdict.
    $env:OSQI = (Get-Command -Name whoami -CommandType Application | Select-Object -First 1).Path
    $printed = Invoke-Runner --cache $inventory
    $code = $LASTEXITCODE
    $env:OSQI = $HostOsqi
    Check 'a validator that gives no verdict exits 1 and names osqueryi, not the file' `
        ($code -eq 1 -and @($printed | Where-Object { $_ -match 'osqueryi did not answer' }).Count -eq 1 -and
         @($printed | Where-Object { $_ -match '^\[' }).Count -eq 0) "exit ${code}: $($printed -join ' | ')"
    Check 'the checks left nothing in TEMP' ((Get-Leftovers).Count -eq 0) "left: $(Get-Leftovers)"

    Write-Host '  arguments'
    $printed = Invoke-Runner --names
    Check 'an argument this script does not take is refused by name' `
        ($LASTEXITCODE -eq 1 -and ($printed -join ' ') -match 'unknown argument: --names') "exit ${LASTEXITCODE}: $printed"
    $printed = Invoke-Runner --write
    Check '--write with no path is refused' ($LASTEXITCODE -eq 1 -and ($printed -join ' ') -match 'needs a path') "exit ${LASTEXITCODE}: $printed"
    $printed = Invoke-Runner --status (Join-Path $Work 's.txt')
    Check '--status with no --write is refused' ($LASTEXITCODE -eq 1 -and ($printed -join ' ') -match 'needs --write') "exit ${LASTEXITCODE}: $printed"
    $printed = Invoke-Runner --write (Join-Path $Work 'a.json') --cache (Join-Path $Work 'b.json')
    Check '--write with --cache is refused' ($LASTEXITCODE -eq 1 -and ($printed -join ' ') -match 'pick one') "exit ${LASTEXITCODE}: $printed"

    Write-Host '  a broken branch document costs one branch, and the merge says which'
    # THE MERGE, HANDED ITS INPUT DIRECTLY: test/docker_states.sh's six branches, each
    # carrying a different fact.
    #
    #   good      rows, no scan row of its own    -> rows kept, a synthetic `ok` marker added
    #   substit   rows plus id=<its own name>     -> its row stands, no synthetic marker
    #   additive  rows plus a scan row, other id  -> both ship
    #   broken    not JSON at all                 -> `error`, and the other five still report
    #   empty     an empty document, not failed   -> `error`
    #   sentinel  failed                          -> `error`
    . $Runner
    $Osqi = Find-Osqueryi
    $one = '{{"kind":"{0}","id":"{1}","ver":"1","loc":"","extra":"{2}","perms":""}}'
    $sql = Get-MergeSql @(
        @{ Name = 'good'; Failed = 0; Doc = '[' + ($one -f 'app', 'good-1', '') + ']' }
        @{ Name = 'substit'; Failed = 0; Doc = '[' + ($one -f 'app', 'sub-1', '') + ',' + ($one -f 'scan', 'substit', 'timeout:6') + ']' }
        @{ Name = 'additive'; Failed = 0; Doc = '[' + ($one -f 'app', 'add-1', '') + ',' + ($one -f 'scan', 'systemd', 'absent') + ']' }
        @{ Name = 'broken'; Failed = 0; Doc = '[{"kind":"app","id":' }
        @{ Name = 'empty'; Failed = 0; Doc = '' }
        @{ Name = 'sentinel'; Failed = 1; Doc = '' }
    )
    $statement = Join-Path $Work 'merge.sql'
    $merged = Join-Path $Work 'merged.json'
    Write-Text $statement $sql
    $env:TEMP = $RunnerTemp
    $env:TMP = $RunnerTemp
    $rc = Invoke-Osqueryi $statement $merged (Join-Path $Work 'merge.err') 0 @('--json')
    $env:TEMP = $HostTemp
    $env:TMP = $HostTmp
    $rows = @()
    if ($rc -eq 0) { $rows = @(Expand-Rows (Read-Rows $merged)) }
    Check 'the merge answers at all with a malformed branch in the set' ($rows.Count -gt 0) "osqueryi exit $rc"
    $scans = Get-Scans $rows
    $wantScans = 'additive=ok broken=error empty=error good=ok sentinel=error substit=timeout:6 systemd=absent'
    Check 'each branch reports the right outcome' ((Format-Scans $scans) -eq $wantScans) "got: $(Format-Scans $scans)"
    $ids = (@($rows | Where-Object { $_.kind -ne 'scan' } | ForEach-Object { $_.id }) | Sort-Object) -join ' '
    Check 'and no branch loses its rows' ($ids -eq 'add-1 good-1 sub-1') "got: $ids"
    Check 'a branch that wrote its own scan row gets no second one' `
        (@($rows | Where-Object { $_.kind -eq 'scan' -and $_.id -eq 'substit' }).Count -eq 1) "rows: $($rows.Count)"
} finally {
    $env:TEMP = $HostTemp
    $env:TMP = $HostTmp
    $env:OSQI = $HostOsqi
    $env:DISCOVER_PACK = $null
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($Fail -eq 0) { Write-Host 'discover-windows: PASS' } else { Write-Host 'discover-windows: FAIL' }
exit $Fail
