# FPGA Project Organization and Main-Branch Publish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 整理 `D:\FPGA`，本地保留 Vivado/Vitis 生成目录但排除 GitHub，归档零散历史文件，补齐可复现资料，并直接推送到远端 `main`。

**Architecture:** 活跃工具目录保持原位，通过 `.gitignore` 建立发布边界；一个默认 dry-run 的 PowerShell 脚本把明确列出的历史/调试文件移动到 `_local/archive/<原相对路径>`。GitHub 只接收源码、工程入口、正式产物、最终证据和文档。

**Tech Stack:** Git、PowerShell 5.1、Vivado/Vitis 2019.2、Python、Icarus Verilog、GitHub CLI。

## Global Constraints

- 不删除或移动 `.Xil/`、`FPGA/FPGA.cache/`、`FPGA/FPGA.hw/`、`FPGA/FPGA.ip_user_files/`、`FPGA/FPGA.runs/`、`FPGA/FPGA.sim/`、生成的 BD 子目录和 `vitis_workspace/`。
- 不覆盖 `_local/archive/` 中已存在的同名文件。
- 正式 bit/XSA、正式板测日志和最终 Word 报告的 SHA-256 必须保持不变。
- 仅允许直接推送 `main`；用户已明确授权，不创建发布分支，不强推。
- 保留并恢复当前被删除标记的两个 `.xci` 和 `FPGA/update_project.tcl`。

---

### Task 1: 建立 Git 忽略边界并恢复工程入口

**Files:**
- Modify: `.gitignore`
- Restore: `FPGA/FPGA.srcs/sources_1/ip/blk_mem_gen_0/blk_mem_gen_0.xci`
- Restore: `FPGA/FPGA.srcs/sources_1/ip/div_gen_0/div_gen_0.xci`
- Restore: `FPGA/update_project.tcl`

**Interfaces:**
- Consumes: 当前 Vivado/Vitis 目录结构。
- Produces: `git check-ignore` 可验证的本地生成文件发布边界。

- [ ] **Step 1: 记录忽略规则的失败基线**

Run:

```powershell
git check-ignore .Xil vitis_workspace FPGA/FPGA.srcs/sources_1/bd/system/ip
```

Expected: 至少 `vitis_workspace` 与生成 BD 目录没有全部命中。

- [ ] **Step 2: 扩充 `.gitignore`**

添加以下规则，同时保留现有 XCI 例外：

```gitignore
# Local organization archive
_local/

# Xilinx local state and generated workspaces
.Xil/
FPGA/.Xil/
vitis_workspace/
FPGA/FPGA.cache/
FPGA/FPGA.hw/
FPGA/FPGA.ip_user_files/
FPGA/FPGA.runs/
FPGA/FPGA.sim/
FPGA/FPGA.srcs/sources_1/bd/mref/
FPGA/FPGA.srcs/sources_1/bd/system/hdl/
FPGA/FPGA.srcs/sources_1/bd/system/hw_handoff/
FPGA/FPGA.srcs/sources_1/bd/system/ip/
FPGA/FPGA.srcs/sources_1/bd/system/ipshared/
FPGA/FPGA.srcs/sources_1/bd/system/sim/
FPGA/FPGA.srcs/sources_1/bd/system/synth/
FPGA/FPGA.srcs/sources_1/bd/system/ui/
FPGA/FPGA.srcs/sources_1/bd/system/*.bxml
FPGA/FPGA.srcs/sources_1/bd/system/*_ooc.xdc

# Loose tool/session output
.codex_qa/
.docx_review_*/
vivado*.log
vivado*.jou
*.pid
```

- [ ] **Step 3: 恢复已删除标记的工程文件**

Run:

```powershell
git restore -- FPGA/FPGA.srcs/sources_1/ip/blk_mem_gen_0/blk_mem_gen_0.xci FPGA/FPGA.srcs/sources_1/ip/div_gen_0/div_gen_0.xci FPGA/update_project.tcl
```

Expected: `git status --short` 不再显示这三个 `D`。

- [ ] **Step 4: 验证忽略边界**

Run:

```powershell
git check-ignore -v .Xil vitis_workspace FPGA/FPGA.runs FPGA/FPGA.srcs/sources_1/bd/system/ip
```

Expected: 四个路径全部由 `.gitignore` 命中。

- [ ] **Step 5: 提交忽略边界**

