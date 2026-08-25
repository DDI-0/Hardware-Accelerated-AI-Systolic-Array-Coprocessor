// Driver: sa_driver
//
// Receives sa_seq_item transactions and drives them into the DUT with the
// correct skewed/staggered timing:
//
//   Feed A[r][k] at cycle (k + r)    -- row r delayed by r cycles
//   Feed B[k][c] at cycle (k + c)    -- col c delayed by c cycles
//
// After feeding, flushes the pipeline and de-asserts compute_en.
// Broadcasts driven items via an analysis port (-> scoreboard, coverage).

class sa_driver extends uvm_driver #(sa_seq_item);
    `uvm_component_utils(sa_driver)

    virtual sa_if vif;

    // Analysis port -- broadcasts input items to scoreboard & coverage
    uvm_analysis_port #(sa_seq_item) drv_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv_ap = new("drv_ap", this);
        if (!uvm_config_db#(virtual sa_if)::get(this, "", "vif", vif))
            `uvm_fatal("NO_VIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        // Initialize outputs
        vif.rst_n      <= 1'b0;
        vif.compute_en <= 1'b0;
        vif.a_in       <= '0;
        vif.b_in       <= '0;
        @(posedge vif.clk);

        forever begin
            sa_seq_item item;
            seq_item_port.get_next_item(item);
            drive_item(item);
            drv_ap.write(item);              // broadcast to scoreboard & coverage
            seq_item_port.item_done();
        end
    endtask

    // Drive one complete matrix multiplication transaction
    task drive_item(sa_seq_item item);
        int k;

        // ---- 1. Reset (clears all PE accumulators) ----
        vif.rst_n      <= 1'b0;
        vif.compute_en <= 1'b0;
        vif.a_in       <= '0;
        vif.b_in       <= '0;
        repeat (3) @(posedge vif.clk);
        vif.rst_n <= 1'b1;
        @(posedge vif.clk);

        // ---- 2. Feed skewed data for 2*N - 1 cycles ----
        vif.compute_en <= 1'b1;

        for (int t = 0; t < 2 * SA_N - 1; t++) begin
            for (int i = 0; i < SA_N; i++) begin
                k = t - i;
                // A: row i, column k  (row i delayed by i cycles)
                if (k >= 0 && k < SA_N)
                    vif.a_in[i*SA_DATA_WIDTH +: SA_DATA_WIDTH] <= item.mat_a[i][k];
                else
                    vif.a_in[i*SA_DATA_WIDTH +: SA_DATA_WIDTH] <= '0;

                // B: row k, column i  (col i delayed by i cycles)
                if (k >= 0 && k < SA_N)
                    vif.b_in[i*SA_DATA_WIDTH +: SA_DATA_WIDTH] <= item.mat_b[k][i];
                else
                    vif.b_in[i*SA_DATA_WIDTH +: SA_DATA_WIDTH] <= '0;
            end
            @(posedge vif.clk);
        end

        // ---- 3. Zero inputs, flush pipeline (N+1 extra cycles) ----
        vif.a_in <= '0;
        vif.b_in <= '0;
        repeat (SA_N + 1) @(posedge vif.clk);

        // ---- 4. De-assert compute_en ----
        vif.compute_en <= 1'b0;
        @(posedge vif.clk);
    endtask

endclass
