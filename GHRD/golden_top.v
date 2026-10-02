// ============================================================================
// Copyright (c) 2025 by Terasic Technologies Inc.
// ============================================================================
//
// Permission:
//
//   Terasic grants permission to use and modify this code for use
//   in synthesis for all Terasic Development Boards and Altera Development
//   Kits made by Terasic.  Other use of this code, including the selling
//   ,duplication, or modification of any portion is strictly prohibited.
//
// Disclaimer:
//
//   This VHDL/Verilog or C/C++ source code is intended as a design reference
//   which illustrates how these types of functions can be implemented.
//   It is the user's responsibility to verify their design for
//   consistency and functionality through the use of formal
//   verification methods.  Terasic provides no warranty regarding the use
//   or functionality of this code.
//
// ============================================================================
//
//  Terasic Technologies Inc
//  No.80, Fenggong Rd., Hukou Township, Hsinchu County 303035. Taiwan
//
//
//                     web: http://www.terasic.com/
//                     email: support@terasic.com
//
// ============================================================================
//Date:  Wed Apr 23 19:05:55 2025
// ============================================================================

`define ENABLE_DDR4
`define ENABLE_HPS
//`define ENABLE_HDMI
//`define ENABLE_HSMC
//`define ENABLE_CAM

module golden_top(

      ///////// CLOCK /////////
      input              CLOCK0_50,
      input              CLOCK1_50,
      input              CLOCK2_50,

      ///////// KEY /////////
      input              CPU_RESET_n,
      input    [ 3: 0]   KEY,

      ///////// SW /////////
      input    [ 9: 0]   SW,

      ///////// LED /////////
      output   [ 9: 0]   LEDR,

      ///////// Seg7 /////////
      output   [ 6: 0]   HEX0,
      output   [ 6: 0]   HEX1,
      output   [ 6: 0]   HEX2,
      output   [ 6: 0]   HEX3,
      output   [ 6: 0]   HEX4,
      output   [ 6: 0]   HEX5,

      ///////// SDRAM /////////
      output             DRAM_CLK,
      output             DRAM_CKE,
      output   [12: 0]   DRAM_ADDR,
      output   [ 1: 0]   DRAM_BA,
      inout    [15: 0]   DRAM_DQ,
      output             DRAM_LDQM,
      output             DRAM_UDQM,
      output             DRAM_CS_n,
      output             DRAM_WE_n,
      output             DRAM_CAS_n,
      output             DRAM_RAS_n,

`ifdef ENABLE_DDR4
      ///////// DDR4 /////////
      input              DDR4_REFCLK_p,
      output   [16: 0]   DDR4_A,
      output   [ 1: 0]   DDR4_BA,
      output   [ 0: 0]   DDR4_BG,
      output             DDR4_CK,
      output             DDR4_CK_n,
      output             DDR4_CKE,
      inout    [ 3: 0]   DDR4_DQS,
      inout    [ 3: 0]   DDR4_DQS_n,
      inout    [31: 0]   DDR4_DQ,
      inout    [ 3: 0]   DDR4_DBI_n,
      output             DDR4_CS_n,
      output             DDR4_RESET_n,
      output             DDR4_ODT,
      output             DDR4_PAR,
      input              DDR4_ALERT_n,
      output             DDR4_ACT_n,
      input              DDR4_RZQ,
`endif /*ENABLE_DDR4*/

      ///////// Video-In /////////
      input              TD_CLK27,
      input              TD_HS,
      input              TD_VS,
      input    [ 7: 0]   TD_DATA,
      output             TD_RESET_n,

`ifdef ENABLE_HDMI
      ///////// HDMI /////////
      inout              HDMI_LRCLK,
      inout              HDMI_MCLK,
      inout              HDMI_SCLK,
      output             HDMI_TX_CLK,
      output             HDMI_TX_HS,
      output             HDMI_TX_VS,
      output   [23: 0]   HDMI_TX_D,
      output             HDMI_TX_DE,
      input              HDMI_TX_INT,
      inout              HDMI_I2S,
`endif /*ENABLE_HDMI*/

      ///////// Audio /////////
      inout              AUD_BCLK,
      output             AUD_XCK,
      inout              AUD_ADCLRCK,
      input              AUD_ADCDAT,
      inout              AUD_DACLRCK,
      output             AUD_DACDAT,

      ///////// ADC /////////
      output             ADC_SCK,
      input              ADC_SDO,
      output             ADC_SDI,
      output             ADC_CS_n,

      ///////// I2C for Camera, Audio, Video-In, Temerature Sensor and Fan Control /////////
      inout              FPGA_I2C_SCLK,
      inout              FPGA_I2C_SDAT,

      ///////// GPIO /////////
      inout    [35: 0]   GPIO_D,

`ifdef ENABLE_HSMC
      ///////// HSMC /////////
      output   [ 3: 0]   HSMC_GTS_TX_p,
      output   [ 3: 0]   HSMC_GTS_TX_n,
      input    [ 3: 0]   HSMC_GTS_RX_p,
      input    [ 3: 0]   HSMC_GTS_RX_n,
      input              HSMC_GTS_RX_REFCLK_p,
      output             HSMC_I2C_SCL,
      inout              HSMC_I2C_SDA,
      input    [ 2: 0]   HSMC_CLK_IN,
      input              HSMC_GTS_REFCLK_p,
      inout    [ 1: 0]   HSMC_B5B_D,
      inout    [76: 0]   HSMC_D,
`endif /*ENABLE_HSMC*/

`ifdef ENABLE_CAM
      ///////// CAM /////////
      input              CAM_CLK_p,
      input              CAM_CLK_n,
      input    [ 1: 0]   CAM_D_p,
      input    [ 1: 0]   CAM_D_n,
      inout              CAM_GPIO,
      input              CAM_RZQ1,
`endif /*ENABLE_CAM*/

`ifdef ENABLE_HPS
      ///////// HPS /////////
      input              HPS_CLK_25,
      output             HPS_ENET_MDC,
      inout              HPS_ENET_MDIO,
      input              HPS_ENET_RX_CLK,
      input              HPS_ENET_RX_CTL,
      input    [ 3: 0]   HPS_ENET_RX_DATA,
      output             HPS_ENET_TX_CLK,
      output             HPS_ENET_TX_CTL,
      output   [ 3: 0]   HPS_ENET_TX_DATA,
      inout    [ 1: 0]   HPS_GPIO,
      inout              HPS_GSENSOR_INT,
      inout              HPS_I2C_SCL,
      inout              HPS_I2C_SDA,
      inout              HPS_KEY,
      inout              HPS_LCM_BK,
      inout              HPS_LCM_D_C,
      inout              HPS_LCM_RST_n,
      output             HPS_LCM_SPIM_CLK,
      output             HPS_LCM_SPIM_MOSI,
      output             HPS_LCM_SPIM_SS,
      inout              HPS_LED,
      output             HPS_SD_CLK,
      inout              HPS_SD_CMD,
      inout    [ 3: 0]   HPS_SD_DATA,
      input              HPS_UART_RX,
      output             HPS_UART_TX,
      input              HPS_USB_CLK,
      inout    [ 7: 0]   HPS_USB_DATA,
      input              HPS_USB_DIR,
      input              HPS_USB_NXT,
      output             HPS_USB_STP,
`endif /*ENABLE_HPS*/

      ///////// IR /////////
      output             IRDA_TXD,
      input              IRDA_RXD

);


