# Verify a recreated project and run the packaged XSim self-check.
# Usage: set AI4NPU_BUILD_DIR, then vivado -mode batch -source tools/verify_rebuilt.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
if {![info exists ::env(AI4NPU_BUILD_DIR)]} {
    error "Set AI4NPU_BUILD_DIR to the recreated project directory"
}
open_project [file join $::env(AI4NPU_BUILD_DIR) ai4npu.xpr]
if {[llength [get_files -quiet ai4npu_bd.bd]] != 1 ||
    [get_property top [get_filesets sources_1]] ne "ai4npu_bd_wrapper" ||
    [llength [get_ips -quiet]] < 7} {
    error "Rebuilt project is missing the expected BD, top, or IPs"
}
set_property top tb_mnist_regression [get_filesets sim_1]
set_property xsim.simulate.runtime 5100us [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
