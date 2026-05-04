    class lsq_env extends uvm_env;
        `uvm_component_utils(lsq_env)
        lsq_agent agent;
        lsq_scoreboard scoreboard;
        lsq_coverage coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = lsq_agent::type_id::create("agent", this);
            scoreboard = lsq_scoreboard::type_id::create("scoreboard", this);
            coverage = lsq_coverage::type_id::create("coverage", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.monitor.ap.connect(scoreboard.obs_imp);
            agent.monitor.ap.connect(coverage.analysis_export);
        endfunction
    endclass
