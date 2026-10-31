set base [file normalize [file join [file dirname [info script]] ..]]
cd $base
file mkdir build_hx4s20
file mkdir HX4S20_HDMI_Config_Runs/phy_1
import_device eagle_s20.db -package EG4S20BG256
open_project HX4S20_HDMI_Config.al -single_run
elaborate -top hx4s20_board_top
read_adc constraints/hx4s20_hdmi_a.adc
optimize_rtl
read_sdc constraints/hx4s20_clocks.sdc
optimize_gate
legalize_phy_inst
read_sdc constraints/hx4s20_clocks.sdc
export_db build_hx4s20/gate.db
write_verilog build_hx4s20/gate.v
report_area -file build_hx4s20/gate.area
puts {HX4S20_SYNTHESIS_FINISHED}
place
report_area -io_info -file build_hx4s20/place.area
route
export_db build_hx4s20/route.db
report_area -io_info -file HX4S20_HDMI_Config_Runs/phy_1/HX4S20_HDMI_Config_phy.area
update_timing -mode final
report_timing_summary -file HX4S20_HDMI_Config_Runs/phy_1/final_timing.rpt
report_timing_status -file HX4S20_HDMI_Config_Runs/phy_1/timing_status.rpt
bitgen -bit HX4S20_HDMI_Config_Runs/phy_1/HX4S20_HDMI_Config.bit
puts {HX4S20_BITGEN_FINISHED}
close_project
exit
