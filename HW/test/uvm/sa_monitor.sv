// Monitor: sa_monitor
//
// Watches the compute_en signal for a complete transaction cycle:
//   1. Waits for compute_en to rise  (driver starts feeding)
//   2. Waits for compute_en to fall  (driver finished + pipeline flushed)
//   3. Captures the result bus and unpacks it into an NxN matrix
//   4. Broadcasts sa_result_txn via analysis port (-> scoreboard)

class sa_monitor extends uvm_monitor;
    `uvm_component_utils(sa_monitor)

    virtual sa_if vif;

    // Analysis port -- broadcasts captured results to scoreboard
    uvm_analysis_port #(sa_result_txn) mon_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon_ap = new("mon_ap", this);
        if (!uvm_config_db#(virtual sa_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            capture_result();
        end
    endtask

    // Wait for a complete transaction, then capture the result matrix
    task capture_result();
        sa_result_txn txn;
        int idx;

        // Wait for computation to start
        @(posedge vif.compute_en);

        // Wait for computation to complete (driver drops compute_en)
        @(negedge vif.compute_en);

        // Results are stable now (PE accumulators hold their values)
        txn = sa_result_txn::type_id::create("result_txn");

        for (int r = 0; r < SA_N; r++) begin
            for (int c = 0; c < SA_N; c++) begin
                idx = r * SA_N + c;
                txn.result[r][c] = vif.result[idx*SA_ACC_WIDTH +: SA_ACC_WIDTH];
            end
        end

        `uvm_info(get_type_name(),
            $sformatf("Captured result matrix%s", txn.convert2string()), UVM_HIGH)

        mon_ap.write(txn);
    endtask

endclass
