#*******************************************************************************
# build.tcl - Project Recreation Script
# Generated: Wed Oct 28 14:36:37 2026
# Original Project: ai4npu
#*******************************************************************************

set script_dir [file dirname [file normalize [info script]]]
set base_dir [file dirname $script_dir]
set proj_name ai4npu

#─────────────────────────────────────────────────────────────────────────────────
# Step 1: Create Project
#─────────────────────────────────────────────────────────────────────────────────
if {[info exists ::env(AI4NPU_BUILD_DIR)]} {
    set build_dir [file normalize $::env(AI4NPU_BUILD_DIR)]
} else {
    set build_dir [file normalize [file join $base_dir .. build vivado]]
}
if {[file exists [file join $build_dir ai4npu.xpr]]} {
    error "Project already exists in $build_dir; choose a fresh AI4NPU_BUILD_DIR"
}
create_project ai4npu $build_dir -part xczu7ev-ffvc1156-2-e
set_property BOARD_PART {xilinx.com:zcu104:part0:1.1} [current_project]

#─────────────────────────────────────────────────────────────────────────────────
# Step 2: Add RTL Sources
#─────────────────────────────────────────────────────────────────────────────────
# Local sources �? import into project for full portability
set rtl_files {}
catch {set rtl_files [glob $base_dir/Sources/RTL/*]}
if {[llength $rtl_files] > 0} {
    import_files $rtl_files
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 3: Add Constraint Files
#─────────────────────────────────────────────────────────────────────────────────
set xdc_files {}
catch {set xdc_files [glob $base_dir/Sources/Constraints/*.xdc]}
# Include NoC constraints if present
catch {lappend xdc_files {*}[glob $base_dir/Sources/NoC/*.xdc]}
if {[llength $xdc_files] > 0} {
    import_files -fileset constrs_1 $xdc_files
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 4: Add Simulation Files
#─────────────────────────────────────────────────────────────────────────────────
set sim_files {}
catch {set sim_files [glob $base_dir/Sources/Simulation/*]}
if {[llength $sim_files] > 0} {
    import_files -fileset sim_1 $sim_files
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 5: Add Data Files (Memory init, config, etc.)
#─────────────────────────────────────────────────────────────────────────────────
set data_files {}
catch {set data_files [glob $base_dir/Sources/Data/*]}
if {[llength $data_files] > 0} {
    import_files -fileset sim_1 $data_files
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 6: Recreate IP Cores
#─────────────────────────────────────────────────────────────────────────────────
set ip_tcls {}
catch {set ip_tcls [glob $base_dir/Sources/IP/*.tcl]}
foreach ip_tcl $ip_tcls {
    source $ip_tcl
}

# Create OOC synthesis runs for standalone IPs (outside Block Designs)
set standalone_ips [get_ips]
foreach ip $standalone_ips {
    set is_bd [get_property IS_BD_CONTEXT $ip]
    if {$is_bd ne "1" && $is_bd ne "true"} {
        catch {create_ip_run [get_ips [get_property NAME $ip]]}
    }
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 7: Recreate Block Designs
# CRITICAL: BDC child BDs must be sourced BEFORE parent BDs that instantiate them.
# For DFX: RM Block Designs are skipped here �? they are added to RM filesets in
#          Step 12 (dfx_define_partition) to prevent them from becoming independent BDs.
#─────────────────────────────────────────────────────────────────────────────────
set bd_is_rm_owned 0
if {[info exists _rm_owned_bd_names]} {
    set bd_is_rm_owned [expr {[lsearch $_rm_owned_bd_names "ai4npu_bd"] >= 0}]
}
if {$bd_is_rm_owned} {
    puts "  Skipping BD (RM-owned): ai4npu_bd �? will be added to RM fileset in Step 12"
} elseif {0} {
    # Preserved BD (remote cache mode): add_files the .bd restored from the
    # cache in Step 1c, and rely on the .gen restored there too to avoid
    # regeneration. Non-preserved BDs use the standard Tcl-regeneration path
    # below -- this branch is per-BD, not global. Step 1c already guarantees
    # this source exists (it errors out the whole build otherwise).
    add_files -norecurse [file join ${proj_name}.srcs {} {ai4npu_bd.bd}]
    if {[catch {generate_target all [get_files ai4npu_bd.bd]} _gt_pres_err]} {
        puts "  WARNING: generate_target failed for preserved BD ai4npu_bd: $_gt_pres_err"
    }
    # add_files alone does not open the BD as a live design -- validate_bd_design
    # / save_bd_design / get_bd_designs need open_bd_design first, or they fail
    # with 'Cannot find design named ...' / 'A block design must be open'.
    catch {open_bd_design [get_files ai4npu_bd.bd]}
    catch {validate_bd_design -force -design ai4npu_bd}
    catch {save_bd_design [get_bd_designs -quiet ai4npu_bd]}
} else {
    set bd_tcl $base_dir/Sources/BD/ai4npu_bd.tcl
    if {[file exists $bd_tcl]} {
        puts "  Sourcing BD: ai4npu_bd"
        source $bd_tcl
        # Validate immediately: BDC parents that reference this BD as a
        # container (create_bd_cell -type container -reference) require it
        # to be validated first, otherwise cell creation fails.
        if {[catch {validate_bd_design -force -design ai4npu_bd} _vbd_err]} {
            puts "  WARNING: validate_bd_design reported an error for ai4npu_bd: $_vbd_err"
            puts "  This is usually caused by locked/out-of-date IPs in the BD."
            puts "  On the ORIGINAL project: open_bd_design ai4npu_bd.bd; report_ip_status"
            puts "  then upgrade_ip the flagged IPs and re-run this export."
            puts "  NOTE: Vivado now treats this session as having a logged error --"
            puts "  later commands (e.g. make_wrapper) may fail with 'failed due to"
            puts "  earlier errors' even though THIS is the real root cause."
        }
        # Persist the validated state �? without this, a sibling BD sourced
        # later that references this BD as a BDC container may see it as
        # not validated (validate_bd_design alone is not enough).
        catch {save_bd_design [get_bd_designs -quiet ai4npu_bd]}
    } else {
        puts "  WARNING: BD tcl not exported, skipping: ai4npu_bd"
    }
}


#─────────────────────────────────────────────────────────────────────────────────
# Step 8: Recreate Block Design wrappers (only if wrapper was present in project)
#─────────────────────────────────────────────────────────────────────────────────
# Create and add wrapper for BD: ai4npu_bd
set bd_obj [get_files -quiet ai4npu_bd.bd]
if {[llength $bd_obj] > 0} {
    if {[catch {set wrapper_path [make_wrapper -files $bd_obj -top]} _mw_err]} {
        puts "  ERROR: make_wrapper failed for ai4npu_bd: $_mw_err"
        puts "  This almost always means an EARLIER step already logged an error"
        puts "  for this BD (search this log above for WARNING/ERROR mentioning"
        puts "  ai4npu_bd -- commonly locked/out-of-date IPs from Step 7)."
        puts "  Fix on the ORIGINAL project (report_ip_status / upgrade_ip), then"
        puts "  re-run the export/build pipeline."
    } else {
        import_files $wrapper_path
    }
}


#─────────────────────────────────────────────────────────────────────────────────
# Step 9: Generate BD Targets and Create BD IP OOC Runs
# NOTE: Only operate on top-level user BDs from sources_1 fileset.
#       Nested sub-designs (e.g., inside Versal CIPS) are auto-generated by
#       their parent IP and MUST NOT be generated independently.
#       Using FILE_TYPE filter + .srcs path check to exclude them.
#─────────────────────────────────────────────────────────────────────────────────
set bd_files {}
catch {set bd_files [get_files -filter {FILE_TYPE == "Block Designs"} -of_objects [get_filesets sources_1]]}
foreach bd $bd_files {
    set bd_norm [file normalize $bd]
    # Skip nested sub-designs in .gen/ (auto-generated by parent IPs like Versal CIPS)
    if {[string match "*/.gen/*" $bd_norm]} {
        puts "  Skipping nested sub-design: [file tail $bd]"
        continue
    }
    # Skip generated BDs
    if {[get_property IS_GENERATED $bd] eq "1"} {
        puts "  Skipping generated BD: [file tail $bd]"
        continue
    }
    puts "  Generating targets for: [file tail $bd]"
    if {[catch {generate_target all $bd} _gt_err]} {
        puts "  ERROR: generate_target failed for [file tail $bd]: $_gt_err"
        puts "  Check the ERROR/CRITICAL WARNING lines just above for the real root"
        puts "  cause. Two known classes seen in this skill's own validation:"
        puts "    1) Debug-net (mark_debug/ILA) connections routed through a Block"
        puts "       Design Container failing to resolve on a freshly recreated"
        puts "       design ('Could not find the cell' errors) -- not an export"
        puts "       issue. Workaround: remove debug cores from the BD before"
        puts "       export, or manually regenerate targets for [file tail $bd]"
        puts "       in the GUI."
        puts "    2) A NoC memory-controller PHY IP (e.g. noc_mc_ddr5_phy_v1_0)"
        puts "       failing to generate simulation BFM outputs due to a missing"
        puts "       file under this Vivado install's own"
        puts "       data/ip/xilinx/<ip>/hdl/bfm/ tree ('Failed to copy file ..."
        puts "       it does not exist' CRITICAL WARNING) -- a Vivado installation"
        puts "       gap, not something export/rebuild can fix; report it to your"
        puts "       Vivado install owner."
    }
}

# Create OOC runs for IPs within top-level Block Designs only
foreach bd $bd_files {
    set bd_norm [file normalize $bd]
    if {[string match "*/.gen/*" $bd_norm]} { continue }
    if {[get_property IS_GENERATED $bd] eq "1"} { continue }
    catch {create_ip_run [get_ips -of_objects [get_files $bd]]}
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 10: Add Hook Scripts to utils_1 fileset
#─────────────────────────────────────────────────────────────────────────────────
set hook_scripts {}
catch {set hook_scripts [glob $base_dir/Sources/Scripts/*.tcl]}
if {[llength $hook_scripts] > 0} {
    import_files -fileset utils_1 $hook_scripts
}

#─────────────────────────────────────────────────────────────────────────────────
# Step 11: Apply Captured Project Settings
#─────────────────────────────────────────────────────────────────────────────────
source $script_dir/project_settings.tcl
set_property TOP tb_mnist_regression [get_filesets sim_1]
set_property xsim.simulate.runtime 5100us [get_filesets sim_1]
update_compile_order -fileset sources_1

#─────────────────────────────────────────────────────────────────────────────────
# Step 11b: Restore fileset source ordering (if captured)
#─────────────────────────────────────────────────────────────────────────────────
proc _rc_restore_fileset_order {fileset_name ordered_tails} {
    if {[llength [get_filesets -quiet $fileset_name]] == 0} { return }
    set last_file ""
    foreach tail $ordered_tails {
        set match {}
        catch {set match [get_files -quiet -of_objects [get_filesets $fileset_name] -filter "NAME =~ *${tail}"]}
        if {[llength $match] == 0} { continue }
        set f [lindex $match 0]
        if {$last_file eq ""} {
            catch {reorder_files -fileset $fileset_name -front $f}
        } else {
            catch {reorder_files -fileset $fileset_name -after $last_file $f}
        }
        set last_file $f
    }
    catch {update_compile_order -fileset $fileset_name}
}

_rc_restore_fileset_order ai4npu_bd_axi_ctrl_ic_0 {ai4npu_bd_axi_ctrl_ic_0.xci sc_xtlm_ai4npu_bd_axi_ctrl_ic_0.mem proc_sys_reset_v5_0_rfs.vhd sc_util_v1_0_4_constants.vh sc_util_v1_0_4_constants_noc.vh sc_util_v1_0_4_structs.svh sc_node_v1_0_19_t_reqsend.svh axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_register_slice_v2_1_rfs.v axi_vip_v1_1_vl_rfs.sv ai4npu_bd_axi_ctrl_ic_0.sv ai4npu_bd_axi_ctrl_ic_0.dcp ai4npu_bd_axi_ctrl_ic_0_stub.v ai4npu_bd_axi_ctrl_ic_0_stub.vhdl ooc.xdc smartconnect.xdc ai4npu_bd_axi_ctrl_ic_0.v}
_rc_restore_fileset_order ai4npu_bd_axi_dma_0_0 {ai4npu_bd_axi_dma_0_0.xci axi_datamover_v5_1_rfs.vhd axi_sg_v4_1_rfs.vhd ai4npu_bd_axi_dma_0_0.xdc ai4npu_bd_axi_dma_0_0_clocks.xdc axi_dma_v7_1_rfs.vhd ai4npu_bd_axi_dma_0_0.vhd ai4npu_bd_axi_dma_0_0.dcp ai4npu_bd_axi_dma_0_0_stub.v ai4npu_bd_axi_dma_0_0_stub.vhdl ai4npu_bd_axi_dma_0_0_sim_netlist.v ai4npu_bd_axi_dma_0_0_sim_netlist.vhdl ai4npu_bd_axi_dma_0_0.vhd ai4npu_bd_axi_dma_0_0_ooc.xdc}
_rc_restore_fileset_order ai4npu_bd_axi_mem_ic_0 {ai4npu_bd_axi_mem_ic_0.xci sc_post_elab.rld sc_xtlm_ai4npu_bd_axi_mem_ic_0.mem proc_sys_reset_v5_0_rfs.vhd sc_util_v1_0_4_constants.vh sc_util_v1_0_4_constants_noc.vh sc_util_v1_0_4_structs.svh sc_node_v1_0_19_t_reqsend.svh axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_register_slice_v2_1_rfs.v axi_vip_v1_1_vl_rfs.sv ai4npu_bd_axi_mem_ic_0.sv ai4npu_bd_axi_mem_ic_0.dcp ai4npu_bd_axi_mem_ic_0_stub.v ai4npu_bd_axi_mem_ic_0_stub.vhdl ooc.xdc smartconnect.xdc ai4npu_bd_axi_mem_ic_0.v}
_rc_restore_fileset_order ai4npu_bd_clk_wiz_0_0 {ai4npu_bd_clk_wiz_0_0.xci ai4npu_bd_clk_wiz_0_0_board.xdc ai4npu_bd_clk_wiz_0_0.xdc ai4npu_bd_clk_wiz_0_0_ooc.xdc mmcm_pll_drp_func_7s_mmcm.vh mmcm_pll_drp_func_7s_pll.vh mmcm_pll_drp_func_us_mmcm.vh mmcm_pll_drp_func_us_pll.vh mmcm_pll_drp_func_us_plus_pll.vh mmcm_pll_drp_func_us_plus_mmcm.vh ai4npu_bd_clk_wiz_0_0_clk_wiz.v ai4npu_bd_clk_wiz_0_0.v ai4npu_bd_clk_wiz_0_0.dcp ai4npu_bd_clk_wiz_0_0_stub.v ai4npu_bd_clk_wiz_0_0_stub.vhdl ai4npu_bd_clk_wiz_0_0_sim_netlist.v ai4npu_bd_clk_wiz_0_0_sim_netlist.vhdl}
_rc_restore_fileset_order ai4npu_bd_mnist_npu_0_0 {ai4npu_bd_mnist_npu_0_0.xci ai4npu_bd_mnist_npu_0_0.sv ai4npu_bd_mnist_npu_0_0.dcp ai4npu_bd_mnist_npu_0_0_stub.v ai4npu_bd_mnist_npu_0_0_stub.vhdl ai4npu_bd_mnist_npu_0_0_sim_netlist.v ai4npu_bd_mnist_npu_0_0_sim_netlist.vhdl ai4npu_bd_mnist_npu_0_0.sv}
_rc_restore_fileset_order ai4npu_bd_rst_ai4npu_0 {ai4npu_bd_rst_ai4npu_0.xci ai4npu_bd_rst_ai4npu_0_board.xdc proc_sys_reset_v5_0_rfs.vhd ai4npu_bd_rst_ai4npu_0.vhd ai4npu_bd_rst_ai4npu_0.dcp ai4npu_bd_rst_ai4npu_0_stub.v ai4npu_bd_rst_ai4npu_0_stub.vhdl ai4npu_bd_rst_ai4npu_0_sim_netlist.v ai4npu_bd_rst_ai4npu_0_sim_netlist.vhdl ai4npu_bd_rst_ai4npu_0.vhd ai4npu_bd_rst_ai4npu_0_ooc.xdc}
_rc_restore_fileset_order ai4npu_bd_zynq_ultra_ps_e_0_0 {ai4npu_bd_zynq_ultra_ps_e_0_0.xci axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_vip_v1_1_vl_rfs.sv zynq_ultra_ps_e_vip_v1_0_23_local_params.sv zynq_ultra_ps_e_vip_v1_0_vl_rfs.sv zynq_ultra_ps_e_vip_v1_0_23_reg_params.sv zynq_ultra_ps_e_vip_v1_0_23_reg_init.sv zynq_ultra_ps_e_vip_v1_0_23_apis.sv zynq_ultra_ps_e_vip_v1_0_23_unused_ports.sv zynq_ultra_ps_e_vip_v1_0_23_axi_gp.sv zynq_ultra_ps_e_vip_v1_0_23_axi_acp.sv zynq_ultra_ps_e_vip_v1_0_23_axi_ace.sv ai4npu_bd_zynq_ultra_ps_e_0_0_vip_wrapper.v ai4npu_bd_zynq_ultra_ps_e_0_0.dcp ai4npu_bd_zynq_ultra_ps_e_0_0_stub.v ai4npu_bd_zynq_ultra_ps_e_0_0_stub.vhdl ai4npu_bd_zynq_ultra_ps_e_0_0_sim_netlist.v ai4npu_bd_zynq_ultra_ps_e_0_0_sim_netlist.vhdl zynq_ultra_ps_e_v3_5_9.v ai4npu_bd_zynq_ultra_ps_e_0_0_ooc.xdc ai4npu_bd_zynq_ultra_ps_e_0_0.xdc ai4npu_bd_zynq_ultra_ps_e_0_0.hwdef psu_init.c psu_init.h psu_init_gpl.c psu_init_gpl.h psu_init.tcl psu_init.html ai4npu_bd_zynq_ultra_ps_e_0_0.v}
_rc_restore_fileset_order sim_1 {tb_mnist_regression.sv tb_mnist_stream_core.sv frame_0.mem expected_logits_0.mem frames_regression.mem logits_regression.mem}
_rc_restore_fileset_order sources_1 {conv2d.sv maxpool2d.sv mnist_stream_core.sv ai4npu_bd.bd ai4npu_bd_zynq_ultra_ps_e_0_0.xci axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_vip_v1_1_vl_rfs.sv zynq_ultra_ps_e_vip_v1_0_23_local_params.sv zynq_ultra_ps_e_vip_v1_0_vl_rfs.sv zynq_ultra_ps_e_vip_v1_0_23_reg_params.sv zynq_ultra_ps_e_vip_v1_0_23_reg_init.sv zynq_ultra_ps_e_vip_v1_0_23_apis.sv zynq_ultra_ps_e_vip_v1_0_23_unused_ports.sv zynq_ultra_ps_e_vip_v1_0_23_axi_gp.sv zynq_ultra_ps_e_vip_v1_0_23_axi_acp.sv zynq_ultra_ps_e_vip_v1_0_23_axi_ace.sv ai4npu_bd_zynq_ultra_ps_e_0_0_vip_wrapper.v ai4npu_bd_zynq_ultra_ps_e_0_0.dcp ai4npu_bd_zynq_ultra_ps_e_0_0_stub.v ai4npu_bd_zynq_ultra_ps_e_0_0_stub.vhdl ai4npu_bd_zynq_ultra_ps_e_0_0_sim_netlist.v ai4npu_bd_zynq_ultra_ps_e_0_0_sim_netlist.vhdl zynq_ultra_ps_e_v3_5_9.v ai4npu_bd_zynq_ultra_ps_e_0_0_ooc.xdc ai4npu_bd_zynq_ultra_ps_e_0_0.xdc ai4npu_bd_zynq_ultra_ps_e_0_0.hwdef psu_init.c psu_init.h psu_init_gpl.c psu_init_gpl.h psu_init.tcl psu_init.html ai4npu_bd_zynq_ultra_ps_e_0_0.v ai4npu_bd_axi_dma_0_0.xci axi_datamover_v5_1_rfs.vhd axi_sg_v4_1_rfs.vhd ai4npu_bd_axi_dma_0_0.xdc ai4npu_bd_axi_dma_0_0_clocks.xdc axi_dma_v7_1_rfs.vhd ai4npu_bd_axi_dma_0_0.vhd ai4npu_bd_axi_dma_0_0.dcp ai4npu_bd_axi_dma_0_0_stub.v ai4npu_bd_axi_dma_0_0_stub.vhdl ai4npu_bd_axi_dma_0_0_sim_netlist.v ai4npu_bd_axi_dma_0_0_sim_netlist.vhdl ai4npu_bd_axi_dma_0_0.vhd ai4npu_bd_axi_dma_0_0_ooc.xdc ai4npu_bd_clk_wiz_0_0.xci ai4npu_bd_clk_wiz_0_0_board.xdc ai4npu_bd_clk_wiz_0_0.xdc ai4npu_bd_clk_wiz_0_0_ooc.xdc mmcm_pll_drp_func_7s_mmcm.vh mmcm_pll_drp_func_7s_pll.vh mmcm_pll_drp_func_us_mmcm.vh mmcm_pll_drp_func_us_pll.vh mmcm_pll_drp_func_us_plus_pll.vh mmcm_pll_drp_func_us_plus_mmcm.vh ai4npu_bd_clk_wiz_0_0_clk_wiz.v ai4npu_bd_clk_wiz_0_0.v ai4npu_bd_clk_wiz_0_0.dcp ai4npu_bd_clk_wiz_0_0_stub.v ai4npu_bd_clk_wiz_0_0_stub.vhdl ai4npu_bd_clk_wiz_0_0_sim_netlist.v ai4npu_bd_clk_wiz_0_0_sim_netlist.vhdl ai4npu_bd_rst_ai4npu_0.xci ai4npu_bd_rst_ai4npu_0_board.xdc proc_sys_reset_v5_0_rfs.vhd ai4npu_bd_rst_ai4npu_0.vhd ai4npu_bd_rst_ai4npu_0.dcp ai4npu_bd_rst_ai4npu_0_stub.v ai4npu_bd_rst_ai4npu_0_stub.vhdl ai4npu_bd_rst_ai4npu_0_sim_netlist.v ai4npu_bd_rst_ai4npu_0_sim_netlist.vhdl ai4npu_bd_rst_ai4npu_0.vhd ai4npu_bd_rst_ai4npu_0_ooc.xdc ai4npu_bd_axi_ctrl_ic_0.xci sc_xtlm_ai4npu_bd_axi_ctrl_ic_0.mem proc_sys_reset_v5_0_rfs.vhd sc_util_v1_0_4_constants.vh sc_util_v1_0_4_constants_noc.vh sc_util_v1_0_4_structs.svh sc_node_v1_0_19_t_reqsend.svh axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_register_slice_v2_1_rfs.v axi_vip_v1_1_vl_rfs.sv ai4npu_bd_axi_ctrl_ic_0.sv ai4npu_bd_axi_ctrl_ic_0.dcp ai4npu_bd_axi_ctrl_ic_0_stub.v ai4npu_bd_axi_ctrl_ic_0_stub.vhdl ooc.xdc smartconnect.xdc ai4npu_bd_axi_ctrl_ic_0.v ai4npu_bd_axi_mem_ic_0.xci sc_post_elab.rld sc_xtlm_ai4npu_bd_axi_mem_ic_0.mem proc_sys_reset_v5_0_rfs.vhd sc_util_v1_0_4_constants.vh sc_util_v1_0_4_constants_noc.vh sc_util_v1_0_4_structs.svh sc_node_v1_0_19_t_reqsend.svh axi_infrastructure_v1_1_0.vh axi_infrastructure_v1_1_vl_rfs.v axi_register_slice_v2_1_rfs.v axi_vip_v1_1_vl_rfs.sv ai4npu_bd_axi_mem_ic_0.sv ai4npu_bd_axi_mem_ic_0.dcp ai4npu_bd_axi_mem_ic_0_stub.v ai4npu_bd_axi_mem_ic_0_stub.vhdl ooc.xdc smartconnect.xdc ai4npu_bd_axi_mem_ic_0.v ai4npu_bd_mnist_npu_0_0.xci ai4npu_bd_mnist_npu_0_0.sv ai4npu_bd_mnist_npu_0_0.dcp ai4npu_bd_mnist_npu_0_0_stub.v ai4npu_bd_mnist_npu_0_0_stub.vhdl ai4npu_bd_mnist_npu_0_0_sim_netlist.v ai4npu_bd_mnist_npu_0_0_sim_netlist.vhdl ai4npu_bd_mnist_npu_0_0.sv ai4npu_bd.v ai4npu_bd.v ai4npu_bd_ooc.xdc ai4npu_bd.hwh ai4npu_bd.bda ai4npu_bd.hwdef ai4npu_bd.protoinst ai4npu_bd.vho ai4npu_bd.veo ai4npu_bd_sv.sveo ai4npu_bd_wrapper.v new.v}

#─────────────────────────────────────────────────────────────────────────────────
# Step 13: Finalize Project
#─────────────────────────────────────────────────────────────────────────────────
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "──────────────────────────────────────────────────────────────────────────"
puts "Project recreated successfully!"
puts "──────────────────────────────────────────────────────────────────────────"
