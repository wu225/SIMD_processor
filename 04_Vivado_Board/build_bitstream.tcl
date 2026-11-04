set root [file dirname [file normalize [info script]]]
open_project $root/project/asip_board_demo.xpr
reset_run synth_1
launch_runs synth_1 -jobs 3
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 3
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
file mkdir $root/delivery
report_timing_summary -delay_type min_max -report_unconstrained -file $root/delivery/timing_summary.rpt
report_utilization -file $root/delivery/utilization.rpt
report_drc -file $root/delivery/drc.rpt
check_timing -verbose -file $root/delivery/check_timing.rpt
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup]==0 || [llength $hold]==0} {error "No timing paths"}
if {[get_property SLACK $setup]<0 || [get_property SLACK $hold]<0} {error "Timing failed; bitstream not generated"}
set violations [get_drc_violations -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]
if {[llength $violations]>0} {error "DRC requires resolution: $violations"}
write_debug_probes -force $root/delivery/asip_board_demo.ltx
write_bitstream -force $root/delivery/asip_board_demo.bit
puts "DELIVERY_READY: $root/delivery"
close_project
