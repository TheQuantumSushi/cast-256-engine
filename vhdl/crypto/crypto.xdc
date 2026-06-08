## ============================================================================
## crypto.xdc - Physical constraints for the Zybo Z7-10 (xc7z010clg400-1)
##
## Only the ports exposed by the crypto entity are constrained here:
##   sw[3:0]   - slide switches
##   btn[3:0]  - push buttons
##   led[3:0]  - user LEDs
##
## The clock (aclk) is driven by PS FCLK_CLK0 and constrained inside the
## block design (Vivado sets it automatically from the PS clock wizard).
##
## aresetn comes from the Processing System Reset IP - also inside the BD.
##
## AXI ports (s0_axi_*, m0_axi_*) connect to the PS AXI fabric and are
## constrained by the PS block design, not here.
##
## irq connects to the PS fabric interrupt input - wired in the block design.
## ============================================================================

## ----------------------------------------------------------------------------
## Slide switches  (LVCMOS33, no pull - driven by the board's resistors)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN G15  IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN P15  IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W13  IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN T16  IOSTANDARD LVCMOS33} [get_ports {sw[3]}]

## ----------------------------------------------------------------------------
## Push buttons  (LVCMOS33, active high, debounced on the board)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN K18  IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN P16  IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN K19  IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN Y16  IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

## ----------------------------------------------------------------------------
## User LEDs  (LVCMOS33, drive strength 8 mA)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN M14  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN M15  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN G14  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN D18  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
