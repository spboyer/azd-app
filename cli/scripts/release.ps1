#!/usr/bin/env pwsh
#Requires -Version 7.4
<#
.SYNOPSIS
    Create a new release draft for azd-app CLI
.DESCRIPTION
    This script triggers the GitHub Actions workflow to create a draft release.
    After the workflow completes, you can review and publish the release in GitHub.
.PARAMETER Version
    The semantic version number (e.g., 1.2.3). If not specified, prompts for bump type.
.PARAMETER BumpType
    Type of version bump: Major, Minor, or Patch (default: Patch)
.PARAMETER DryRun
    Show what would happen without actually triggering the workflow
.EXAMPLE
    .\release.ps1
    Prompts to select version bump type based on current version
.EXAMPLE
    .\release.ps1 -BumpType Minor
    Automatically bumps the minor version
.EXAMPLE
    .\release.ps1 -Version 1.2.3
    Creates a draft release for version 1.2.3
.EXAMPLE
    .\release.ps1 -Version 1.2.3 -DryRun
    Shows what would happen without triggering the workflow
#>

param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d+\.\d+\.\d+$', ErrorMessage = "Version must be in format X.Y.Z (e.g., 1.2.3)")]
    [string]$Version,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Major', 'Minor', 'Patch')]
    [string]$BumpType,
    
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get script directory and cli root (parent of scripts directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cliRoot = Split-Path -Parent $scriptDir

# Function to update changelog with new version
function Update-Changelog {
    param(
        [string]$Version,
        [string]$Date
    )
    
    $changelogPath = Join-Path $cliRoot "CHANGELOG.md"
    if (-not (Test-Path $changelogPath)) {
        Write-Warning "CHANGELOG.md not found at $changelogPath, skipping changelog update"
        return
    }
    
    $content = Get-Content $changelogPath -Raw
    
    # Check if there's an [Unreleased] section with content
    if ($content -notmatch '## \[Unreleased\]') {
        Write-Warning "No [Unreleased] section found in CHANGELOG.md"
        return
    }
    
    # Replace [Unreleased] with the version and date, and add a new [Unreleased] section
    $newContent = $content -replace '## \[Unreleased\]', "## [Unreleased]`n`n## [$Version] - $Date"
    
    # Update the comparison links at the bottom
    # Find existing version comparison links pattern
    if ($newContent -match '\[Unreleased\]:\s*https://github\.com/([^/]+)/([^/]+)/compare/([^\.]+)\.\.\.HEAD') {
        $owner = $Matches[1]
        $repo = $Matches[2]
        $lastTag = $Matches[3]
        
        # Update Unreleased link to compare from new version
        $newContent = $newContent -replace '\[Unreleased\]:\s*https://[^\n]+', "[Unreleased]: https://github.com/$owner/$repo/compare/azd-app-cli-v$Version...HEAD"
        
        # Add new version comparison link (insert before existing version links)
        $versionLink = "[$Version]: https://github.com/$owner/$repo/releases/tag/azd-app-cli-v$Version"
        $newContent = $newContent -replace '(\[Unreleased\]:[^\n]+\n)', "`$1$versionLink`n"
    }
    
    Set-Content -Path $changelogPath -Value $newContent -NoNewline
    Write-Host "✅ Updated CHANGELOG.md" -ForegroundColor Green
}

# Function to extract changelog notes for a specific version
function Get-ChangelogNotes {
    param([string]$Version)
    
    $changelogPath = Join-Path $cliRoot "CHANGELOG.md"
    if (-not (Test-Path $changelogPath)) {
        return "No changelog found."
    }
    
    $content = Get-Content $changelogPath -Raw
    
    # Match the version section
    $pattern = "## \[$Version\][^\n]*\n(.*?)(?=\n## \[|$)"
    if ($content -match $pattern) {
        return $Matches[1].Trim()
    }
    
    return "See CHANGELOG.md for details."
}

# Function to get the last released version from git tags
function Get-CurrentVersion {
    # Use latest git tag as the source of truth for releases
    $latestTag = git tag --list "azd-app-cli-v*" --sort=-version:refname | Select-Object -First 1
    if ($latestTag -and $latestTag -match '^azd-app-cli-v(\d+\.\d+\.\d+)$') {
        return $Matches[1]
    }
    
    # If no tags exist, check version.txt as fallback
    $versionFile = Join-Path $cliRoot "version.txt"
    if (Test-Path $versionFile) {
        $versionContent = (Get-Content $versionFile -Raw).Trim()
        if ($versionContent -match '^\d+\.\d+\.\d+$') {
            return $versionContent
        }
    }
    
    # Default to 0.0.0 if nothing found
    return "0.0.0"
}

# Function to bump version
function Get-BumpedVersion {
    param(
        [string]$CurrentVersion,
        [string]$BumpType
    )
    
    if ($CurrentVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        throw "Invalid version format: $CurrentVersion"
    }
    
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = [int]$Matches[3]
    
    switch ($BumpType) {
        'Major' { return "$($major + 1).0.0" }
        'Minor' { return "$major.$($minor + 1).0" }
        'Patch' { return "$major.$minor.$($patch + 1)" }
    }
}

# If version not specified, determine it automatically
if (-not $Version) {
    $currentVersion = Get-CurrentVersion
    Write-Host "Current version: $currentVersion" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $BumpType) {
        Write-Host "Select version bump type:" -ForegroundColor Yellow
        Write-Host "  1. Patch (bug fixes)       → $(Get-BumpedVersion $currentVersion 'Patch')" -ForegroundColor Gray
        Write-Host "  2. Minor (new features)    → $(Get-BumpedVersion $currentVersion 'Minor')" -ForegroundColor Gray
        Write-Host "  3. Major (breaking changes)→ $(Get-BumpedVersion $currentVersion 'Major')" -ForegroundColor Gray
        Write-Host "  4. Custom version" -ForegroundColor Gray
        Write-Host ""
        
        $choice = Read-Host "Enter choice (1-4)"
        
        switch ($choice) {
            '1' { $BumpType = 'Patch' }
            '2' { $BumpType = 'Minor' }
            '3' { $BumpType = 'Major' }
            '4' {
                $Version = Read-Host "Enter custom version (X.Y.Z)"
                if ($Version -notmatch '^\d+\.\d+\.\d+$') {
                    Write-Error "Invalid version format. Must be X.Y.Z (e.g., 1.2.3)"
                    exit 1
                }
            }
            default {
                Write-Error "Invalid choice"
                exit 1
            }
        }
    }
    
    if (-not $Version) {
        $Version = Get-BumpedVersion $currentVersion $BumpType
        Write-Host "New version: $Version" -ForegroundColor Green
    }
}

