// Tests for systolic array UVM verification
//
// sa_base_test     -- Common setup: build env, configure signed_mode from
//                     +SIGNED_MODE plusarg
// sa_unsigned_test -- 50 random + corner-case tests in unsigned mode
// sa_signed_test   -- 50 random + corner-case tests in signed mode
// sa_random_test   -- 100 random tests using plusarg-configured mode

// Base test -- common infrastructure
class sa_base_test extends uvm_test;
    `uvm_component_utils(sa_base_test)

    sa_env env;
    bit    signed_mode;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        int val;
        super.build_phase(phase);

        // Read arithmetic mode from plusarg (+SIGNED_MODE=0 or +SIGNED_MODE=1)
        if ($value$plusargs("SIGNED_MODE=%d", val))
            signed_mode = val[0];
        else
            signed_mode = 0;

        `uvm_info(get_type_name(),
            $sformatf("Arithmetic mode: %s",
                      signed_mode ? "SIGNED" : "UNSIGNED"), UVM_LOW)

        // Propagate to all components via config_db
        uvm_config_db#(bit)::set(this, "*", "signed_mode", signed_mode);

        env = sa_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_top.print_topology();
    endfunction
endclass

// Unsigned test -- forces unsigned mode, runs random + corners
class sa_unsigned_test extends sa_base_test;
    `uvm_component_utils(sa_unsigned_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        // Override plusarg: force unsigned
        signed_mode = 0;
        uvm_config_db#(bit)::set(this, "*", "signed_mode", 0);
        super.build_phase(phase);
    endfunction

    task run_phase(uvm_phase phase);
        sa_random_seq random_seq;
        sa_corner_seq corner_seq;

        phase.raise_objection(this, "sa_unsigned_test");

        // Corner cases first
        corner_seq = sa_corner_seq::type_id::create("corner_seq");
        corner_seq.signed_mode = 0;
        corner_seq.start(env.agent.sqr);

        // Then random
        random_seq = sa_random_seq::type_id::create("random_seq");
        random_seq.signed_mode = 0;
        random_seq.num_txns    = 50;
        random_seq.start(env.agent.sqr);

        phase.drop_objection(this, "sa_unsigned_test");
    endtask
endclass

// Signed test -- forces signed mode, runs random + corners
class sa_signed_test extends sa_base_test;
    `uvm_component_utils(sa_signed_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        // Override plusarg: force signed
        signed_mode = 1;
        uvm_config_db#(bit)::set(this, "*", "signed_mode", 1);
        super.build_phase(phase);
    endfunction

    task run_phase(uvm_phase phase);
        sa_random_seq random_seq;
        sa_corner_seq corner_seq;

        phase.raise_objection(this, "sa_signed_test");

        corner_seq = sa_corner_seq::type_id::create("corner_seq");
        corner_seq.signed_mode = 1;
        corner_seq.start(env.agent.sqr);

        random_seq = sa_random_seq::type_id::create("random_seq");
        random_seq.signed_mode = 1;
        random_seq.num_txns    = 50;
        random_seq.start(env.agent.sqr);

        phase.drop_objection(this, "sa_signed_test");
    endtask
endclass

// Random test -- uses plusarg-configured mode, 100 random transactions
class sa_random_test extends sa_base_test;
    `uvm_component_utils(sa_random_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        sa_random_seq seq;

        phase.raise_objection(this, "sa_random_test");

        seq = sa_random_seq::type_id::create("random_seq");
        seq.signed_mode = signed_mode;
        seq.num_txns    = 100;
        seq.start(env.agent.sqr);

        phase.drop_objection(this, "sa_random_test");
    endtask
endclass
