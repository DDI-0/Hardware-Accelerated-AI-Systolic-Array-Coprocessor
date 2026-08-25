// Scoreboard: sa_scoreboard
//
// Implements a self-checking golden model for matrix multiplication.
//
// Two TLM FIFOs:
//   input_fifo   <-- receives sa_seq_item  from driver  (mat_a, mat_b, mat_c golden)
//   output_fifo  <-- receives sa_result_txn from monitor (actual DUT result)
//
// Pairs them in order and does element-by-element comparison.
// Reports per-element PASS/FAIL and a summary in report_phase.

class sa_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(sa_scoreboard)

    uvm_tlm_analysis_fifo #(sa_seq_item)   input_fifo;
    uvm_tlm_analysis_fifo #(sa_result_txn) output_fifo;

    int unsigned num_compared = 0;
    int unsigned num_passed   = 0;
    int unsigned num_failed   = 0;

    bit signed_mode;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        input_fifo  = new("input_fifo",  this);
        output_fifo = new("output_fifo", this);

        if (!uvm_config_db#(bit)::get(this, "", "signed_mode", signed_mode))
            signed_mode = 0;
    endfunction

    task run_phase(uvm_phase phase);
        sa_seq_item   in_item;
        sa_result_txn out_item;

        forever begin
            input_fifo.get(in_item);
            output_fifo.get(out_item);
            compare(in_item, out_item);
        end
    endtask

    // Element-by-element comparison
    function void compare(sa_seq_item expected, sa_result_txn actual);
        bit all_pass = 1;
        num_compared++;

        for (int r = 0; r < SA_N; r++) begin
            for (int c = 0; c < SA_N; c++) begin
                if (expected.mat_c[r][c] !== actual.result[r][c]) begin
                    string msg;
                    if (signed_mode)
                        msg = $sformatf(
                            "MISMATCH C[%0d][%0d]: got %0d (0x%08h), expected %0d (0x%08h)",
                            r, c,
                            $signed(actual.result[r][c]),  actual.result[r][c],
                            $signed(expected.mat_c[r][c]), expected.mat_c[r][c]);
                    else
                        msg = $sformatf(
                            "MISMATCH C[%0d][%0d]: got %0d (0x%08h), expected %0d (0x%08h)",
                            r, c,
                            actual.result[r][c],  actual.result[r][c],
                            expected.mat_c[r][c], expected.mat_c[r][c]);

                    `uvm_error("SCOREBOARD", msg)
                    all_pass = 0;
                    num_failed++;
                end else begin
                    num_passed++;
                end
            end
        end

        if (all_pass)
            `uvm_info("SCOREBOARD",
                $sformatf("Transaction %0d: all %0d elements PASSED",
                          num_compared, SA_N * SA_N), UVM_MEDIUM)
        else begin
            // Dump matrices for debugging
            `uvm_info("SCOREBOARD",
                $sformatf("Transaction %0d FAILED -- input:\n%s",
                          num_compared, expected.convert2string()), UVM_LOW)
            `uvm_info("SCOREBOARD",
                $sformatf("DUT output:\n%s", actual.convert2string()), UVM_LOW)
        end
    endfunction

    // Final summary
    function void report_phase(uvm_phase phase);
        `uvm_info("SCOREBOARD",
            $sformatf("  Transactions compared : %0d", num_compared), UVM_NONE)
        `uvm_info("SCOREBOARD",
            $sformatf("  Elements passed       : %0d", num_passed), UVM_NONE)
        `uvm_info("SCOREBOARD",
            $sformatf("  Elements failed       : %0d", num_failed), UVM_NONE)
        if (num_failed == 0)
            `uvm_info("SCOREBOARD", "  RESULT: ALL TESTS PASSED", UVM_NONE)
        else
            `uvm_error("SCOREBOARD", "  RESULT: SOME TESTS FAILED")
    endfunction

endclass
