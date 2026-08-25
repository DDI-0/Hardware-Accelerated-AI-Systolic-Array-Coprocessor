# ==============================================================================
# SDC Constraints for system_top
# ==============================================================================

# ------------------------------------------------------------------------------
# Primary clock: 50 MHz (CLOCK_50 on board, 20 ns period)
# ------------------------------------------------------------------------------
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

# ------------------------------------------------------------------------------
# Input delay on reset push-button (asynchronous, but constrain loosely)
# ------------------------------------------------------------------------------
set_input_delay  -clock clk_50 -max 5.0 [get_ports {RESET_N}]
set_input_delay  -clock clk_50 -min 0.0 [get_ports {RESET_N}]

# ------------------------------------------------------------------------------
# Output delays on LED indicators
# ------------------------------------------------------------------------------
set_output_delay -clock clk_50 -max 5.0 [get_ports {LED_IRQ LED_DMA0 LED_DMA1 LED_RESET}]
set_output_delay -clock clk_50 -min 0.0 [get_ports {LED_IRQ LED_DMA0 LED_DMA1 LED_RESET}]

# ------------------------------------------------------------------------------
# All Avalon-MM, Avalon-ST, and internal signals are now inside the
# Platform Designer system — no external I/O delay constraints needed.
# The interconnect is fully synchronous to clk_50.
# ------------------------------------------------------------------------------