wire                   system_clk_50;
wire                   system_clk_100_internal;
wire                   ninit_done;
wire                   fpga_reset_n_debounced_wire;
reg                    fpga_reset_n_debounced;
wire                   system_reset_n;
//wire                 h2f_reset;

assign                 system_reset_n = fpga_reset_n_debounced & ~ninit_done;

//assign               system_reset_n = fpga_reset_n_debounced & ~h2f_reset & ~ninit_done;

assign                 system_clk_50   = CLOCK2_50;

//assign                 system_clk_100_internal  = system_clk_100;
pll pll_inst (
.refclk   (system_clk_50),
.locked   (),
.rst      (ninit_done),
.outclk_0 (system_clk_100_internal)
);

assign                 FPGA_I2C_SCLK = 1'bZ;
assign                 FPGA_I2C_SDAT = 1'bZ;
assign                 TD_RESET_n = 1'b0;

wire [10-1:0]          fpga_led_pio;
wire [10-1:0]          fpga_dipsw_pio;
wire [10-1:0]          fpga_button_pio;
wire                   fpga_reset_n;
assign                 LEDR = fpga_led_pio;
assign                 fpga_dipsw_pio = SW;
assign                 fpga_button_pio = KEY;
assign                 fpga_reset_n = CPU_RESET_n;

