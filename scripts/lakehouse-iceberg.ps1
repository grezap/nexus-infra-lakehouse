#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster lakehouse-iceberg env -- Phase 0.L.2.

.DESCRIPTION
  Drives terraform/envs/lakehouse-iceberg/ -- the Iceberg REST catalog (Project
  Nessie, 2 HA instances) + its dedicated PostgreSQL master-replica metadata
  store (keepalived VRRP VIP iceberg-db.nexus.lab .151). Warehouse data lives in
  MinIO (0.L.1 must be up).

  Pre-flight (see docs/handbook.md):
    1. nexus-infra-vmware foundation env applied (reservations :A0-:A3;
       iceberg.nexus.lab -> .147/.148 + iceberg-db.nexus.lab -> VIP .151).
    2. nexus-infra-vmware security env applied (iceberg-server PKI role + 4
       AppRole sidecars + KV seeds nexus/lakehouse/iceberg/*).
    3. packer build packer/lakehouse-iceberg-pg-node + packer/lakehouse-iceberg-rest-node.
    4. MinIO (0.L.1) running (the s3://warehouse).

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate
.PARAMETER Vars
  "key=value" pairs forwarded as -var flags.
.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.L.2.ps1.

.EXAMPLE
  pwsh -File scripts\lakehouse-iceberg.ps1 cycle
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('apply', 'destroy', 'smoke', 'cycle', 'plan', 'validate')]
    [string]$Verb,

    [string[]]$Vars = @(),

    [hashtable]$SmokeArgs = @{}
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$envDir    = Join-Path $repoRoot 'terraform\envs\lakehouse-iceberg'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.L.2.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[lakehouse-iceberg] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
        Push-Location $envDir
        try {
            & terraform init
            if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$TfArgs)
    Initialize-TerraformIfNeeded
    Push-Location $envDir
    try {
        & terraform @TfArgs
        if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Get-VarFlags {
    $flags = @()
    foreach ($v in $Vars) {
        foreach ($piece in ($v -split ',')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $flags += @('-var', $trimmed) }
        }
    }
    return $flags
}

function Invoke-Apply {
    Write-Step 'terraform apply -auto-approve  (envs/lakehouse-iceberg)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/lakehouse-iceberg)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.L.2.ps1  (Iceberg catalog gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/lakehouse-iceberg)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/lakehouse-iceberg)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/lakehouse-iceberg)'
    Invoke-Terraform @('validate')
}

switch ($Verb) {
    'apply'    { Invoke-Apply }
    'destroy'  { Invoke-Destroy }
    'smoke'    { Invoke-Smoke }
    'plan'     { Invoke-Plan }
    'validate' { Invoke-Validate }
    'cycle' {
        Invoke-Destroy
        Invoke-Apply
        Invoke-Smoke
    }
}

Write-Host ''
Write-Host "lakehouse-iceberg $Verb complete" -ForegroundColor Green
