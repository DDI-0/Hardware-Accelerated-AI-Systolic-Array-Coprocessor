// Top Module: sa_top
//
// Questa mixed-language testbench top:
//   1. Generates clock
//   2. Instantiates sa_if interface
//   3. Instantiates VHDL systolic_array DUT (generics overridden via vsim -g)
//   4. Passes virtual interface to UVM via config_db
//   5. Calls run_test() -- test name from +UVM_TESTNAME plusarg
//
// Usage:
//   vsim -g/sa_top/u_dut/SIGNED_ARITH=false +UVM_TESTNAME=sa_unsigned_test ...
//   vsim -g/sa_top/u_dut/SIGNED_ARITH=true  +UVM_TESTNAME=sa_signed_test  ...

module sa_top;

    import uvm_pkg::*;
    import sa_pkg::*;

    // Clock generation
    localparam CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Interface
    sa_if #(
        .N         (SA_N),
        .DATA_WIDTH(SA_DATA_WIDTH),
        .ACC_WIDTH (SA_ACC_WIDTH)
    ) vif (clk);

    // DUT -- VHDL entity (mixed-language)
    //
    // SIGNED_ARITH generic is overridden at vsim time:
    //   vsim -g/sa_top/u_dut/SIGNED_ARITH=true  ...   (signed mode)
    //   vsim -g/sa_top/u_dut/SIGNED_ARITH=false ...   (unsigned mode)
    systolic_array u_dut (
        .clk        (clk),
        .rst_n      (vif.rst_n),
        .compute_en (vif.compute_en),
        .a_in       (vif.a_in),
        .b_in       (vif.b_in),
        .a_out      (vif.a_out),
        .b_out      (vif.b_out),
        .result     (vif.result)
    );

    // UVM launch
    initial begin
        // Pass virtual interface to all UVM components
        uvm_config_db#(virtual sa_if)::set(null, "*", "vif", vif);

        // Run test (selected by +UVM_TESTNAME=<test_class>)
        run_test();
    end

    // Safety timeout
    initial begin
        #1ms;
        `uvm_fatal("TIMEOUT", "Simulation exceeded 1ms -- possible hang")
    end

endmodule
