// Sequences for systolic array verification
//
// sa_random_seq  -- Fully random matrices (with corner-case bias from item)
// sa_corner_seq  -- Targets specific corner cases: zeros, max, identity

// Random sequence -- runs num_txns random matrix multiplications
class sa_random_seq extends uvm_sequence #(sa_seq_item);
    `uvm_object_utils(sa_random_seq)

    int unsigned num_txns = 100;
    bit          signed_mode = 0;

    function new(string name = "sa_random_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info(get_type_name(),
            $sformatf("Starting %0d random transactions (signed_mode=%0d)",
                      num_txns, signed_mode), UVM_MEDIUM)

        for (int i = 0; i < num_txns; i++) begin
            sa_seq_item item = sa_seq_item::type_id::create($sformatf("item_%0d", i));
            item.signed_mode = signed_mode;
            start_item(item);
            if (!item.randomize())
                `uvm_fatal("RAND_FAIL", "Randomization of sa_seq_item failed")
            `uvm_info(get_type_name(),
                $sformatf("Transaction %0d/%0d\n%s", i+1, num_txns, item.convert2string()),
                UVM_HIGH)
            finish_item(item);
        end

        `uvm_info(get_type_name(),
            $sformatf("Completed %0d random transactions", num_txns), UVM_MEDIUM)
    endtask
endclass

// Corner-case sequence -- exercises specific matrix patterns
class sa_corner_seq extends uvm_sequence #(sa_seq_item);
    `uvm_object_utils(sa_corner_seq)

    bit signed_mode = 0;

    function new(string name = "sa_corner_seq");
        super.new(name);
    endfunction

    task body();
        sa_seq_item item;

        `uvm_info(get_type_name(), "Running corner-case patterns", UVM_MEDIUM)

        // ---- Pattern 1: All-zero A * random B = zero result ----
        item = sa_seq_item::type_id::create("zero_a");
        item.signed_mode = signed_mode;
        start_item(item);
        if (!item.randomize() with {
            foreach (mat_a[i,j]) mat_a[i][j] == 0;
        }) `uvm_fatal("RAND", "zero_a randomization failed")
        finish_item(item);

        // ---- Pattern 2: Random A * all-zero B = zero result ----
        item = sa_seq_item::type_id::create("zero_b");
        item.signed_mode = signed_mode;
        start_item(item);
        if (!item.randomize() with {
            foreach (mat_b[i,j]) mat_b[i][j] == 0;
        }) `uvm_fatal("RAND", "zero_b randomization failed")
        finish_item(item);

        // ---- Pattern 3: Identity-like A * B = B ----
        item = sa_seq_item::type_id::create("identity_a");
        item.signed_mode = signed_mode;
        start_item(item);
        if (!item.randomize() with {
            foreach (mat_a[i,j]) {
                if (i == j) mat_a[i][j] == 1;
                else        mat_a[i][j] == 0;
            }
        }) `uvm_fatal("RAND", "identity_a randomization failed")
        finish_item(item);

        // ---- Pattern 4: A * Identity-like B = A ----
        item = sa_seq_item::type_id::create("identity_b");
        item.signed_mode = signed_mode;
        start_item(item);
        if (!item.randomize() with {
            foreach (mat_b[i,j]) {
                if (i == j) mat_b[i][j] == 1;
                else        mat_b[i][j] == 0;
            }
        }) `uvm_fatal("RAND", "identity_b randomization failed")
        finish_item(item);

        // ---- Pattern 5: All-max A * all-max B (stress accumulator) ----
        item = sa_seq_item::type_id::create("max_max");
        item.signed_mode = signed_mode;
        start_item(item);
        if (!item.randomize() with {
            foreach (mat_a[i,j]) mat_a[i][j] == 8'hFF;
            foreach (mat_b[i,j]) mat_b[i][j] == 8'hFF;
        }) `uvm_fatal("RAND", "max_max randomization failed")
        finish_item(item);

        // ---- Pattern 6 (signed only): Negative * Negative ----
        if (signed_mode) begin
            item = sa_seq_item::type_id::create("neg_neg");
            item.signed_mode = 1;
            start_item(item);
            if (!item.randomize() with {
                foreach (mat_a[i,j]) mat_a[i][j] inside {[8'h80:8'hFF]};
                foreach (mat_b[i,j]) mat_b[i][j] inside {[8'h80:8'hFF]};
            }) `uvm_fatal("RAND", "neg_neg randomization failed")
            finish_item(item);

            // ---- Pattern 7: Positive * Negative ----
            item = sa_seq_item::type_id::create("pos_neg");
            item.signed_mode = 1;
            start_item(item);
            if (!item.randomize() with {
                foreach (mat_a[i,j]) mat_a[i][j] inside {[8'h00:8'h7F]};
                foreach (mat_b[i,j]) mat_b[i][j] inside {[8'h80:8'hFF]};
            }) `uvm_fatal("RAND", "pos_neg randomization failed")
            finish_item(item);
        end

        `uvm_info(get_type_name(), "Corner-case patterns complete", UVM_MEDIUM)
    endtask
endclass
