#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster lakehouse-minio env -- Phase 0.L.1.

.DESCRIPTION
  Drives terraform/envs/lakehouse-minio/ (4 MinIO nodes, distributed erasure-
  coded) on the per-cluster state + per-engine template canon. MinIO is the
  storage foundation for 0.L.2 (Iceberg warehouse), 0.L.3 (Spark), and 0.L.5
  (StarRocks shared-data).

  Pre-flight (see docs/handbook.md §1):
    1. nexus-infra-vmware foundation env applied (dhcp-host reservations for the
       4 MinIO MACs :9A-:9D at .141-.144 + round-robin minio.nexus.lab).
    2. nexus-infra-vmware security env applied (minio-server PKI role + 4 AppRole
       sidecars + KV seeds at nexus/lakehouse/minio/*).
    3. packer build packer/lakehouse-minio-node.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate

.PARAMETER Vars
  "key=value" pairs forwarded as -var flags (full override set per apply).

.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.L.1.ps1.

.EXAMPLE
  pwsh -File scripts\lakehouse-minio.ps1 cycle
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
$envDir    = Join-Path $repoRoot 'terraform\envs\lakehouse-minio'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.L.1.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[lakehouse-minio] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/lakehouse-minio)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/lakehouse-minio)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.L.1.ps1  (MinIO cluster gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/lakehouse-minio)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/lakehouse-minio)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/lakehouse-minio)'
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
Write-Host "lakehouse-minio $Verb complete" -ForegroundColor Green
