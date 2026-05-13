<#
.SYNOPSIS
    Interactively deletes stale branches from Azure DevOps repositories.

.DESCRIPTION
    Scans repositories matching a given prefix for branches whose last commit is older
    than a configurable threshold. When -OwnerDisplayName is specified, only branches
    created by that owner are considered. When omitted, all stale branches are shown.
    Each stale branch prompts for confirmation before deletion, unless -DeleteAll is
    used (requires -OwnerDisplayName). Supports a dry-run mode (enabled by default)
    that simulates deletions without making changes. Branches named 'main' and 'master'
    are always skipped.

.EXAMPLE
    # Dry run (default) — see which of your branches would be deleted
    .\Remove-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org"

.EXAMPLE
    # Actually delete stale branches after confirmation prompts
    .\Remove-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -DryRun:$false

.EXAMPLE
    # Delete branches older than 12 months for a specific owner
    .\Remove-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -ThresholdMonths 12 -OwnerDisplayName "John Doe"

.EXAMPLE
    # Delete all stale branches for a specific owner without confirmation
    .\Remove-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -OwnerDisplayName "John Doe" -DeleteAll -DryRun:$false

.EXAMPLE
    # Target a different repo prefix and scan all projects
    .\Remove-StaleBranches.ps1 -OrganizationUrl "https://dev.azure.com/Org" -Project "" -RepoPrefix "MyApp." -DryRun:$false
#>
param(
    [string]$OrganizationUrl = "https://dev.azure.com/Org",

    [string]$Project = "Project",

    [string]$RepoPrefix = "",

    [int]$ThresholdMonths = 6,

    [string]$OwnerDisplayName,

    [switch]$DeleteAll,

    [switch]$DryRun = $False
)

if ($DeleteAll -and [string]::IsNullOrWhiteSpace($OwnerDisplayName)) {
    throw "-DeleteAll requires -OwnerDisplayName to be specified."
}

$accessToken = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query "accessToken" --output tsv
if ($null -eq $accessToken) {
    exit 1
}
$authHeader = "Bearer " + $accessToken
function Invoke-AzDoGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [hashtable]$Headers
    )

    return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -ErrorAction Stop
}

function Invoke-AzDoPost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [hashtable]$Headers
    )

    return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Post -Body $Body -ContentType "application/json" -ErrorAction Stop
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

function Get-OwnerDisplayName {
    param([string]$OverrideName, [string]$OrgUrl)

    if (-not [string]::IsNullOrWhiteSpace($OverrideName)) {
        return $OverrideName
    }

    $uri = [uri]$OrgUrl
    $orgName = $uri.AbsolutePath.Trim("/")
    if ([string]::IsNullOrWhiteSpace($orgName)) {
        throw "Unable to resolve org name from OrganizationUrl. Provide -OwnerDisplayName explicitly."
    }

    $profileUrl = "https://vssps.dev.azure.com/{0}/_apis/profile/profiles/me?api-version=7.1-preview.1" -f $orgName
    try {
        $profile = Invoke-AzDoGet -Url $profileUrl -Headers @{ Authorization = $authHeader }
        if (-not [string]::IsNullOrWhiteSpace($profile.displayName)) {
            return $profile.displayName
        }
    } catch {
        Write-Warning "Failed to resolve profile from $profileUrl. Provide -OwnerDisplayName explicitly."
    }

    $manual = Read-Host "Enter your Azure DevOps display name"
    if ([string]::IsNullOrWhiteSpace($manual)) {
        throw "Owner display name is required."
    }

    return $manual
}

function Should-DeleteBranch {
    param(
        [string]$ProjectName,
        [string]$RepoName,
        [string]$BranchName,
        [DateTime]$CommitDate,
        [string]$CreatorName
    )

    $ageDays = (Get-Date) - $CommitDate
    $prompt = "Delete remote branch '$BranchName' in $ProjectName/$($RepoName)? Last commit: {0:yyyy-MM-dd} (age {1} days). Creator: {2}. [Y/N]" -f $CommitDate, $ageDays.Days, $CreatorName
    while ($true) {
        $answer = Read-Host $prompt
        if ($answer -match "^[Yy]$") { return $true }
        if ($answer -match "^[Nn]$") { return $false }
        Write-Host "Please answer Y or N." -ForegroundColor Yellow
    }
}

function Remove-AzDoBranch {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$RepoId,
        [string]$BranchName,
        [string]$OldObjectId
    )

    $deleteUrl = "{0}/{1}/_apis/git/repositories/{2}/refs?api-version=7.1-preview.1" -f $OrgUrl, $ProjectName, $RepoId
    $body = ConvertTo-Json -Depth 5 -InputObject @(
        @{
            name        = "refs/heads/$BranchName"
            oldObjectId = $OldObjectId
            newObjectId = "0000000000000000000000000000000000000000"
        }
    )

    return Invoke-AzDoPost -Url $deleteUrl -Body $body -Headers @{ Authorization = $authHeader }
}

