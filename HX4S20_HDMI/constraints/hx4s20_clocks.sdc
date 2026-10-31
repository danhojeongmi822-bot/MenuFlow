# Basic clocks only: full IO/CDC timing signoff is a separate task.
create_clock -name clk_50m -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
derive_clocks
