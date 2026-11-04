# Run from this package with Vivado 2021.2. No programming or bitstream generation.
set root [file dirname [file normalize [info script]]]
cd $root
proc all_verilog {dir} {
    set out [glob -nocomplain -directory $dir *.v]
    foreach sub [glob -nocomplain -type d -directory $dir *] {
        set out [concat $out [all_verilog $sub]]
    }
    return $out
}
create_project asip_board_demo $root/project -part xcvu13p-fhgb2104-2-i
set_property target_language Verilog [current_project]
add_files [all_verilog $root/../01_ASIP_Verilog]
add_files [glob $root/rtl/*.v]
set_property file_type SystemVerilog [get_files *.v]
set_property file_type {Verilog Header} [get_files */primitives.v]
set_property include_dirs [list $root/../01_ASIP_Verilog/prim] [get_filesets sources_1]
foreach f [glob $root/mem/pm*.mem $root/mem/dm.mem] {
    file copy -force $f $root/[file tail $f]
    add_files $f
}
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name demo_vio
set_property -dict [list CONFIG.C_NUM_PROBE_IN {1} CONFIG.C_PROBE_IN0_WIDTH {32} \
 CONFIG.C_NUM_PROBE_OUT {1} CONFIG.C_PROBE_OUT0_WIDTH {1} CONFIG.C_PROBE_OUT0_INIT_VAL {0x1}] [get_ips demo_vio]
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name demo_ila
set_property -dict [list CONFIG.C_NUM_OF_PROBES {8} CONFIG.C_DATA_DEPTH {2048} \
 CONFIG.C_PROBE0_WIDTH {32} CONFIG.C_PROBE1_WIDTH {32} CONFIG.C_PROBE2_WIDTH {32} \
 CONFIG.C_PROBE3_WIDTH {32} CONFIG.C_PROBE4_WIDTH {32} CONFIG.C_PROBE5_WIDTH {32} \
 CONFIG.C_PROBE6_WIDTH {1} CONFIG.C_PROBE7_WIDTH {1}] [get_ips demo_ila]
generate_target all [get_ips]
add_files -fileset constrs_1 $root/board_pending.xdc
set_property top asip_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1
close_project
puts "PROJECT_READY: $root/project/asip_board_demo.xpr"
