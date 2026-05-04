    class lsq_monitor extends uvm_component;
        `uvm_component_utils(lsq_monitor)
        virtual lsq_if vif;
        uvm_analysis_port #(lsq_obs) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual lsq_if)::get(this, "", "lsq_vif", vif))
                `uvm_fatal("NOVIF", "lsq_vif not found")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                lsq_obs obs;
                @(vif.mon_cb);
                obs = lsq_obs::type_id::create("obs");
                obs.reset = vif.mon_cb.reset;
                foreach (obs.load_funct3[i]) begin
                    obs.load_funct3[i] = vif.mon_cb.inst_in_bits[i][14:12];
                    obs.store_funct3[i] = vif.mon_cb.inst_in_bits[i][14:12];
                end
                obs.is_load = vif.mon_cb.is_load;
                obs.is_store = vif.mon_cb.is_store;
                obs.is_branch = vif.mon_cb.is_branch;
                foreach (obs.dest_tag_in[i]) obs.dest_tag_in[i] = PRF_IDX'(vif.mon_cb.dest_tag_in_bits[i]);
                obs.rob_index = vif.mon_cb.rob_index;
                obs.load_execute_pack = vif.mon_cb.load_execute_pack;
                obs.store_execute_pack = vif.mon_cb.store_execute_pack;
                obs.store_retire_pack = vif.mon_cb.store_retire_pack;
                obs.load_retire_valid = vif.mon_cb.load_retire_valid;
                obs.load_retire_num = vif.mon_cb.load_retire_num;
                obs.mispredicted = vif.mon_cb.mispredicted;
                obs.BS_lq_tail_in = vif.mon_cb.BS_lq_tail_in;
                obs.BS_sq_tail_in = vif.mon_cb.BS_sq_tail_in;
                obs.dcache_can_accept_load = vif.mon_cb.dcache_can_accept_load;
                obs.dcache_can_accept_store = vif.mon_cb.dcache_can_accept_store;
                obs.dcache_load_valid = vif.mon_cb.dcache_load_packet.valid;
                obs.dcache_load_lq_index = vif.mon_cb.dcache_load_packet.lq_index;
                obs.dcache_load_data = vif.mon_cb.dcache_load_packet.data;
                obs.dcache_load_generation = vif.mon_cb.dcache_load_packet.generation;
                obs.sq_index = vif.mon_cb.sq_index;
                obs.lq_index = vif.mon_cb.lq_index;
                obs.sq_tail_out = vif.mon_cb.sq_tail_out;
                obs.sq_valid_out_mask = vif.mon_cb.sq_valid_out_mask;
                obs.sq_head_out = vif.mon_cb.sq_head_out;
                obs.sq_valid_out = vif.mon_cb.sq_valid_out;
                obs.sq_addr_ready_out = vif.mon_cb.sq_addr_ready_out;
                obs.sq_data_ready_out = vif.mon_cb.sq_data_ready_out;
                obs.sq_addr_out = vif.mon_cb.sq_addr_out;
                obs.sq_data_out = vif.mon_cb.sq_data_out;
                obs.sq_funct3_out = vif.mon_cb.sq_funct3_out;
                obs.sq_out = vif.mon_cb.sq_out;
                obs.load_packet = vif.mon_cb.load_packet;
                obs.cdb_req_load = vif.mon_cb.cdb_req_load;
                obs.lq_out = vif.mon_cb.lq_out;
                ap.write(obs);
            end
        endtask
    endclass

