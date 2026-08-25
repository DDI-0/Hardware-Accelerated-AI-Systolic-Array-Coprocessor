// Package: sa_pkg
//
// Imports UVM and includes all systolic array verification components
// in dependency order.
//
// Compile with:  vlog -sv +incdir+test/uvm test/uvm/sa_pkg.sv

package sa_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Global parameters (match DUT defaults)
    localparam int SA_N          = 4;
    localparam int SA_DATA_WIDTH = 8;
    localparam int SA_ACC_WIDTH  = 32;

    // UVM components (order matters for dependencies)
    `include "sa_seq_item.sv"
    `include "sa_sequences.sv"
    `include "sa_driver.sv"
    `include "sa_monitor.sv"
    `include "sa_coverage.sv"
    `include "sa_scoreboard.sv"
    `include "sa_agent.sv"
    `include "sa_env.sv"
    `include "sa_test.sv"

endpackage