# Check if gh CLI is installed
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) is not installed. Install from: https://cli.github.com/"
    exit 1
}

# Check if authenticated
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not authenticated with GitHub. Run: gh auth login"
    exit 1
}

# Get current directory and ensure we're in the repo
$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    Write-Error "Not in a git repository"
    exit 1
}

# Check if on main branch
$currentBranch = git branch --show-current
if ($currentBranch -ne 'main') {
    Write-Warning "⚠️  You're on branch '$currentBranch', not 'main'"
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne 'y') {
        Write-Host "Aborted."
        exit 0
    }
}

# Check for uncommitted changes
$gitStatus = git status --porcelain
if ($gitStatus) {
    Write-Warning "⚠️  You have uncommitted changes:"
    git status --short
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne 'y') {
        Write-Host "Aborted."
        exit 0
    }
}

# Check if tag already exists
$tagExists = git tag -l "azd-app-cli-v$Version"
if ($tagExists) {
    Write-Error "❌ Tag azd-app-cli-v$Version already exists. Choose a different version or delete the tag first."
    exit 1
}

# Check if release already exists on GitHub
gh release view "azd-app-cli-v$Version" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Error "❌ Release azd-app-cli-v$Version already exists on GitHub."
    exit 1
}

Write-Host ""
Write-Host "🚀 Release Plan" -ForegroundColor Cyan
Write-Host "═══════════════" -ForegroundColor Cyan
Write-Host "Version:        $Version" -ForegroundColor White
Write-Host "Tag:            azd-app-cli-v$Version" -ForegroundColor White
Write-Host "Branch:         $currentBranch" -ForegroundColor White
Write-Host "Repository:     $(gh repo view --json nameWithOwner -q .nameWithOwner)" -ForegroundColor White
Write-Host ""
Write-Host "This will:" -ForegroundColor Yellow
Write-Host "  1. Update CHANGELOG.md [Unreleased] → [$Version] with today's date" -ForegroundColor Gray
Write-Host "  2. Update version.txt to $Version" -ForegroundColor Gray
Write-Host "  3. Commit and push the changelog and version changes" -ForegroundColor Gray
Write-Host "  4. Trigger GitHub Actions workflow to:" -ForegroundColor Gray
Write-Host "     • Build binaries for all platforms" -ForegroundColor DarkGray
Write-Host "     • Update registry.json with checksums and URLs" -ForegroundColor DarkGray
Write-Host "     • Create tag azd-app-cli-v$Version" -ForegroundColor DarkGray
Write-Host "     • Create a DRAFT release on GitHub" -ForegroundColor DarkGray
Write-Host ""
Write-Host "After completion, you can:" -ForegroundColor Green
Write-Host "  • Review the draft release at:" -ForegroundColor Gray
Write-Host "    https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases" -ForegroundColor Blue
Write-Host "  • Click 'Publish release' to make it official" -ForegroundColor Gray
Write-Host ""