```powershell
git add .gitignore
git commit -m "chore: define local Xilinx workspace boundaries"
```

---

### Task 2: 创建安全的本地归档脚本并整理零散文件

**Files:**
- Create: `tools/organize_local_workspace.ps1`
- Create locally: `_local/archive/`（被忽略）

**Interfaces:**
- Consumes: 明确的文件/目录相对路径和可选 `-Apply` 开关。
- Produces: dry-run 清单；应用后把源移动到 `_local/archive/<原相对路径>`。

- [ ] **Step 1: 编写归档脚本的安全检查**

脚本必须实现：

```powershell
param([switch]$Apply)
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ArchiveRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '_local\archive'))

function Assert-UnderRoot([string]$Path, [string]$Root) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = $Root.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes project root: $resolved"
    }
    return $resolved
}
```

移动函数必须拒绝覆盖目标；默认只输出 `PLAN MOVE`，仅在 `-Apply` 时调用 `Move-Item -LiteralPath`。

- [ ] **Step 2: 固化归档清单**

清单包含下列相对路径：

```text
.codex_qa
.docx_review_fgpa1
backup_before_codex_20260723_112014
component.xml
xgui
FPGA/add_axi_debug_ila.tcl
FPGA/apply_admet_timing_fix.tcl
FPGA/board_init_debug.tcl
FPGA/board_mrd_once.tcl
FPGA/capture_axi_read.tcl
FPGA/debug_dma_hang.tcl
FPGA/export_platform_nobit.tcl
FPGA/fix_aux_reset_and_rebuild.tcl
FPGA/inspect_dma_clock_pins.tcl
FPGA/inspect_dma_reset_net.tcl
FPGA/probe_axi_dwidth_converter.tcl
FPGA/probe_smartconnect_properties.tcl
FPGA/query_board_ila.tcl
FPGA/query_system_ila.tcl
FPGA/rebuild_admet_parallel_ila.tcl
FPGA/rebuild_clean_system.tcl
FPGA/rebuild_performance_targets_ila.tcl
FPGA/recover_dap.tcl
FPGA/recover_dap_after_powercycle.tcl
FPGA/recover_ps_via_dap_reset.tcl
FPGA/replace_interconnect_smartconnect.tcl
FPGA/replace_smartconnect_custom_bridge.tcl
FPGA/reprogram_recover.tcl
FPGA/rerun_impl_admet_parallel_performance.tcl
FPGA/run_accelerator_selftest.tcl
FPGA/run_dma_batch_debug.tcl
FPGA/tight_setup_hold_pins.txt
artifacts/candidate_dma_batch
artifacts/experimental_failed
artifacts/ps7_init.c
artifacts/ps7_init.h
artifacts/ps7_init.html
artifacts/ps7_init.tcl
artifacts/ps7_init_gpl.c
artifacts/ps7_init_gpl.h
artifacts/system_before_aux_reset_fix.bd
artifacts/system_before_custom_bridge.bd
artifacts/system_wrapper.bit
artifacts/system_wrapper.xsa
artifacts/system_wrapper_before_xdc_cleanup.bit
artifacts/system_wrapper_custom_bridge_ila.bit
artifacts/system_wrapper_custom_bridge_ila.ltx
artifacts/system_wrapper_debug_ila.bit
artifacts/system_wrapper_debug_ila.ltx
artifacts/system_wrapper_nobit.xsa
artifacts/system_wrapper_smartconnect_ila.bit
artifacts/system_wrapper_smartconnect_ila.ltx
reports/FGPA_1_contents.txt
reports/Z15_report_render
reports/accelerator_utilization_hierarchical.rpt
reports/axi_read_capture.csv
reports/dma_batch/board-profile.txt
reports/dma_batch/board-results-final-candidate.txt
reports/dma_batch/board-single-n64-profile.txt
reports/dma_batch/experimental
reports/dma_batch/uart_capture.pid
reports/docx_render_dma_final
reports/docx_render_dma_final_v2
reports/docx_render_dma_final_v3
reports/experimental_failed
reports/performance_measured_20260809.md
reports/project_status_20260809.md
```

另外按文件名匹配归档根目录 `vivado*.log/jou`，以及 `reports/` 根下除正式 Word 外的旧日期 `20260809` 文档和松散 `drc/timing_summary/utilization/worst_setup_paths` 报告。

