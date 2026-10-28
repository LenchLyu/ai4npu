# Run with Vivado 2026.1 and the local vivado-revision-control skill installed.
# The generated RevisionControl/Scripts/build.tcl does not depend on the skill.
set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root ai4npu.xpr]
source [file join $::env(USERPROFILE) .codex skills vivado-revision-control helper-procedures helper_scripts.tcl]
set flow_info [detect_project_flow]
set scenario_info [analyze_source_locations]
set export_dir [file join $project_root RevisionControl]
set no_cached_outputs [dict create enabled 0 ips {} bds {} cache_dir {}]
export_all_sources $export_dir $flow_info $no_cached_outputs
file mkdir [file join $export_dir Scripts]
capture_project_settings [file join $export_dir Scripts project_settings.tcl]
generate_build_script [file join $export_dir Scripts build.tcl] $export_dir $scenario_info
capture_verification_manifest [file join $export_dir Scripts verification_manifest.tcl] $export_dir
close_project
