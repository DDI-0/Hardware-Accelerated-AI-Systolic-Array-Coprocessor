// Functional Coverage: sa_coverage
//
// Subscribes to the driver's analysis port and samples every driven
// transaction.  Covergroups track:
//
//   cg_element_values  -- Per-element value distribution for A and B
//                         (unsigned bins + signed bins when in signed mode)
//   cg_matrix_patterns -- Special matrix shapes (all-zero, all-max, identity)
//   cg_cross_ab        -- Cross of A-value x B-value ranges

class sa_coverage extends uvm_subscriber #(sa_seq_item);
    `uvm_component_utils(sa_coverage)

    // Variables sampled by covergroups
    bit [SA_DATA_WIDTH-1:0]        cov_a;
    bit [SA_DATA_WIDTH-1:0]        cov_b;
    bit                            cov_signed_mode;
    bit                            cov_a_all_zero;
    bit                            cov_a_all_max;
    bit                            cov_a_identity;
    bit                            cov_b_all_zero;
    bit                            cov_b_all_max;
    bit                            cov_b_identity;

    // Per-element value coverage
    covergroup cg_element_values;
        option.per_instance = 1;
        option.name         = "cg_element_values";

        // Unsigned interpretation
        a_unsigned: coverpoint cov_a {
            bins zero    = {0};
            bins one     = {1};
            bins small   = {[2:10]};
            bins mid     = {[11:127]};
            bins large   = {[128:254]};
            bins max_val = {8'hFF};
        }

        b_unsigned: coverpoint cov_b {
            bins zero    = {0};
            bins one     = {1};
            bins small   = {[2:10]};
            bins mid     = {[11:127]};
            bins large   = {[128:254]};
            bins max_val = {8'hFF};
        }

        // Signed interpretation (sampled only when signed_mode == 1)
        a_signed: coverpoint $signed(cov_a) iff (cov_signed_mode) {
            bins neg_max  = {-128};
            bins negative = {[-127:-1]};
            bins zero     = {0};
            bins positive = {[1:126]};
            bins pos_max  = {127};
        }

        b_signed: coverpoint $signed(cov_b) iff (cov_signed_mode) {
            bins neg_max  = {-128};
            bins negative = {[-127:-1]};
            bins zero     = {0};
            bins positive = {[1:126]};
            bins pos_max  = {127};
        }

        // Arithmetic mode
        arith_mode: coverpoint cov_signed_mode {
            bins unsigned_mode = {0};
            bins signed_mode   = {1};
        }

        // Cross: value range of A x B
        cross_ab_unsigned: cross a_unsigned, b_unsigned;

        // Cross: arithmetic mode x A-value range
        cross_mode_a: cross arith_mode, a_unsigned;
    endgroup

    // Matrix-level pattern coverage
    covergroup cg_matrix_patterns;
        option.per_instance = 1;
        option.name         = "cg_matrix_patterns";

        a_all_zero: coverpoint cov_a_all_zero {
            bins is_all_zero = {1};
            bins not_all_zero = {0};
        }

        a_all_max: coverpoint cov_a_all_max {
            bins is_all_max = {1};
            bins not_all_max = {0};
        }

        a_identity_like: coverpoint cov_a_identity {
            bins is_identity = {1};
            bins not_identity = {0};
        }

        b_all_zero: coverpoint cov_b_all_zero {
            bins is_all_zero = {1};
            bins not_all_zero = {0};
        }

        b_all_max: coverpoint cov_b_all_max {
            bins is_all_max = {1};
            bins not_all_max = {0};
        }

        b_identity_like: coverpoint cov_b_identity {
            bins is_identity = {1};
            bins not_identity = {0};
        }

        mode: coverpoint cov_signed_mode {
            bins unsigned_mode = {0};
            bins signed_mode   = {1};
        }
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_element_values  = new();
        cg_matrix_patterns = new();
    endfunction

    // write() -- called for every sa_seq_item driven
    function void write(sa_seq_item t);
        cov_signed_mode = t.signed_mode;

        // Sample per-element coverage
        for (int r = 0; r < SA_N; r++) begin
            for (int c = 0; c < SA_N; c++) begin
                cov_a = t.mat_a[r][c];
                cov_b = t.mat_b[r][c];
                cg_element_values.sample();
            end
        end

        // Compute matrix-level pattern flags
        classify_matrix(t);
        cg_matrix_patterns.sample();
    endfunction

    // Detect special matrix patterns
    function void classify_matrix(sa_seq_item t);
        cov_a_all_zero = 1;
        cov_a_all_max  = 1;
        cov_a_identity = 1;
        cov_b_all_zero = 1;
        cov_b_all_max  = 1;
        cov_b_identity = 1;

        for (int r = 0; r < SA_N; r++) begin
            for (int c = 0; c < SA_N; c++) begin
                // Matrix A patterns
                if (t.mat_a[r][c] != 0)       cov_a_all_zero = 0;
                if (t.mat_a[r][c] != 8'hFF)   cov_a_all_max  = 0;
                if (r == c && t.mat_a[r][c] != 1)   cov_a_identity = 0;
                if (r != c && t.mat_a[r][c] != 0)   cov_a_identity = 0;

                // Matrix B patterns
                if (t.mat_b[r][c] != 0)       cov_b_all_zero = 0;
                if (t.mat_b[r][c] != 8'hFF)   cov_b_all_max  = 0;
                if (r == c && t.mat_b[r][c] != 1)   cov_b_identity = 0;
                if (r != c && t.mat_b[r][c] != 0)   cov_b_identity = 0;
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("COVERAGE",
            $sformatf("  Element values  : %.1f%%",
                      cg_element_values.get_inst_coverage()), UVM_NONE)
        `uvm_info("COVERAGE",
            $sformatf("  Matrix patterns : %.1f%%",
                      cg_matrix_patterns.get_inst_coverage()), UVM_NONE)
    endfunction

endclass