- [ ] **Step 3: 运行 dry-run 并检查正式产物未出现**

Run:

```powershell
New-Item -ItemType Directory -Force _local | Out-Null
& tools/organize_local_workspace.ps1 | Tee-Object _local/organization-dry-run.txt
Select-String _local/organization-dry-run.txt -Pattern 'system_wrapper_dma_batch|board-results.txt|DMA最终版'
```

Expected: dry-run 有移动条目；正式 bit/XSA、正式板测日志和最终 Word 不在清单中。

- [ ] **Step 4: 应用归档**

Run:

```powershell
& tools/organize_local_workspace.ps1 -Apply
```

Expected: 列出的现存路径移动到 `_local/archive/`；Vivado/Vitis 活跃生成目录仍在原位置。

- [ ] **Step 5: 提交可复用归档脚本**

```powershell
git add tools/organize_local_workspace.ps1
git commit -m "chore: add safe local workspace organizer"
```

---

### Task 3: 归类需求、模板和可复现源码

**Files:**
- Move: `FGPA(1).docx` → `docs/requirements/FGPA(1).docx`
- Move: `reports/Z15_FPGA项目验收与测试报告.docx` → `docs/templates/Z15_FPGA项目验收与测试报告.docx`
- Add: `constraints/z15_board_pins.xdc`
- Add: `software/baremetal/README.md`
- Add: `software/baremetal/src/main.c`
- Add: `software/create_vitis_workspace.tcl`
- Add: `software/rebuild_dma_vitis_app.tcl`
- Add: `tools/create_acceptance_report.py`
- Add: `tools/export_docx_pdf_word.ps1`
- Add: `tools/extract_docx_structure.py`
- Add: `tools/render_docx_with_word.ps1`
- Add: `tools/update_acceptance_report_final.py`
- Modify: `tools/update_acceptance_report_dma_final.py`
- Modify: `tools/create_acceptance_report.py`

**Interfaces:**
- Consumes: 原始项目目的文档、基础验收模板和现有生成工具。
- Produces: 职责明确的需求/模板目录和可复现软件/文档工具。

- [ ] **Step 1: 建立文档目录并移动文件**

```powershell
New-Item -ItemType Directory -Force docs/requirements,docs/templates | Out-Null
git mv 'FGPA(1).docx' 'docs/requirements/FGPA(1).docx'
Move-Item -LiteralPath 'reports/Z15_FPGA项目验收与测试报告.docx' -Destination 'docs/templates/Z15_FPGA项目验收与测试报告.docx'
```

- [ ] **Step 2: 更新文档生成工具路径**

`tools/update_acceptance_report_dma_final.py` 的 `SRC` 改为：

```python
SRC = ROOT / "docs" / "templates" / "Z15_FPGA项目验收与测试报告.docx"
```

`tools/create_acceptance_report.py` 的基础模板输出改为同一路径，最终输出仍留在 `reports/`。

- [ ] **Step 3: 暂存可复现文件并检查差异**

```powershell
git add docs constraints/z15_board_pins.xdc software tools
git diff --cached --check
```

Expected: 没有生成 workspace、缓存或 `_local/` 进入暂存区。

- [ ] **Step 4: 提交归类结果**

```powershell
git commit -m "chore: classify project inputs and build utilities"
```

---

### Task 4: 重写项目入口文档和发布说明

**Files:**
- Modify: `README.md`
- Create: `docs/PROJECT_STRUCTURE.md`
- Create: `artifacts/README.md`
- Create: `reports/README.md`
- Create: `.gitattributes`

**Interfaces:**
- Consumes: 最终 DMA 性能、正式交付路径和重建命令。
- Produces: GitHub 首页、目录索引和二进制文件声明。

- [ ] **Step 1: 重写 README**

README 必须准确记录：

```text
单次共享 Tanimoto N64 32 us / 20.62x
GNN 33.84x
ADMET 21.11x
Pipeline 37.28x
MM2S/S2MM 1198.37/1199.74 MB/s
23 RTL testbench + 1 协议检查 + 7 软件测试
Vivado/Vitis 2019.2；器件 XC7Z015CLG485-2
```

并给出 `sim/run_tests.py --test all`、`FPGA/rebuild_dma_batch.tcl`、`software/create_dma_vitis_app.tcl` 和 `FPGA/program_dma_batch.tcl` 的命令。