if (-not [string]::IsNullOrWhiteSpace($OwnerDisplayName)) {
    $ownerName = Get-OwnerDisplayName -OverrideName $OwnerDisplayName -OrgUrl $OrganizationUrl
    Write-Host "Filtering by owner display name: $ownerName" -ForegroundColor Gray
} else {
    $ownerName = $null
    Write-Host "No owner filter — all stale branches will be shown." -ForegroundColor Gray
}

$cutoffDate = (Get-Date).AddMonths(-1 * $ThresholdMonths)

Write-Host "Fetching projects..." -ForegroundColor Cyan
if ([string]::IsNullOrWhiteSpace($Project)) {
    $projects = Get-AzDoPaged ("{0}/_apis/projects?api-version=7.1-preview.4" -f $OrganizationUrl)
} else {
    $projects = @(@{ name = $Project })
}
Write-Host "Found $($projects.Count) project(s)." -ForegroundColor Gray

$deleted = 0
$skipped = 0
$staleMatches = 0

foreach ($projectItem in $projects) {
    $projectName = $projectItem.name

    Write-Host "[$projectName] Fetching repositories..." -ForegroundColor Cyan
    $reposUrl = "{0}/{1}/_apis/git/repositories?api-version=7.1-preview.1" -f $OrganizationUrl, $projectName
    $repos = @(Get-AzDoPaged $reposUrl)
    $matchingRepos = @($repos | Where-Object { $null -ne $_ -and $null -ne $_.name -and $_.name.StartsWith($RepoPrefix) -and $_.isDisabled -ne $true })
    Write-Host "[$projectName] Found $($matchingRepos.Count) matching repo(s)." -ForegroundColor Gray

    foreach ($repo in $matchingRepos) {
        Write-Host "[$projectName/$($repo.name)] Fetching branches..." -ForegroundColor DarkCyan
        $refsUrl = "{0}/{1}/_apis/git/repositories/{2}/refs?filter=heads/&api-version=7.1-preview.1" -f $OrganizationUrl, $projectName, $repo.id
        $refs = Get-AzDoPaged $refsUrl

        foreach ($ref in $refs) {
            $branchName = $ref.name -replace "^refs/heads/", ""
            if ($branchName -eq "main" -or $branchName -eq "master") {
                continue
            }
            $commitId = $ref.objectId
            $commitUrl = "{0}/{1}/_apis/git/repositories/{2}/commits/{3}?api-version=7.1-preview.1" -f $OrganizationUrl, $projectName, $repo.id, $commitId
            try {
                $commit = Invoke-AzDoGet -Url $commitUrl -Headers @{ Authorization = $authHeader }
            } catch {
                Write-Warning "Failed to get commit $commitId for branch $branchName in $($repo.name): $_"
                continue
            }

            $committerName = $commit.committer.name

            if ($null -ne $ownerName) {
                if ([string]::IsNullOrWhiteSpace($committerName)) {
                    continue
                }
                if ($committerName -ne $ownerName) {
                    continue
                }
            }

            $commitDate = [DateTime]$commit.committer.date
            if ($commitDate -ge $cutoffDate) {
                continue
            }

            $staleMatches++
            if ($DeleteAll) {
                $shouldDelete = $true
            } else {
                $shouldDelete = Should-DeleteBranch -ProjectName $projectName -RepoName $repo.name -BranchName $branchName -CommitDate $commitDate -CreatorName $committerName
            }
            if (-not $shouldDelete) {
                $skipped++
                continue
            }

            if ($DryRun) {
                Write-Host "DRY RUN: Would delete $projectName/$($repo.name)/$branchName" -ForegroundColor Yellow
                $deleted++
                continue
            }

            try {
                $null = Remove-AzDoBranch -OrgUrl $OrganizationUrl -ProjectName $projectName -RepoId $repo.id -BranchName $branchName -OldObjectId $commitId
                Write-Host "Deleted $projectName/$($repo.name)/$branchName" -ForegroundColor Green
                $deleted++
            } catch {
                Write-Warning "Failed to delete $projectName/$($repo.name)/$branchName : $_"
            }
        }
    }
}

Write-Host "" 
Write-Host "Done." -ForegroundColor Green
Write-Host "Stale branches matched: $staleMatches" -ForegroundColor Gray
Write-Host "Deleted: $deleted" -ForegroundColor Gray
Write-Host "Skipped: $skipped" -ForegroundColor Gray
