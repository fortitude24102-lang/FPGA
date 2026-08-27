# Rebuild and gate the production DMA/burst/batch candidate without touching
# the previously validated release artifacts.

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project_file [file join $script_dir FPGA.xpr]
set build_mode release
if {[info exists ::env(BUILD_MODE)]} {
    set build_mode [string tolower $::env(BUILD_MODE)]
}
if {$build_mode ni {debug release}} {
    error "BUILD_MODE must be debug or release (got $build_mode)"
}
set candidate_report_dir [file join $root_dir reports candidate_dma_batch \
                               $build_mode]
set rtl_report_dir [file join $candidate_report_dir rtl]
set impl_report_dir [file join $candidate_report_dir impl]
set candidate_dir [file join $root_dir artifacts candidate_dma_batch $build_mode]
set candidate_bit [file join $candidate_dir system_wrapper_${build_mode}.bit]
set candidate_xsa [file join $candidate_dir system_wrapper_${build_mode}.xsa]

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

proc find_core_wizard_clock {} {
    foreach pin [get_pins -quiet -hierarchical \
                     -filter {NAME =~ */accelerator_clock_wizard*/clk_out1}] {
        set clocks [get_clocks -quiet -of_objects $pin]
        if {[llength $clocks] != 0} {
            return [lindex $clocks 0]
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

proc tns_for_clock {clock} {
    if {$clock eq ""} {
        return -999.0
    }
    set total 0.0
    foreach path [get_timing_paths -quiet -delay_type max -max_paths 10000 \
                  -slack_lesser_than 0 -group $clock] {
        set total [expr {$total + double([get_property SLACK $path])}]
    }
    return $total
}

proc bd_pins_share_net {first second} {
    set first_pin [get_bd_pins -quiet $first]
    set second_pin [get_bd_pins -quiet $second]
    if {[llength $first_pin] != 1 || [llength $second_pin] != 1} {
        return 0
    }
    set first_net [get_bd_nets -quiet -of_objects $first_pin]
    set second_net [get_bd_nets -quiet -of_objects $second_pin]
    return [expr {[llength $first_net] == 1 && $first_net eq $second_net}]
}

set packaged_sources_match 1
foreach name {
    admet_predictor.v fc_network.v gnn_message_passing.v
    tanimoto_accelerator.v tanimoto_stream_batch.v
    dma_task_queue_frontend.v dma_task_queue.v dma_result_formatter.v
    dma_accelerator_backend.v lcd_status_display.v
    generator_accelerator_top.v mol_dma_protocol.vh
} {
    set tracked [file join $root_dir rtl $name]
    set packaged [file join $root_dir ip_repo generator_accelerator_1_0 src $name]
    if {![file exists $tracked] || ![file exists $packaged] ||
        [file size $tracked] != [file size $packaged]} {
        set packaged_sources_match 0
        puts "SOURCE_MISMATCH=$name"
        continue
    }
    set tracked_handle [open $tracked rb]
    set tracked_data [read $tracked_handle]
    close $tracked_handle
    set packaged_handle [open $packaged rb]
    set packaged_data [read $packaged_handle]
    close $packaged_handle
    if {$tracked_data ne $packaged_data} {
        set packaged_sources_match 0
        puts "SOURCE_MISMATCH=$name"
    }
}
if {!$packaged_sources_match} {
    error "packaged accelerator RTL does not match tracked RTL"
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
set ila_bd_cells [get_bd_cells -quiet -hierarchical \
    -filter {VLNV =~ "xilinx.com:ip:ila:*"}]
if {($build_mode eq "release" && [llength $ila_bd_cells] != 0) ||
    ($build_mode eq "debug" && [llength $ila_bd_cells] != 1)} {
    error "BD ILA content does not match BUILD_MODE=$build_mode"
}
set ila_queue_occupancy_probe [bd_pins_share_net \
    accelerator_debug_ila/probe0 generator_accelerator_0/debug_queue_occupancy]
set ila_engine_start_probe [bd_pins_share_net \
    accelerator_debug_ila/probe1 generator_accelerator_0/engine_start]
set ila_engine_busy_probe [bd_pins_share_net \
    accelerator_debug_ila/probe2 generator_accelerator_0/engine_busy]
set ila_engine_done_probe [bd_pins_share_net \
    accelerator_debug_ila/probe3 generator_accelerator_0/engine_done]
set ila_active_sequence_probe [bd_pins_share_net \
    accelerator_debug_ila/probe4 generator_accelerator_0/debug_active_sequence]
set ila_clock_profile_probe [bd_pins_share_net \
    accelerator_debug_ila/probe5 clock_profile_const/dout]
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
set accel_ips [get_ips -quiet -filter \
    {NAME =~ "system_generator_accelerator_*"}]
if {[llength $accel_ips] != 1} {
    error "expected one current accelerator IP, found [llength $accel_ips]"
}
set accel_ooc_runs [get_runs -quiet "[get_property NAME $accel_ips]_synth_1"]
if {[llength $accel_ooc_runs] != 1} {
    error "current accelerator OOC synthesis run was not found"
}
set pending_accel_ooc_runs {}
foreach accel_ooc_run $accel_ooc_runs {
    set accel_ooc_status [get_property STATUS $accel_ooc_run]
    if {[string match "*Complete*" $accel_ooc_status]} {
        puts "REUSE_ACCELERATOR_OOC=[get_property NAME $accel_ooc_run]"
    } else {
        puts "RESET_ACCELERATOR_OOC=[get_property NAME $accel_ooc_run]"
        reset_run $accel_ooc_run
        lappend pending_accel_ooc_runs $accel_ooc_run
    }
}
if {[llength $pending_accel_ooc_runs] != 0} {
    launch_runs $pending_accel_ooc_runs -jobs 4
    foreach accel_ooc_run $pending_accel_ooc_runs {
        wait_on_run $accel_ooc_run
    }
}
foreach accel_ooc_run $accel_ooc_runs {
    require_complete_run [get_property NAME $accel_ooc_run]
}

set synth_run [get_runs synth_1]
set impl_run [get_runs impl_1]
set_property strategy {Vivado Synthesis Defaults} $synth_run
set_property strategy {Performance_ExplorePostRoutePhysOpt} $impl_run
# Vivado 2019.2 crashes in the Explore directive's internal BRAM power pass
# for this design ([Vivado_Tcl 4-133/4-130]).  Keep the strategy's timing
# directives, but select the documented opt_design variant that omits only
# that power pass; the separate power_opt_design step is disabled as well.
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE NoBramPowerOpt $impl_run
set_property STEPS.POWER_OPT_DESIGN.IS_ENABLED false $impl_run
# On this near-capacity Z015 implementation, Vivado 2019.2 PSIP leaves 91
# slices unplaced; the ordinary placer packs the same netlist successfully.
set_property -name {STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS} -value {-no_psip} \
    -objects $impl_run

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
set global_tns 0.0
foreach path [get_timing_paths -quiet -delay_type max -max_paths 10000 \
              -slack_lesser_than 0] {
    set global_tns [expr {$global_tns + double([get_property SLACK $path])}]
}

set clock100 [find_clock_with_period 10.000 0.010]
set clock125 [find_clock_with_period 8.000 0.010]
set clock33 [find_clock_with_period 30.303 0.500]
set clock_core_100 [find_core_wizard_clock]
set clock100_present [expr {$clock100 ne "" ? 1 : 0}]
set clock125_present [expr {$clock125 ne "" ? 1 : 0}]
set clock33_present [expr {$clock33 ne "" ? 1 : 0}]
set clock_core_100_present [expr {$clock_core_100 ne "" ? 1 : 0}]
set clock100_wns [worst_slack_for_clock $clock100 max]
set clock100_whs [worst_slack_for_clock $clock100 min]
set clock100_tns [tns_for_clock $clock100]
set clock125_wns [worst_slack_for_clock $clock125 max]
set clock125_whs [worst_slack_for_clock $clock125 min]
set clock125_tns [tns_for_clock $clock125]
set clock_core_100_wns [worst_slack_for_clock $clock_core_100 max]
set clock_core_100_whs [worst_slack_for_clock $clock_core_100 min]
set clock_core_100_tns [tns_for_clock $clock_core_100]

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
set ila_present [expr {[llength [get_debug_cores -quiet]] != 0 ? 1 : 0}]
set result_pool_bram_cells 0
set weight_bank_bram_cells 0
foreach cell [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}] {
    set cell_name [get_property NAME $cell]
    if {[string match "*u_dma_queue*result_pool*" $cell_name]} {
        incr result_pool_bram_cells
    }
    if {([string match "*u_gnn*" $cell_name] ||
         [string match "*u_admet*" $cell_name]) &&
        ([string match -nocase "*weight*" $cell_name] ||
         [string match -nocase "*bias*" $cell_name])} {
        incr weight_bank_bram_cells
    }
}

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
write_metric $metrics clock_125_present $clock125_present
write_metric $metrics clock_33_present $clock33_present
write_metric $metrics clock_core_100_present $clock_core_100_present
write_metric $metrics clock_core_150_experimental 1
write_metric $metrics clock_100_wns $clock100_wns
write_metric $metrics clock_100_tns $clock100_tns
write_metric $metrics clock_100_whs $clock100_whs
write_metric $metrics clock_125_wns $clock125_wns
write_metric $metrics clock_125_tns $clock125_tns
write_metric $metrics clock_125_whs $clock125_whs
write_metric $metrics clock_core_100_wns $clock_core_100_wns
write_metric $metrics clock_core_100_tns $clock_core_100_tns
write_metric $metrics clock_core_100_whs $clock_core_100_whs
write_metric $metrics global_wns $global_wns
write_metric $metrics global_tns $global_tns
write_metric $metrics global_whs $global_whs
write_metric $metrics build_mode $build_mode
write_metric $metrics runtime_profiles_mhz 50,100,150
write_metric $metrics ila_present $ila_present
write_metric $metrics ila_queue_occupancy_probe $ila_queue_occupancy_probe
write_metric $metrics ila_engine_start_probe $ila_engine_start_probe
write_metric $metrics ila_engine_busy_probe $ila_engine_busy_probe
write_metric $metrics ila_engine_done_probe $ila_engine_done_probe
write_metric $metrics ila_active_sequence_probe $ila_active_sequence_probe
write_metric $metrics ila_clock_profile_probe $ila_clock_profile_probe
write_metric $metrics result_pool_bram_cells $result_pool_bram_cells
write_metric $metrics weight_bank_bram_cells $weight_bank_bram_cells
write_metric $metrics rtl_ip_sources_match $packaged_sources_match
write_metric $metrics bitstream_exists [expr {[file exists $candidate_bit] ? 1 : 0}]
write_metric $metrics xsa_exists [expr {[file exists $candidate_xsa] ? 1 : 0}]
close $metrics

puts "DMA_CANDIDATE_BIT=$candidate_bit"
puts "DMA_CANDIDATE_XSA=$candidate_xsa"
puts "DMA_GATE_METRICS=$metric_file"
puts "BUILD_MODE=$build_mode"
close_project
exit
