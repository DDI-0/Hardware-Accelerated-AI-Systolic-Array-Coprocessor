// Agent: sa_agent
//
// Active agent containing:
//   - sa_driver    (drives skewed matrix inputs)
//   - uvm_sequencer (standard sequencer for sa_seq_item)
//   - sa_monitor   (captures DUT results)
//
// Exposes analysis ports for external connection to scoreboard & coverage.

class sa_agent extends uvm_agent;
    `uvm_component_utils(sa_agent)

    sa_driver                       drv;
    uvm_sequencer #(sa_seq_item)    sqr;
    sa_monitor                      mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = sa_driver::type_id::create("drv", this);
        sqr = uvm_sequencer #(sa_seq_item)::type_id::create("sqr", this);
        mon = sa_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass
