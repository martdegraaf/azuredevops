<#
.SYNOPSIS
    Scans Azure DevOps repositories for stale branches and generates a Markdown report.

.DESCRIPTION
    Queries all repositories matching a given prefix for branches whose last commit
    is older than a configurable threshold. Produces a Markdown report with statistics,
    top-10 lists, and a "Hall of Shame" ranking.

.EXAMPLE
    # Generate a report for the default project () using defaults (6-month threshold)
    .\Get-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org"

.EXAMPLE
    # Scan all projects in the org for branches older than 12 months
    .\Get-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -Project "" -ThresholdMonths 12

.EXAMPLE
    # Only scan repos starting with "MyApp." and write the report to a custom folder
    .\Get-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -RepoPrefix "MyApp." -OutputFolder "C:\Reports"
#>
param(
    [string]$OrganizationUrl = "https://dev.azure.com/Organisation",

    [string]$Project = "Project",

    [string]$RepoPrefix = "",

    [int]$ThresholdMonths = 6,

    [string]$OutputFolder = "reports"
)

$accessToken = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query "accessToken" --output tsv
if ($null -eq $accessToken) {
    exit 1
}

$authHeader = "Bearer " + $accessToken

$serviceAccounts = @()  # @('svc_RDWBuild')  # temporarily disabled to see where svc accounts appear

# Author aliases — maps known variants to a canonical name
$authorAliases = @{
    'Graaf, de Mart' = 'Mart de Graaf'
}

function Resolve-Author {
    param([string]$Name)
    if ($authorAliases.ContainsKey($Name)) { return $authorAliases[$Name] }
    return $Name
}

function Format-HumanAge {
    param([DateTime]$Date)
    $ts = (Get-Date) - $Date
    $years  = [math]::Floor($ts.Days / 365)
    $months = [math]::Floor(($ts.Days % 365) / 30)
    $parts  = @()
    if ($years  -gt 0) { $parts += "$years yr$(if ($years  -gt 1) {'s'})" }
    if ($months -gt 0) { $parts += "$months mo" }
    if ($parts.Count -eq 0) { $parts += "$($ts.Days) day$(if ($ts.Days -gt 1) {'s'})" }
    return ($parts -join ', ')
}

function Invoke-AzDoGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [hashtable]$Headers
    )

    return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -ErrorAction Stop
}

function Get-AzDoPaged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $items = @()
    $continuation = $null

    do {
        $headers = @{ Authorization = $authHeader }
        if ($continuation) {
            $headers["x-ms-continuationtoken"] = $continuation
        }

        try {
            $respHeaders = $null
            $response = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -ResponseHeadersVariable respHeaders -ErrorAction Stop
        } catch {
            Write-Warning "Request failed for $Url : $_"
            return $items
        }

        if ($null -ne $response.value) {
            $items += $response.value
        } else {
            $items += $response
        }

        $continuation = if ($respHeaders) { $respHeaders["x-ms-continuationtoken"] } else { $null }
    } while ($continuation)

    return $items
}

$cutoffDate = (Get-Date).AddMonths(-1 * $ThresholdMonths)

Write-Host "[1/3] Fetching projects..." -ForegroundColor Cyan
if ([string]::IsNullOrWhiteSpace($Project)) {
    $projects = Get-AzDoPaged ("{0}/_apis/projects?api-version=7.1-preview.4" -f $OrganizationUrl)
} else {
    $projects = @(@{ name = $Project })
}
Write-Host "      Found $($projects.Count) project(s)." -ForegroundColor Gray

$staleBranches = @()
$projectIndex = 0

foreach ($projectItem in $projects) {
    $projectName = $projectItem.name
    $projectIndex++

    Write-Progress -Id 1 -Activity "Scanning projects" -Status "Project: $projectName ($projectIndex / $($projects.Count))" -PercentComplete (($projectIndex / $projects.Count) * 100)

    Write-Host "[2/3] [$projectName] Fetching [$RepoPrefix] repositories..." -ForegroundColor Cyan
    $reposUrl = "{0}/{1}/_apis/git/repositories?api-version=7.1-preview.1" -f $OrganizationUrl, $projectName
    $repos = Get-AzDoPaged $reposUrl
    $matchingRepos = $repos | Where-Object { $_.name.StartsWith($RepoPrefix) -and $_.isDisabled -ne $true }
    Write-Host "      Found $($matchingRepos.Count) matching repo(s)." -ForegroundColor Gray

    $repoIndex = 0
    foreach ($repo in $matchingRepos) {
        $repoIndex++
        Write-Progress -Id 2 -ParentId 1 -Activity "Scanning repos" -Status "Repo: $($repo.name) ($repoIndex / $($matchingRepos.Count))" -PercentComplete (($repoIndex / $matchingRepos.Count) * 100)
        Write-Host "      [$($repo.name)] Fetching branches..." -ForegroundColor DarkCyan

        $refsUrl = "{0}/{1}/_apis/git/repositories/{2}/refs?filter=heads/&api-version=7.1-preview.1" -f $OrganizationUrl, $projectName, $repo.id
        $refs = Get-AzDoPaged $refsUrl
        Write-Host "      [$($repo.name)] $($refs.Count) branch(es) found. Checking staleness..." -ForegroundColor DarkCyan

        $branchIndex = 0
        foreach ($ref in $refs) {
            $branchIndex++
            $branchName = $ref.name -replace "^refs/heads/", ""
            Write-Progress -Id 3 -ParentId 2 -Activity "Checking branches" -Status "Branch: $branchName ($branchIndex / $($refs.Count))" -PercentComplete (($branchIndex / $refs.Count) * 100)

            $commitId = $ref.objectId
            $commitUrl = "{0}/{1}/_apis/git/repositories/{2}/commits/{3}?api-version=7.1-preview.1" -f $OrganizationUrl, $projectName, $repo.id, $commitId
            try {
                $commit = Invoke-AzDoGet -Url $commitUrl -Headers @{ Authorization = $authHeader }
            } catch {
                Write-Warning "Failed to get commit $commitId for branch $branchName in $($repo.name): $_"
                continue
            }

            $commitDate = [DateTime]$commit.committer.date
            if ($commitDate -lt $cutoffDate) {
                $staleBranches += [PSCustomObject]@{
                    Project    = $projectName
                    Repository = $repo.name
                    Branch     = $branchName
                    Author     = Resolve-Author $commit.committer.name
                    CommitId   = $commitId
                    CommitDate = $commitDate
                    CommitLink = "{0}/{1}/_git/{2}/commit/{3}" -f $OrganizationUrl, $projectName, $repo.name, $commitId
                }
            }
        }
        Write-Progress -Id 3 -ParentId 2 -Activity "Checking branches" -Completed
    }
    Write-Progress -Id 2 -ParentId 1 -Activity "Scanning repos" -Completed
}
Write-Progress -Id 1 -Activity "Scanning projects" -Completed
Write-Host "[3/3] Generating report..." -ForegroundColor Cyan

if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = Join-Path $OutputFolder ("stale-branches-{0}.md" -f $timestamp)

$lines = @()
$lines += "# Stale Branches Report"
$lines += ""
$lines += "- Organization: $OrganizationUrl"
$lines += "- Project: " + ($(if ([string]::IsNullOrWhiteSpace($Project)) { "(all projects)" } else { $Project }))
$lines += "- Repo prefix: $RepoPrefix"
$lines += "- Threshold months: $ThresholdMonths"
$lines += "- Cutoff date: $($cutoffDate.ToString("dd MMM yyyy"))"
$lines += "- Generated: $((Get-Date).ToString("dd MMM yyyy HH:mm"))"
$lines += ""

if ($staleBranches.Count -eq 0) {
    $lines += "No stale branches found."
} else {
    $lines += "Found $($staleBranches.Count) stale branches."
    $lines += ""
    $lines += "| Project | Repository | Branch | Author | Commit Date | Commit |"
    $lines += "| --- | --- | --- | --- | --- | --- |"

    foreach ($item in $staleBranches) {
        $lines += "| {0} | {1} | {2} | {3} | {4} | [link]({5}) |" -f $item.Project, $item.Repository, $item.Branch, $item.Author, $item.CommitDate.ToString("dd MMM yyyy"), $item.CommitLink
    }

    $now = Get-Date
    $agesDays = $staleBranches | ForEach-Object { ($now - $_.CommitDate).Days }
    $avgAge = [math]::Round(($agesDays | Measure-Object -Average).Average)
    $maxAge = ($agesDays | Measure-Object -Maximum).Maximum
    $minAge = ($agesDays | Measure-Object -Minimum).Minimum
    $repoCount = ($staleBranches | Select-Object -ExpandProperty Repository -Unique).Count
    $fossil = $staleBranches | Sort-Object CommitDate | Select-Object -First 1

    $lines += ""
    $lines += "## Statistics"
    $lines += ""
    $lines += "| Metric | Value |"
    $lines += "| --- | --- |"
    $lines += "| Total stale branches | $($staleBranches.Count) |"
    $lines += "| Repositories affected | $repoCount |"
    $lines += "| Average branch age | $(Format-HumanAge ((Get-Date).AddDays(-$avgAge))) |"
    $lines += "| Oldest branch age | $(Format-HumanAge ((Get-Date).AddDays(-$maxAge))) |"
    $lines += "| Newest stale branch age | $(Format-HumanAge ((Get-Date).AddDays(-$minAge))) |"

    $lines += ""
    $fossilEmoji = [System.Char]::ConvertFromUtf32(0x1FAA6)
    $lines += "> $fossilEmoji **The Fossil Award** goes to ``$($fossil.Branch)`` in ``$($fossil.Repository)`` — last touched **$(Format-HumanAge $fossil.CommitDate) ago** by $($fossil.Author). Pour one out."
    $lines += ""

    # Top 10 oldest stale branches
    $top10Oldest = $staleBranches | Sort-Object CommitDate | Select-Object -First 10

    $lines += "## $([System.Char]::ConvertFromUtf32(0x1F480)) Top 10 Oldest Stale Branches"
    $lines += ""
    $lines += "| Project | Repository | Branch | Author | Commit Date | Age | Commit |"
    $lines += "| --- | --- | --- | --- | --- | --- | --- |"

    foreach ($item in $top10Oldest) {
        $lines += "| {0} | {1} | {2} | {3} | {4} | {5} | [link]({6}) |" -f $item.Project, $item.Repository, $item.Branch, $item.Author, $item.CommitDate.ToString("dd MMM yyyy"), (Format-HumanAge $item.CommitDate), $item.CommitLink
    }

    # Top 10 repositories with most stale branches
    $top10Repos = $staleBranches | Group-Object Repository | Sort-Object Count -Descending | Select-Object -First 10

    $lines += ""
    $lines += "## $([System.Char]::ConvertFromUtf32(0x1F5C2)) Top 10 Repositories with Most Stale Branches"
    $lines += ""
    $lines += "| Repository | Stale Branch Count |"
    $lines += "| --- | --- |"

    foreach ($grp in $top10Repos) {
        $lines += "| {0} | {1} |" -f $grp.Name, $grp.Count
    }

    # Top 15 Hall of Shame — rank-based verdicts, last 5 get participation trophy
    $top15Hoarders = $staleBranches | Where-Object { $serviceAccounts -notcontains $_.Author } | Group-Object Author | Sort-Object Count -Descending | Select-Object -First 15

    $lines += ""
    $lines += "## $([System.Char]::ConvertFromUtf32(0x1F3C6)) Hall of Shame"
    $lines += ""
    $lines += "_These developers have committed crimes against cleanliness. They know what they did._"
    $lines += ""
    $lines += "| Rank | Author | Stale Branches | Verdict |"
    $lines += "| --- | --- | --- | --- |"

    $hoarderRank = 0
    foreach ($grp in $top15Hoarders) {
        $hoarderRank++
        $verdict = switch ($hoarderRank) {
            1  { "$([System.Char]::ConvertFromUtf32(0x1F451)) Supreme Neglector" }
            2  { "$([System.Char]::ConvertFromUtf32(0x1F948)) Distinguished Deserter" }
            3  { "$([System.Char]::ConvertFromUtf32(0x1F949)) Bronze Abandoner" }
            4  { "$([System.Char]::ConvertFromUtf32(0x1F30B)) Unstoppable Force of Neglect" }
            5  { "$([System.Char]::ConvertFromUtf32(0x1F9D1))$([char]0x200D)$([char]0x2696)$([char]0xFE0F) Under Investigation" }
            6  { "$([System.Char]::ConvertFromUtf32(0x1F4C9)) Statistically Concerning" }
            7  { "$([System.Char]::ConvertFromUtf32(0x1F4CE)) Like Clippy, But Worse" }
            8  { "$([System.Char]::ConvertFromUtf32(0x1F4E0)) Still Faxing It In" }
            9  { "$([System.Char]::ConvertFromUtf32(0x1F6D2)) Abandoned Cart Energy" }
            default { "$([System.Char]::ConvertFromUtf32(0x1F388)) Participation Trophy" }
        }
        $lines += "| {0} | {1} | {2} | {3} |" -f $hoarderRank, $grp.Name, $grp.Count, $verdict
    }

    # Cleanup commands per author
    $authorGroups = $staleBranches | Where-Object { $serviceAccounts -notcontains $_.Author } | Group-Object Author | Sort-Object Count -Descending

    $lines += ""
    $lines += "## $([System.Char]::ConvertFromUtf32(0x1F9F9)) Cleanup Commands"
    $lines += ""
    $lines += "_Run these commands to remove stale branches per author. Add ``-DryRun:`$false`` to actually delete._"
    $lines += ""

    foreach ($grp in $authorGroups) {
        $lines += "**$($grp.Name)** — $($grp.Count) stale branch(es):"
        $lines += ""
        $lines += '```powershell'
        $lines += ".\Remove-StaleBranches.ps1 -OrganizationUrl `"$OrganizationUrl`" -Project `"$Project`" -RepoPrefix `"$RepoPrefix`" -ThresholdMonths $ThresholdMonths -OwnerDisplayName `"$($grp.Name)`" -DeleteAll"
        $lines += '```'
        $lines += ""
    }
}

$lines | Set-Content -Path $outputPath -Encoding UTF8

Write-Host ""
Write-Host "Done! Found $($staleBranches.Count) stale branch(es)." -ForegroundColor Green
Write-Host "Report written to: $outputPath" -ForegroundColor Green