- [ ] **Step 2: 创建目录与本地文件说明**

`docs/PROJECT_STRUCTURE.md` 逐项解释一级目录和 `_local/archive/`；`artifacts/README.md` 说明仅正式产物可提交；`reports/README.md` 区分正式证据与本地中间结果。

- [ ] **Step 3: 声明二进制文件**

`.gitattributes` 内容：

```gitattributes
*.bit binary
*.xsa binary
*.ltx binary
*.docx binary
*.pdf binary
```

- [ ] **Step 4: 验证 README 引用路径存在**

Run:

```powershell
rg -n "update_project|FGPA\(1\)|Z15_FPGA项目验收与测试报告\.docx" README.md tools docs
```

Expected: 所有引用对应新路径或仍存在的工程入口。

- [ ] **Step 5: 提交文档**

```powershell
git add README.md docs/PROJECT_STRUCTURE.md artifacts/README.md reports/README.md .gitattributes
git commit -m "docs: publish final FPGA project guide"
```

---

### Task 5: 验证整理结果与 GitHub 上传集合

**Files:**
- Verify only.

**Interfaces:**
- Consumes: 整理后的工作树。
- Produces: 测试、门禁、哈希、忽略和上传集合证据。

- [ ] **Step 1: 验证生成目录仍在且被忽略**

```powershell
$paths = '.Xil','FPGA/FPGA.cache','FPGA/FPGA.runs','vitis_workspace'
foreach ($path in $paths) {
    if (-not (Test-Path $path)) { throw "Missing retained path: $path" }
    git check-ignore -q $path
    if ($LASTEXITCODE -ne 0) { throw "Not ignored: $path" }
}
```

- [ ] **Step 2: 验证正式产物哈希**

```powershell
Get-FileHash artifacts/system_wrapper_dma_batch.bit,artifacts/system_wrapper_dma_batch.xsa,reports/Z15_FPGA项目验收与测试报告_20260811_DMA最终版.docx -Algorithm SHA256
```

Expected bit/XSA: `81EF25EE...ABC3E`、`736397FA...B6A61`；Word: `5CFE868F...D09C`。

- [ ] **Step 3: 运行 RTL、协议和软件测试**

```powershell
python sim/run_tests.py --test all
wsl.exe bash -lc "cd /mnt/d/FPGA && python3 -m unittest software/tests/test_mol_dma_layout.py"
python FPGA/check_dma_reports.py reports/dma_batch/impl
```

Expected: 23 RTL + 1 protocol PASS，7 tests OK，`DMA_REPORT_GATE_PASSED`。

- [ ] **Step 4: 审计上传集合**

```powershell
git status --short --ignored
git ls-files | Select-String -Pattern '^(_local/|vitis_workspace/|\.Xil/|FPGA/FPGA\.(cache|runs|hw|sim)/)'
git ls-files | ForEach-Object { Get-Item -LiteralPath $_ } | Where-Object Length -gt 95MB
```

Expected: 本地生成目录显示 `!!` 且不在 `git ls-files`；没有超过 95 MB 的已跟踪文件。

- [ ] **Step 5: 运行提交前检查**

```powershell
git diff --check
git status -sb
```

Expected: 无未提交的项目整理变更；仅允许被忽略的本地生成/归档内容。

---

### Task 6: 直接发布到 GitHub main

**Files:**
- No file changes.

**Interfaces:**
- Consumes: 已验证的本地 `main`。
- Produces: 更新后的 `fortitude24102-lang/FPGA` 远端 `main`。

- [ ] **Step 1: 验证 GitHub CLI 和远端**

```powershell
gh --version
gh auth status
git remote get-url origin
```

Expected: gh 已认证；origin 为 `https://github.com/fortitude24102-lang/FPGA.git`。

- [ ] **Step 2: 获取远端并验证无分叉**

```powershell
git fetch origin
git merge-base --is-ancestor origin/main main
```

Expected: exit code 0；若非 0，停止并报告远端已有新提交，不强推。

- [ ] **Step 3: 直接推送 main**

```powershell
git push origin main
```

Expected: 远端 `main` 快进到本地最终提交。

- [ ] **Step 4: 验证远端提交**

```powershell
git ls-remote origin refs/heads/main
git rev-parse HEAD
```

Expected: 两个 SHA 完全相同。
