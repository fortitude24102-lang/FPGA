set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set workspace [file join $root_dir vitis_workspace]
set default_xsa [file join $root_dir artifacts system_wrapper_dma_batch.xsa]
set source_dir [file join $script_dir baremetal src]
set platform_name z15_dma_platform
set app_name accelerator_dma_batch
set domain_name standalone_domain

if {[info exists ::env(MOL_DMA_XSA)] && $::env(MOL_DMA_XSA) ne ""} {
    set hardware_xsa [file normalize $::env(MOL_DMA_XSA)]
} else {
    set hardware_xsa $default_xsa
}
if {![file exists $hardware_xsa]} {
    error "DMA hardware XSA does not exist: $hardware_xsa"
}

foreach source_file {
    accelerator.c accelerator.h
    mol_dma_protocol.h mol_dma_queue.c mol_dma_queue.h
    platform.c platform.h main_dma_batch.c
} {
    if {![file exists [file join $source_dir $source_file]]} {
        error "Canonical application source is missing: $source_file"
    }
}

setws $workspace

if {[lsearch -exact [platform list] $platform_name] < 0} {
    platform create -name $platform_name -hw $hardware_xsa \
        -proc ps7_cortexa9_0 -os standalone -no-boot-bsp
} else {
    platform active $platform_name
    platform config -updatehw $hardware_xsa
}
platform active $platform_name
platform generate
domain active $domain_name
bsp regenerate
platform generate

if {[lsearch -exact [getprojects] $app_name] < 0} {
    app create -name $app_name -platform $platform_name \
        -domain $domain_name -template {Empty Application}
}

foreach source_file {
    accelerator.c accelerator.h
    mol_dma_protocol.h mol_dma_queue.c mol_dma_queue.h
    platform.c platform.h main_dma_batch.c
} {
    importsources -name $app_name -path [file join $source_dir $source_file]
}

app config -name $app_name build-config Debug
app build -name $app_name
set debug_elf [file join $workspace $app_name Debug ${app_name}.elf]
if {![file exists $debug_elf]} {
    error "Debug ELF was not generated: $debug_elf"
}
puts "DMA_DEBUG_ELF=$debug_elf"

app config -name $app_name build-config Release
app build -name $app_name
set release_elf [file join $workspace $app_name Release ${app_name}.elf]
if {![file exists $release_elf]} {
    error "Release ELF was not generated: $release_elf"
}
puts "DMA_RELEASE_ELF=$release_elf"
exit
