# Vivado Revision Control Export

This directory is organized for git check-in.

## Check In
- Sources/
- Scripts/
- .gitignore
- README.md
- Sources/Constraints/ (includes DFX pblock constraints if present)
- Sources/Checkpoints/ if present and intentionally versioned
- Sources/NoC/ if present

Note: <proj_name>.xpr is intentionally NOT part of this export or check-in --
this skill recreates the project deterministically via Scripts/build.tcl
instead of revision-controlling the XPR itself.

## Do Not Check In
- .Xil/
- *.jou, *.log, vivado*.backup.*
- ai4npu.cache/
- ai4npu.gen/
- ai4npu.hw/
- ai4npu.ip_user_files/
- ai4npu.runs/
- ai4npu.sim/
- ai4npu.srcs/

## Recreate
Run Vivado in batch mode with Scripts/build.tcl to recreate the project from the checked-in sources.
