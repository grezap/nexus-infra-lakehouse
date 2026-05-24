#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Operator wrapper for the per-cluster lakehouse-spark env -- Phase 0.L.3.

.DESCRIPTION
  Drives terraform/envs/lakehouse-spark/ -- the Apache Spark standalone HA cluster
  (2 masters + 3 workers) coordinated by a dedicated 3-node Apache ZooKeeper
  ensemble (recoveryMode=ZOOKEEPER; no master VIP -- the multi-master URL +
  ZK election is the front door). Warehouse data lives in MinIO (0.L.1); tables
  go through the Iceberg REST catalog (Nessie, 0.L.2).

  Pre-flight (see docs/handbook.md):
    1. nexus-infra-vmware foundation env applied (reservations :AA-:AE;
       spark-master.nexus.lab -> .140/.153).
    2. nexus-infra-vmware security env applied (spark-server PKI role + 5 AppRole
       sidecars + KV seed nexus/lakehouse/spark/auth-secret).
    3. packer build packer/lakehouse-spark-node + packer/lakehouse-zookeeper-node.
    4. MinIO (0.L.1) + Iceberg catalog (0.L.2) running.

.PARAMETER Verb
  apply | destroy | smoke | cycle | plan | validate
.PARAMETER Vars
  "key=value" pairs forwarded as -var flags.
.PARAMETER SmokeArgs
  Hashtable forwarded to scripts/smoke-0.L.3.ps1.

.EXAMPLE
  pwsh -File scripts\lakehouse-spark.ps1 cycle
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
$envDir    = Join-Path $repoRoot 'terraform\envs\lakehouse-spark'
$smokePath = Join-Path $repoRoot 'scripts\smoke-0.L.3.ps1'

function Write-Step([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Initialize-TerraformIfNeeded {
    if (-not (Test-Path (Join-Path $envDir '.terraform'))) {
        Write-Host "[lakehouse-spark] .terraform/ missing -- running ``terraform init``..." -ForegroundColor Yellow
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
    Write-Step 'terraform apply -auto-approve  (envs/lakehouse-spark)'
    $argv = @('apply', '-auto-approve')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Destroy {
    Write-Step 'terraform destroy -auto-approve  (envs/lakehouse-spark)'
    Invoke-Terraform @('destroy', '-auto-approve')
}

function Invoke-Smoke {
    Write-Step 'pwsh -File smoke-0.L.3.ps1  (Spark HA cluster gate)'
    if (-not (Test-Path $smokePath)) { throw "smoke script not found: $smokePath" }
    & pwsh -NoProfile -File $smokePath @SmokeArgs
    if ($LASTEXITCODE -ne 0) { throw "smoke gate failed (exit $LASTEXITCODE)" }
}

function Invoke-Plan {
    Write-Step 'terraform plan  (envs/lakehouse-spark)'
    $argv = @('plan')
    $varFlags = Get-VarFlags
    if ($varFlags.Count -gt 0) { $argv += $varFlags }
    Invoke-Terraform $argv
}

function Invoke-Validate {
    Write-Step 'terraform fmt -check -recursive  (envs/lakehouse-spark)'
    Invoke-Terraform @('fmt', '-check', '-recursive')
    Write-Step 'terraform validate  (envs/lakehouse-spark)'
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
Write-Host "lakehouse-spark $Verb complete" -ForegroundColor Green