if ($DryRun) {
    Write-Host "🔍 DRY RUN - No actions will be taken" -ForegroundColor Magenta
    exit 0
}

$confirm = Read-Host "Proceed with creating draft release? (y/N)"
if ($confirm -ne 'y') {
    Write-Host "Aborted."
    exit 0
}

Write-Host ""
Write-Host "📝 Updating CHANGELOG.md..." -ForegroundColor Yellow
$today = Get-Date -Format "yyyy-MM-dd"
Update-Changelog -Version $Version -Date $today

Write-Host ""
Write-Host "📝 Committing changelog and version updates..." -ForegroundColor Yellow
try {
    # Stage the changelog if it was updated
    $changelogPath = Join-Path $cliRoot "CHANGELOG.md"
    if (Test-Path $changelogPath) {
        git add $changelogPath
    }
    
    # Commit the changes (both changelog and version.txt will be committed by workflow, but we do it here for local state)
    $hasChanges = git diff --cached --quiet; $LASTEXITCODE -ne 0
    if ($hasChanges) {
        git commit -m "chore: prepare release $Version"
        git push
        Write-Host "✅ Changes committed and pushed" -ForegroundColor Green
    } else {
        Write-Host "ℹ️  No changelog changes to commit" -ForegroundColor Gray
    }
} catch {
    Write-Warning "Failed to commit changelog: $_"
    Write-Host "Continuing with release process..." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "⏳ Triggering release workflow..." -ForegroundColor Yellow

try {
    # Trigger the workflow
    gh workflow run release-draft.yml -f "version=$Version"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to trigger workflow"
        exit 1
    }
    
    Write-Host "✅ Workflow triggered successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 Monitor progress:" -ForegroundColor Cyan
    Write-Host "   gh run watch" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Or view in browser:" -ForegroundColor Cyan
    Write-Host "   gh run list --workflow=release-draft.yml --limit 1" -ForegroundColor Blue
    Write-Host ""
    Write-Host "Once complete, review and publish at:" -ForegroundColor Cyan
    Write-Host "   https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases" -ForegroundColor Blue
    
} catch {
    Write-Error "Failed to trigger release: $_"
    exit 1
}