wire [10-1:0]          fpga_debounced_buttons;
wire [10-2:0]          fpga_led_internal;
wire                   heartbeat_led;
reg  [24:0]            heartbeat_count;
assign                 heartbeat_led = ~heartbeat_count[24];
assign                 fpga_led_pio = {heartbeat_led,fpga_led_internal};


// Todo no longer needed
//wire [31:0]            f2h_irq1_irq;

// Todo no longer needed
//assign                 f2h_irq1_irq    = {32'b0};

// Qsys Top module
qsys_top soc_inst (
.clk_100_clk                               (system_clk_100_internal),
.ninit_done_ninit_done                     (ninit_done),
.led_pio_external_connection_in_port       (fpga_led_internal),
.led_pio_external_connection_out_port      (fpga_led_internal),
.dipsw_pio_external_connection_export      (fpga_dipsw_pio),
.button_pio_external_connection_export     (fpga_debounced_buttons),

.emif_hps_emif_mem_ck_0_mem_ck_t           (DDR4_CK),
.emif_hps_emif_mem_ck_0_mem_ck_c           (DDR4_CK_n),
.emif_hps_emif_mem_0_mem_a                 (DDR4_A),
.emif_hps_emif_mem_0_mem_act_n             (DDR4_ACT_n),
.emif_hps_emif_mem_0_mem_ba                (DDR4_BA),
.emif_hps_emif_mem_0_mem_bg                (DDR4_BG),
.emif_hps_emif_mem_0_mem_cke               (DDR4_CKE),
.emif_hps_emif_mem_0_mem_cs_n              (DDR4_CS_n),
.emif_hps_emif_mem_0_mem_odt               (DDR4_ODT),
.emif_hps_emif_mem_reset_n_mem_reset_n     (DDR4_RESET_n),
.emif_hps_emif_mem_0_mem_par               (DDR4_PAR),
.emif_hps_emif_mem_0_mem_alert_n           (DDR4_ALERT_n),
.emif_hps_emif_mem_0_mem_dqs_t             (DDR4_DQS),
.emif_hps_emif_mem_0_mem_dqs_c             (DDR4_DQS_n),
.emif_hps_emif_mem_0_mem_dbi_n             (DDR4_DBI_n),
.emif_hps_emif_mem_0_mem_dq                (DDR4_DQ),
.emif_hps_emif_oct_0_oct_rzqin             (DDR4_RZQ),
.emif_hps_emif_ref_clk_0_clk               (DDR4_REFCLK_p),
.hps_io_emac0_tx_clk                       (HPS_ENET_TX_CLK),
.hps_io_emac0_rx_clk                       (HPS_ENET_RX_CLK),
.hps_io_emac0_tx_ctl                       (HPS_ENET_TX_CTL),
.hps_io_emac0_rx_ctl                       (HPS_ENET_RX_CTL),
.hps_io_emac0_txd0                         (HPS_ENET_TX_DATA[0]),
.hps_io_emac0_txd1                         (HPS_ENET_TX_DATA[1]),
.hps_io_emac0_rxd0                         (HPS_ENET_RX_DATA[0]),
.hps_io_emac0_rxd1                         (HPS_ENET_RX_DATA[1]),
.hps_io_emac0_txd2                         (HPS_ENET_TX_DATA[2]),
.hps_io_emac0_txd3                         (HPS_ENET_TX_DATA[3]),
.hps_io_emac0_rxd2                         (HPS_ENET_RX_DATA[2]),
.hps_io_emac0_rxd3                         (HPS_ENET_RX_DATA[3]),
.hps_io_mdio0_mdio                         (HPS_ENET_MDIO),
.hps_io_mdio0_mdc                          (HPS_ENET_MDC),
.hps_io_sdmmc_cclk                         (HPS_SD_CLK),
.hps_io_sdmmc_cmd                          (HPS_SD_CMD),
.hps_io_sdmmc_data0                        (HPS_SD_DATA[0]),
.hps_io_sdmmc_data1                        (HPS_SD_DATA[1]),
.hps_io_sdmmc_data2                        (HPS_SD_DATA[2]),
.hps_io_sdmmc_data3                        (HPS_SD_DATA[3]),
.hps_io_uart1_rx                           (HPS_UART_RX),
.hps_io_uart1_tx                           (HPS_UART_TX),
.hps_io_usb0_clk                           (HPS_USB_CLK),
.hps_io_usb0_stp                           (HPS_USB_STP),
.hps_io_usb0_dir                           (HPS_USB_DIR),
// Todo clarify for NXT or NXR
.hps_io_usb0_nxt                           (HPS_USB_NXT),
.hps_io_usb0_data0                         (HPS_USB_DATA[0]),
.hps_io_usb0_data1                         (HPS_USB_DATA[1]),
.hps_io_usb0_data2                         (HPS_USB_DATA[2]),
.hps_io_usb0_data3                         (HPS_USB_DATA[3]),
.hps_io_usb0_data4                         (HPS_USB_DATA[4]),
.hps_io_usb0_data5                         (HPS_USB_DATA[5]),
.hps_io_usb0_data6                         (HPS_USB_DATA[6]),
.hps_io_usb0_data7                         (HPS_USB_DATA[7]),
.hps_io_i2c1_sda                           (HPS_I2C_SDA),
.hps_io_i2c1_scl                           (HPS_I2C_SCL),
.hps_io_gpio28                             (HPS_GSENSOR_INT),
.hps_io_spim0_clk                          (HPS_LCM_SPIM_CLK),
.hps_io_spim0_mosi                         (HPS_LCM_SPIM_MOSI),
.hps_io_spim0_ss0_n                        (HPS_LCM_SPIM_SS),
.hps_io_gpio34                             (HPS_LCM_RST_n),
.hps_io_gpio35                             (HPS_LCM_D_C),
.hps_io_gpio42                             (HPS_LCM_BK),
.hps_io_gpio32                             (HPS_GPIO[0]),
.hps_io_gpio33                             (HPS_GPIO[1]),
.hps_io_gpio40                             (HPS_KEY),
.hps_io_gpio41                             (HPS_LED),
// Todo nolonger export to top
//.f2h_irq1_irq                              (f2h_irq1_irq),
.hps_io_hps_osc_clk                        (HPS_CLK_25),

//.h2f_reset_reset                           (h2f_reset),

.reset_reset_n                             (system_reset_n)
);

