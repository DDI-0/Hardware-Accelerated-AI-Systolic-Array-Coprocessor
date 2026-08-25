// Sequence Item:  sa_seq_item
// Result Item:    sa_result_txn
//
// sa_seq_item holds two randomized NxN matrices (A, B) and a golden expected
// result (C = A*B).  Constraints bias toward corner-case values.
//
// sa_result_txn is a lightweight container carrying the actual DUT result
// matrix captured by the monitor.

// Result transaction -- created by the monitor
class sa_result_txn extends uvm_sequence_item;
    `uvm_object_utils(sa_result_txn)

    bit [SA_ACC_WIDTH-1:0] result [SA_N][SA_N];

    function new(string name = "sa_result_txn");
        super.new(name);
    endfunction

    function string convert2string();
        string s = "\n--- DUT Result Matrix ---\n";
        for (int r = 0; r < SA_N; r++) begin
            s = {s, "  ["};
            for (int c = 0; c < SA_N; c++) begin
                s = {s, $sformatf("%10d", result[r][c])};
                if (c < SA_N - 1) s = {s, ", "};
            end
            s = {s, " ]\n"};
        end
        return s;
    endfunction
endclass

// Sequence item -- randomized input matrices + golden model
class sa_seq_item extends uvm_sequence_item;
    `uvm_object_utils(sa_seq_item)

    // Randomized inputs
    rand bit [SA_DATA_WIDTH-1:0] mat_a [SA_N][SA_N];
    rand bit [SA_DATA_WIDTH-1:0] mat_b [SA_N][SA_N];

    // Configuration (set by sequence before randomize)
    bit signed_mode;

    // Golden expected result (computed in post_randomize)
    bit [SA_ACC_WIDTH-1:0] mat_c [SA_N][SA_N];

    // Constraints -- bias toward corner-case values
    constraint c_a_dist {
        foreach (mat_a[i,j])
            mat_a[i][j] dist {
                8'h00        := 10,   // zero
                8'hFF        := 10,   // max unsigned / -1 signed
                8'h80        := 5,    // 128 unsigned / -128 signed
                8'h7F        := 5,    // 127 (max positive signed)
                8'h01        := 5,    // smallest nonzero
                [8'h02:8'hFE] := 65   // everything else
            };
    }

    constraint c_b_dist {
        foreach (mat_b[i,j])
            mat_b[i][j] dist {
                8'h00        := 10,
                8'hFF        := 10,
                8'h80        := 5,
                8'h7F        := 5,
                8'h01        := 5,
                [8'h02:8'hFE] := 65
            };
    }

    function new(string name = "sa_seq_item");
        super.new(name);
    endfunction

    // Golden model -- matches VHDL PE behavior exactly
    function void post_randomize();
        compute_golden();
    endfunction

    function void compute_golden();
        for (int r = 0; r < SA_N; r++) begin
            for (int c = 0; c < SA_N; c++) begin
                if (signed_mode) begin
                    // Signed: sign-extend 8-bit to 32-bit, signed MAC
                    int acc_s = 0;
                    for (int k = 0; k < SA_N; k++) begin
                        int a_s = int'($signed(mat_a[r][k]));
                        int b_s = int'($signed(mat_b[k][c]));
                        acc_s = acc_s + a_s * b_s;
                    end
                    mat_c[r][c] = acc_s;
                end else begin
                    // Unsigned: zero-extend 8-bit to 32-bit, unsigned MAC
                    int unsigned acc_u = 0;
                    for (int k = 0; k < SA_N; k++) begin
                        int unsigned a_u = mat_a[r][k];
                        int unsigned b_u = mat_b[k][c];
                        acc_u = acc_u + a_u * b_u;
                    end
                    mat_c[r][c] = acc_u;
                end
            end
        end
    endfunction

    // Debug printing
    function string convert2string();
        string s;
        s = $sformatf("\n--- sa_seq_item (signed_mode=%0d) ---\n", signed_mode);

        s = {s, "Matrix A:\n"};
        for (int r = 0; r < SA_N; r++) begin
            s = {s, "  ["};
            for (int c = 0; c < SA_N; c++) begin
                if (signed_mode)
                    s = {s, $sformatf("%5d", int'($signed(mat_a[r][c])))};
                else
                    s = {s, $sformatf("%4d", mat_a[r][c])};
                if (c < SA_N - 1) s = {s, ", "};
            end
            s = {s, " ]\n"};
        end

        s = {s, "Matrix B:\n"};
        for (int r = 0; r < SA_N; r++) begin
            s = {s, "  ["};
            for (int c = 0; c < SA_N; c++) begin
                if (signed_mode)
                    s = {s, $sformatf("%5d", int'($signed(mat_b[r][c])))};
                else
                    s = {s, $sformatf("%4d", mat_b[r][c])};
                if (c < SA_N - 1) s = {s, ", "};
            end
            s = {s, " ]\n"};
        end

        s = {s, "Expected C:\n"};
        for (int r = 0; r < SA_N; r++) begin
            s = {s, "  ["};
            for (int c = 0; c < SA_N; c++) begin
                if (signed_mode)
                    s = {s, $sformatf("%10d", $signed(mat_c[r][c]))};
                else
                    s = {s, $sformatf("%10d", mat_c[r][c])};
                if (c < SA_N - 1) s = {s, ", "};
            end
            s = {s, " ]\n"};
        end

        return s;
    endfunction

endclass
