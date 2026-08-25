// Environment: sa_env
//
// Top-level UVM environment containing:
//   - sa_agent       (driver + sequencer + monitor)
//   - sa_scoreboard  (golden model comparison)
//   - sa_coverage    (functional coverage)
//
// Wires all analysis ports in connect_phase.

class sa_env extends uvm_env;
    `uvm_component_utils(sa_env)

    sa_agent      agent;
    sa_scoreboard scoreboard;
    sa_coverage   coverage;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent      = sa_agent::type_id::create("agent", this);
        scoreboard = sa_scoreboard::type_id::create("scoreboard", this);
        coverage   = sa_coverage::type_id::create("coverage", this);
    endfunction

    // Wire analysis ports:
    //   driver.drv_ap  --> scoreboard.input_fifo   (input matrices + golden)
    //   driver.drv_ap  --> coverage                (sample coverage)
    //   monitor.mon_ap --> scoreboard.output_fifo  (actual DUT results)
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Driver -> scoreboard (input items with golden expected)
        agent.drv.drv_ap.connect(scoreboard.input_fifo.analysis_export);

        // Driver -> coverage (sample element & matrix coverage)
        agent.drv.drv_ap.connect(coverage.analysis_export);

        // Monitor -> scoreboard (actual DUT results)
        agent.mon.mon_ap.connect(scoreboard.output_fifo.analysis_export);
    endfunction

endclass
