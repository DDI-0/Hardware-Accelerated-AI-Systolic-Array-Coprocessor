// Interface: sa_if
//
// Signal-level interface bundling all systolic array DUT ports.
// Used by UVM driver and monitor via virtual interface handle.

interface sa_if #(
    parameter int N          = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(input logic clk);

    logic                          rst_n;
    logic                          compute_en;
    logic [N*DATA_WIDTH-1:0]       a_in;
    logic [N*DATA_WIDTH-1:0]       b_in;
    logic [N*DATA_WIDTH-1:0]       a_out;
    logic [N*DATA_WIDTH-1:0]       b_out;
    logic [N*N*ACC_WIDTH-1:0]      result;

endinterface
