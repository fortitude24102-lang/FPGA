# Rebuild and gate the production DMA/burst/batch candidate without touching
# the previously validated release artifacts.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project_file [file join $script_dir FPGA.xpr]
set candidate_report_dir [file join $root_dir reports candidate_dma_batch]
set rtl_report_dir [file join $candidate_report_dir rtl]
set impl_report_dir [file join $candidate_report_dir impl]
set candidate_dir [file join $root_dir artifacts candidate_dma_batch]
set candidate_bit [file join $candidate_dir system_wrapper_dma_batch.bit]
set candidate_xsa [file join $candidate_dir system_wrapper_dma_batch.xsa]

file mkdir $rtl_report_dir
file mkdir $impl_report_dir
file mkdir $candidate_dir

proc require_complete_run {run_name} {
    set status [get_property STATUS [get_runs $run_name]]
    puts "$run_name STATUS=$status"
    if {![string match "*Complete*" $status]} {
        error "$run_name failed: $status"
    }
}

proc find_clock_with_period {target_period tolerance} {
    foreach clock [get_clocks -quiet] {
        set period [get_property PERIOD $clock]
        if {$period ne "" && abs(double($period) - $target_period) <= $tolerance} {
            return $clock
        }
    }
    return ""
}

proc worst_slack_for_clock {clock delay_type} {
    if {$clock eq ""} {
        return -999.0
    }
    set paths [get_timing_paths -quiet -delay_type $delay_type \
        -max_paths 1 -nworst 1 -group $clock]
    if {[llength $paths] == 0} {
        return -999.0
    }
    return [get_property SLACK [lindex $paths 0]]
}

proc write_metric {channel key value} {
    puts $channel "$key=$value"
}

open_project $project_file
set_property ip_repo_paths [file join $root_dir ip_repo] [current_project]
update_ip_catalog

# Build the already validated production BD.  Reopening it before target
# generation avoids the Vivado 2019.2 stale source-direction bug documented in
# add_dma_batch_system.tcl, and also keeps repeated rebuilds byte-stable.
set bd_file [file join $script_dir FPGA.srcs sources_1 bd system system.bd]
open_bd_design $bd_file
set locked_accel_ips [get_ips -quiet -filter \
    {IS_LOCKED == 1 && NAME =~ "system_generator_accelerator_*"}]
if {[llength $locked_accel_ips] != 0} {
    puts "UPGRADE_ACCELERATOR_IP=$locked_accel_ips"
    upgrade_ip $locked_accel_ips
}
validate_bd_design
save_bd_design
set bd_object [get_files -quiet $bd_file]
reset_target all $bd_object
generate_target all $bd_object
create_ip_run $bd_object
close_bd_design [get_bd_designs system]
update_compile_order -fileset sources_1

# Custom IP sources can change without Vivado invalidating an already complete
# block-design OOC run.  Reset and rebuild the accelerator DCP explicitly so a
# production candidate can never silently reuse stale RTL.
set accel_ooc_runs [get_runs -quiet -filter \
    {NAME =~ "system_generator_accelerator_*_synth_1"}]
if {[llength $accel_ooc_runs] == 0} {
    error "accelerator OOC synthesis run was not found"
}
foreach accel_ooc_run $accel_ooc_runs {
    puts "RESET_ACCELERATOR_OOC=[get_property NAME $accel_ooc_run]"
    reset_run $accel_ooc_run
}
launch_runs $accel_ooc_runs -jobs 4
foreach accel_ooc_run $accel_ooc_runs {
    wait_on_run $accel_ooc_run
    require_complete_run [get_property NAME $accel_ooc_run]
}

set synth_run [get_runs synth_1]
set impl_run [get_runs impl_1]
set_property strategy {Vivado Synthesis Defaults} $synth_run
set_property strategy {Performance_ExplorePostRoutePhysOpt} $impl_run

reset_run $synth_run
launch_runs $synth_run -jobs 4
wait_on_run $synth_run
require_complete_run synth_1

