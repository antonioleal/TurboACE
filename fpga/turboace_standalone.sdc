// TurboACE standalone build: clocks (rtl/top_standalone.v, rtl/gowin.v). All come
// from one PLL with their edges aligned: 54 MHz system, 135 MHz TMDS, 27 MHz pixel
// (exactly half of 54 MHz). The 54 -> 27 MHz crossings (the pixel, the HDMI reset)
// change on the 54 MHz edge where the pixel clock falls, so they have a whole 54 MHz
// cycle (18.5 ns) before the pixel clock takes them.
create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
create_clock -name clk54 -period 18.519 [get_nets {clk}]
create_clock -name clk135 -period 7.407 [get_nets {clk_pixel_x5}]
create_clock -name clk27 -period 37.037 [get_pins {clocks/div27/CLKOUT}]
// the 48 kHz audio clock (audio.v, from 54 MHz): hdl-util/hdmi takes its samples into
// the pixel clock with its own handshake, so the two are unrelated for timing
create_clock -name clk_audio -period 20833.333 [get_nets {clk_audio_Z}]
set_clock_groups -asynchronous -group [get_clocks {clk_audio}] -group [get_clocks {clk27}]
// The T80 (rtl/ace_core.v): its registers, its microcode block RAM and its register
// file RAMs change only on its clock enables, 8 or more clocks apart, and the bus
// takes its outputs into t_held two clocks after each enable; so paths from the T80
// to the T80 or to t_held have two clocks. Checked in simulation by
// make -C fpga system-slow (every T80 output garbled for its first clock). Patterns:
// one per level of hierarchy ('*' does not cross '/'), on pins (block RAM and
// distributed RAM are not registers to get_regs); only the data, enable and write
// pins as ends (every pin makes the timing engine run for over half an hour).
set_multicycle_path 2 -end -setup -from [get_pins {ace/cpu/*/*/CLK ace/cpu/*/*/*/CLK ace/cpu/*/*/*/*/CLK}] -to [get_pins {ace/cpu/*/*/D ace/cpu/*/*/CE ace/cpu/*/*/*/D ace/cpu/*/*/*/CE ace/cpu/*/*/Regs/*/DI* ace/cpu/*/*/Regs/*/WAD* ace/cpu/*/*/Regs/*/WRE}]
set_multicycle_path 1 -end -hold  -from [get_pins {ace/cpu/*/*/CLK ace/cpu/*/*/*/CLK ace/cpu/*/*/*/*/CLK}] -to [get_pins {ace/cpu/*/*/D ace/cpu/*/*/CE ace/cpu/*/*/*/D ace/cpu/*/*/*/CE ace/cpu/*/*/Regs/*/DI* ace/cpu/*/*/Regs/*/WAD* ace/cpu/*/*/Regs/*/WRE}]
set_multicycle_path 2 -end -setup -from [get_pins {ace/cpu/*/*/CLK ace/cpu/*/*/*/CLK ace/cpu/*/*/*/*/CLK}] -to [get_regs {ace/t_held*}]
set_multicycle_path 1 -end -hold  -from [get_pins {ace/cpu/*/*/CLK ace/cpu/*/*/*/CLK ace/cpu/*/*/*/*/CLK}] -to [get_regs {ace/t_held*}]