// debounce fpga_reset_n
debounce fpga_reset_n_debounce_inst (
.clk                                       (system_clk_100_internal),
.reset_n                                   (~ninit_done),
.data_in                                   (fpga_reset_n),
.data_out                                  (fpga_reset_n_debounced_wire)
);
defparam fpga_reset_n_debounce_inst.WIDTH = 1;
defparam fpga_reset_n_debounce_inst.POLARITY = "LOW";
defparam fpga_reset_n_debounce_inst.TIMEOUT = 10000;               // at 100Mhz this is a debounce time of 1ms
defparam fpga_reset_n_debounce_inst.TIMEOUT_WIDTH = 32;            // ceil(log2(TIMEOUT))

always @ (posedge system_clk_100_internal or posedge ninit_done)
begin
    if (ninit_done == 1'b1)
        fpga_reset_n_debounced <= 1'b0;
    else
        fpga_reset_n_debounced <= fpga_reset_n_debounced_wire;
end

// Debounce logic to clean out glitches within 1ms
debounce debounce_inst (
.clk                                       (system_clk_100_internal),
.reset_n                                   (system_reset_n),
.data_in                                   (fpga_button_pio),
.data_out                                  (fpga_debounced_buttons)
);
defparam debounce_inst.WIDTH = 10;
defparam debounce_inst.POLARITY = "LOW";
defparam debounce_inst.TIMEOUT = 10000;               // at 100Mhz this is a debounce time of 1ms
defparam debounce_inst.TIMEOUT_WIDTH = 32;            // ceil(log2(TIMEOUT))

always @(posedge system_clk_100_internal or negedge system_reset_n) begin
  if (~system_reset_n)
    heartbeat_count <= 25'd0;
  else
    heartbeat_count <= heartbeat_count + 25'd1;
end


BOARD_MANAGEMENT u_BOARD_MANAGEMENT(
                 .I2C_READY(I2C_READY),
/*input*/        .clk_50 (CLOCK0_50),
/*input*/        .reset_n(KEY[0]),
 
// device i2c interface
/*inout*/        .I2C_SCL(FPGA_I2C_SCLK),
/*inout*/        .I2C_SDA(FPGA_I2C_SDAT),
 
/*input        */.Auto_Fan_Speed(1'b1) // 1: enable audo speed control.0: user specify fan speed
);


endmodule