open_run synth_1
report_utilization -file [file join $rtl_report_dir utilization_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
    -file [file join $rtl_report_dir utilization_synth_hierarchical.rpt]
close_design

set synth_log [file join $script_dir FPGA.runs synth_1 runme.log]
if {![file exists $synth_log]} {
    error "synthesis log is missing: $synth_log"
}
file copy -force $synth_log [file join $impl_report_dir synth_messages.txt]

reset_run $impl_run
launch_runs $impl_run -to_step write_bitstream -jobs 4
wait_on_run $impl_run
require_complete_run impl_1

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -max_paths 50 -file [file join $impl_report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 50 -sort_by group \
    -file [file join $impl_report_dir worst_setup_paths.rpt]
report_timing -delay_type min -max_paths 50 -sort_by group \
    -file [file join $impl_report_dir worst_hold_paths.rpt]
report_utilization -file [file join $impl_report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
    -file [file join $impl_report_dir utilization_hierarchical.rpt]
report_route_status -file [file join $impl_report_dir route_status.rpt]
report_clocks -file [file join $impl_report_dir clocks.rpt]
report_drc -file [file join $impl_report_dir drc.rpt]
set drc_errors [llength [get_drc_violations -quiet \
    -filter {SEVERITY == Error}]]
report_methodology -file [file join $impl_report_dir methodology_drc.rpt]
set methodology_errors [llength [get_methodology_violations -quiet \
    -filter {SEVERITY == Error}]]

set run_bit [file join $script_dir FPGA.runs impl_1 system_wrapper.bit]
if {![file exists $run_bit]} {
    error "implemented bitstream is missing: $run_bit"
}
file copy -force $run_bit $candidate_bit
write_hw_platform -fixed -include_bit -force -file $candidate_xsa

set global_setup [lindex [get_timing_paths -quiet -delay_type max \
    -max_paths 1 -nworst 1] 0]
set global_hold [lindex [get_timing_paths -quiet -delay_type min \
    -max_paths 1 -nworst 1] 0]
if {$global_setup eq "" || $global_hold eq ""} {
    error "implemented design has no setup or hold timing paths"
}
set global_wns [get_property SLACK $global_setup]
set global_whs [get_property SLACK $global_hold]

set clock100 [find_clock_with_period 10.000 0.010]
set clock150 [find_clock_with_period 6.667 0.010]
set clock100_present [expr {$clock100 ne "" ? 1 : 0}]
set clock150_present [expr {$clock150 ne "" ? 1 : 0}]
set clock100_wns [worst_slack_for_clock $clock100 max]
set clock100_whs [worst_slack_for_clock $clock100 min]
set clock150_wns [worst_slack_for_clock $clock150 max]
set clock150_whs [worst_slack_for_clock $clock150 min]

set utilization_text [report_utilization -return_string]
foreach {resource pattern} {
    lut  {\| Slice LUTs\s+\|\s+([0-9.]+)\s+\|}
    ff   {\| Slice Registers\s+\|\s+([0-9.]+)\s+\|}
    bram {\| Block RAM Tile\s+\|\s+([0-9.]+)\s+\|}
    dsp  {\| DSPs\s+\|\s+([0-9.]+)\s+\|}
} {
    if {![regexp $pattern $utilization_text unused value]} {
        error "could not parse $resource utilization"
    }
    set ${resource}_used $value
}
set unrouted_nets [llength [get_nets -quiet -hierarchical \
    -filter {ROUTE_STATUS == UNROUTED}]]

set metric_file [file join $impl_report_dir gate_metrics.txt]
set metrics [open $metric_file w]
puts $metrics "# Generated from the implemented Vivado design."
write_metric $metrics route_complete 1
write_metric $metrics unrouted_nets $unrouted_nets
write_metric $metrics drc_errors $drc_errors
write_metric $metrics methodology_errors $methodology_errors
write_metric $metrics dsp_used $dsp_used
write_metric $metrics dsp_available 160
write_metric $metrics lut_used $lut_used
write_metric $metrics lut_available 46200
write_metric $metrics ff_used $ff_used
write_metric $metrics ff_available 92400
write_metric $metrics bram_used $bram_used
write_metric $metrics bram_available 95
write_metric $metrics clock_100_present $clock100_present
write_metric $metrics clock_150_present $clock150_present
write_metric $metrics clock_100_wns $clock100_wns
write_metric $metrics clock_100_whs $clock100_whs
write_metric $metrics clock_150_wns $clock150_wns
write_metric $metrics clock_150_whs $clock150_whs
write_metric $metrics global_wns $global_wns
write_metric $metrics global_whs $global_whs
write_metric $metrics bitstream_exists [expr {[file exists $candidate_bit] ? 1 : 0}]
write_metric $metrics xsa_exists [expr {[file exists $candidate_xsa] ? 1 : 0}]
close $metrics

puts "DMA_CANDIDATE_BIT=$candidate_bit"
puts "DMA_CANDIDATE_XSA=$candidate_xsa"
puts "DMA_GATE_METRICS=$metric_file"
close_project
exit
