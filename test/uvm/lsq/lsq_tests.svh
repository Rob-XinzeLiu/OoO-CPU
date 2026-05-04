    class lsq_base_test extends uvm_test;
        `uvm_component_utils(lsq_base_test)
        lsq_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = lsq_env::type_id::create("env", this);
        endfunction
    endclass

    class lsq_directed_test extends lsq_base_test;
        `uvm_component_utils(lsq_directed_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            lsq_directed_seq seq = lsq_directed_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.agent.driver.vif.apply_reset();
            seq.start(env.agent.sequencer);
            repeat (10) @(env.agent.driver.vif.drv_cb);
            phase.drop_objection(this);
        endtask
    endclass

    class lsq_smoke_test extends lsq_base_test;
        `uvm_component_utils(lsq_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            lsq_smoke_seq seq = lsq_smoke_seq::type_id::create("seq");
            phase.raise_objection(this);
            env.agent.driver.vif.apply_reset();
            seq.start(env.agent.sequencer);
            repeat (10) @(env.agent.driver.vif.drv_cb);
            phase.drop_objection(this);
        endtask
    endclass
