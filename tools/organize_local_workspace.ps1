[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ArchiveRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '_local\archive'))

function Assert-UnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes allowed root '$Root': $resolved"
    }
    return $resolved
}

function Convert-ToRelativePath {
    param([Parameter(Mandatory = $true)][string]$FullName)

    $fullPath = Assert-UnderRoot -Path $FullName -Root $ProjectRoot
    return $fullPath.Substring($ProjectRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
}

function Test-GitTracked {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    $tracked = @(& git -C $ProjectRoot ls-files -- $normalized "$normalized/**")
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed while checking: $normalized"
    }
    return $tracked.Count -gt 0
}

function Assert-NotFormalDeliverable {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    $protected = @(
        'artifacts/system_wrapper_dma_batch.bit',
        'artifacts/system_wrapper_dma_batch.xsa',
        'reports/dma_batch/board-results.txt',
        'reports/Z15_FPGA项目验收与测试报告_20260811_DMA最终版.docx'
    )
    if ($protected -contains $normalized) {
        throw "Refusing to archive formal deliverable: $normalized"
    }
}

function Move-ArchiveItem {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/').TrimStart('/')
    Assert-NotFormalDeliverable -RelativePath $normalized

    $source = Assert-UnderRoot -Path (Join-Path $ProjectRoot $normalized) -Root $ProjectRoot
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Verbose "SKIP missing: $normalized"
        return
    }
    if (Test-GitTracked -RelativePath $normalized) {
        throw "Refusing to archive Git-tracked content: $normalized"
    }

    $item = Get-Item -LiteralPath $source -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to archive reparse point: $normalized"
    }

    $destination = Assert-UnderRoot -Path (Join-Path $ArchiveRoot $normalized) -Root $ArchiveRoot
    if (Test-Path -LiteralPath $destination) {
        throw "Archive destination already exists: $destination"
    }

    if (-not $Apply) {
        Write-Output "PLAN MOVE: $normalized -> _local/archive/$normalized"
        return
    }

    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Move-Item -LiteralPath $source -Destination $destination
    Write-Output "MOVED: $normalized -> _local/archive/$normalized"
}

$archiveItems = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$fixedItems = @(
    '.codex_qa',
    '.docx_review_fgpa1',
    'backup_before_codex_20260723_112014',
    'component.xml',
    'constraints/z15_board_pins.xdc',
    'xgui',
    'FPGA/add_axi_debug_ila.tcl',
    'FPGA/apply_admet_timing_fix.tcl',
    'FPGA/board_init_debug.tcl',
    'FPGA/board_mrd_once.tcl',
    'FPGA/capture_axi_read.tcl',
    'FPGA/debug_dma_hang.tcl',
    'FPGA/export_platform_nobit.tcl',
    'FPGA/fix_aux_reset_and_rebuild.tcl',
    'FPGA/inspect_dma_clock_pins.tcl',
    'FPGA/inspect_dma_reset_net.tcl',
    'FPGA/probe_axi_dwidth_converter.tcl',
    'FPGA/probe_smartconnect_properties.tcl',
    'FPGA/query_board_ila.tcl',
    'FPGA/query_system_ila.tcl',
    'FPGA/rebuild_admet_parallel_ila.tcl',
    'FPGA/rebuild_clean_system.tcl',
    'FPGA/rebuild_performance_targets_ila.tcl',
    'FPGA/recover_dap.tcl',
    'FPGA/recover_dap_after_powercycle.tcl',
    'FPGA/recover_ps_via_dap_reset.tcl',
    'FPGA/replace_interconnect_smartconnect.tcl',
    'FPGA/replace_smartconnect_custom_bridge.tcl',
    'FPGA/reprogram_recover.tcl',
    'FPGA/rerun_impl_admet_parallel_performance.tcl',
    'FPGA/run_accelerator_selftest.tcl',
    'FPGA/run_dma_batch_debug.tcl',
    'FPGA/tight_setup_hold_pins.txt',
    'artifacts/candidate_dma_batch',
    'artifacts/experimental_failed',
    'artifacts/ps7_init.c',
    'artifacts/ps7_init.h',
    'artifacts/ps7_init.html',
    'artifacts/ps7_init.tcl',
    'artifacts/ps7_init_gpl.c',
    'artifacts/ps7_init_gpl.h',
    'artifacts/system_before_aux_reset_fix.bd',
    'artifacts/system_before_custom_bridge.bd',
    'artifacts/system_wrapper.bit',
    'artifacts/system_wrapper.xsa',
    'artifacts/system_wrapper_before_xdc_cleanup.bit',
    'artifacts/system_wrapper_custom_bridge_ila.bit',
    'artifacts/system_wrapper_custom_bridge_ila.ltx',
    'artifacts/system_wrapper_debug_ila.bit',
    'artifacts/system_wrapper_debug_ila.ltx',
    'artifacts/system_wrapper_nobit.xsa',
    'artifacts/system_wrapper_smartconnect_ila.bit',
    'artifacts/system_wrapper_smartconnect_ila.ltx',
    'reports/FGPA_1_contents.txt',
    'reports/Z15_report_render',
    'reports/accelerator_utilization_hierarchical.rpt',
    'reports/axi_read_capture.csv',
    'reports/dma_batch/board-profile.txt',
    'reports/dma_batch/board-results-final-candidate.txt',
    'reports/dma_batch/board-single-n64-profile.txt',
    'reports/dma_batch/experimental',
    'reports/dma_batch/uart_capture.pid',
    'reports/docx_render_dma_final',
    'reports/docx_render_dma_final_v2',
    'reports/docx_render_dma_final_v3',
    'reports/experimental_failed',
    'reports/performance_measured_20260809.md',
    'reports/project_status_20260809.md',
    'software/baremetal/src/main.c',
    'software/create_vitis_workspace.tcl',
    'tools/create_acceptance_report.py',
    'tools/inspect_challenge_pdf.py',
    'tools/render_docx_with_word.ps1',
    'tools/update_acceptance_report_final.py'
)
foreach ($item in $fixedItems) {
    [void]$archiveItems.Add($item)
}

$rootPatterns = @('vivado*.log', 'vivado*.jou')
foreach ($pattern in $rootPatterns) {
    Get-ChildItem -LiteralPath $ProjectRoot -Filter $pattern -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$archiveItems.Add((Convert-ToRelativePath -FullName $_.FullName)) }
}

$reportsRoot = Join-Path $ProjectRoot 'reports'
$reportPatterns = @(
    '*20260809*',
    '*_structure.txt',
    '*_structural_qa.txt',
    'drc*.rpt',
    'timing_summary*.rpt',
    'utilization*.rpt',
    'worst_setup_paths*.rpt'
)
foreach ($pattern in $reportPatterns) {
    Get-ChildItem -LiteralPath $reportsRoot -Filter $pattern -Force -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$archiveItems.Add((Convert-ToRelativePath -FullName $_.FullName)) }
}

foreach ($relativePath in ($archiveItems | Sort-Object)) {
    Move-ArchiveItem -RelativePath $relativePath
}

if ($Apply) {
    Write-Output "Archive applied. Active Vivado/Vitis workspaces were not included in the archive list."
} else {
    Write-Output 'Dry run only. Re-run with -Apply after reviewing the list.'
}
