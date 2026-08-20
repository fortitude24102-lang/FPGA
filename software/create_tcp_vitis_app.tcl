set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set workspace [file join $root_dir vitis_workspace]
set default_xsa [file join $root_dir artifacts system_wrapper_tcp_service.xsa]
set source_dir [file join $script_dir baremetal src]
set patcher [file join $script_dir patch_lwip_yt8531.py]
set platform_name z15_tcp_platform
set app_name accelerator_tcp_server
set domain_name standalone_domain
set processor_name ps7_cortexa9_0

if {[info exists ::env(MOL_TCP_XSA)] && $::env(MOL_TCP_XSA) ne ""} {
    set hardware_xsa [file normalize $::env(MOL_TCP_XSA)]
} else {
    set hardware_xsa $default_xsa
}
if {![file exists $hardware_xsa]} {
    error "TCP service hardware XSA does not exist: $hardware_xsa"
}
if {![file exists $patcher]} {
    error "YT8531C lwIP patcher is missing: $patcher"
}

set app_sources {
    accelerator.c accelerator.h
    mol_dma_protocol.h mol_dma_queue.c mol_dma_queue.h
    mol_tcp_protocol.c mol_tcp_protocol.h
    platform.c platform.h main_tcp_server.c
}
foreach source_file $app_sources {
    if {![file exists [file join $source_dir $source_file]]} {
        error "Canonical TCP application source is missing: $source_file"
    }
}

setws $workspace

# Vitis 2019.2 ships lwIP 2.0.2 but hides it from new BSPs because its MLD is
# marked deprecated.  Build a local, generated repository overlay from that
# exact bundled package; only the visibility marker is removed.
if {![info exists ::env(XILINX_VITIS)] || $::env(XILINX_VITIS) eq ""} {
    error "XILINX_VITIS is not set"
}
set bundled_lwip202 [file join $::env(XILINX_VITIS) data embeddedsw \
    ThirdParty sw_services lwip202_v1_1]
if {![file exists [file join $bundled_lwip202 data lwip202.mld]]} {
    error "Bundled Vitis 2019.2 lwip202_v1_1 was not found"
}
set overlay_repo [file join $workspace _lwip202_repo]
set overlay_parent [file join $overlay_repo ThirdParty sw_services]
set overlay_lwip202 [file join $overlay_parent lwip202_v1_1]
file delete -force $overlay_lwip202
file mkdir $overlay_parent
file copy -force $bundled_lwip202 $overlay_parent
set overlay_mld [file join $overlay_lwip202 data lwip202.mld]
set input [open $overlay_mld r]
set mld_text [read $input]
close $input
set filtered_lines {}
foreach line [split $mld_text "\n"] {
    if {[string first "OPTION library_state" $line] < 0} {
        lappend filtered_lines $line
    }
}
set output [open $overlay_mld w]
puts -nonewline $output [join $filtered_lines "\n"]
close $output
repo -set $overlay_repo
repo -scan
if {[lsearch -exact [platform list] $platform_name] < 0} {
    platform create -name $platform_name -hw $hardware_xsa \
        -proc $processor_name -os standalone -no-boot-bsp
} else {
    platform active $platform_name
    platform config -updatehw $hardware_xsa
}

platform active $platform_name
platform generate
domain active $domain_name

if {[catch {bsp getlibs} bsp_libraries] ||
    [string first "lwip202" $bsp_libraries] < 0} {
    bsp setlib -name lwip202
}
bsp config api_mode RAW_API
bsp config lwip_dhcp false
bsp config phy_link_speed CONFIG_LINKSPEED_AUTODETECT
bsp config emac_number 0
bsp regenerate
platform generate

# Patch only the generated BSP copy.  The Vitis installation remains pristine,
# while every clean platform build gets the same finite Clause 22 PHY path.
set bsp_root [file join $workspace $platform_name $processor_name \
    $domain_name bsp]
set phy_matches [glob -nocomplain [file join $bsp_root $processor_name \
    libsrc lwip202_v* src contrib ports xilinx netif xemacpsif_physpeed.c]]
if {[llength $phy_matches] != 1} {
    error "Expected one generated lwIP PHY source, found [llength $phy_matches]"
}
set phy_source [lindex $phy_matches 0]

if {[info exists ::env(MOL_PYTHON)] && $::env(MOL_PYTHON) ne ""} {
    set python_cmd $::env(MOL_PYTHON)
} else {
    set python_cmd python
}
puts [exec $python_cmd $patcher $phy_source 2>@1]

# platform generate compiled the unpatched source, so rebuild libxil.a once and
# replace the exported BSP archive that the application linker consumes.
puts [exec make -C $bsp_root clean 2>@1]
puts [exec make -C $bsp_root all 2>@1]
set built_lib [file join $bsp_root $processor_name lib libxil.a]
set exported_lib [file join $workspace $platform_name export $platform_name \
    sw $platform_name $domain_name bsplib lib libxil.a]
if {![file exists $built_lib] || ![file exists [file dirname $exported_lib]]} {
    error "Rebuilt or exported BSP library path is missing"
}
file copy -force $built_lib $exported_lib

if {[lsearch -exact [getprojects] $app_name] < 0} {
    app create -name $app_name -platform $platform_name \
        -domain $domain_name -template {Empty Application}
}
foreach source_file $app_sources {
    importsources -name $app_name -path [file join $source_dir $source_file]
}

app config -name $app_name build-config Debug
app build -name $app_name
set debug_elf [file join $workspace $app_name Debug ${app_name}.elf]
if {![file exists $debug_elf]} {
    error "Debug ELF was not generated: $debug_elf"
}
puts "TCP_DEBUG_ELF=$debug_elf"

app config -name $app_name build-config Release
app build -name $app_name
set release_elf [file join $workspace $app_name Release ${app_name}.elf]
if {![file exists $release_elf]} {
    error "Release ELF was not generated: $release_elf"
}
puts "TCP_RELEASE_ELF=$release_elf"
exit
