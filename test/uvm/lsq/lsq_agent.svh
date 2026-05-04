    class lsq_agent extends uvm_agent;
        `uvm_component_utils(lsq_agent)
        uvm_sequencer #(lsq_seq_item) sequencer;
        lsq_driver driver;
        lsq_monitor monitor;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sequencer = uvm_sequencer #(lsq_seq_item)::type_id::create("sequencer", this);
            driver = lsq_driver::type_id::create("driver", this);
            monitor = lsq_monitor::type_id::create("monitor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass
