    typedef enum logic [3:0] {
        LSQ_IDLE,
        LSQ_DISP_STORE,
        LSQ_DISP_LOAD,
        LSQ_DISP_STORE_LOAD,
        LSQ_DISP_LOAD_STORE,
        LSQ_DISP_LOAD_LOAD,
        LSQ_DISP_STORE_STORE,
        LSQ_EXEC_STORE,
        LSQ_EXEC_LOAD,
        LSQ_RETIRE_STORE,
        LSQ_RETIRE_LOAD,
        LSQ_CACHE_RETURN,
        LSQ_MISPREDICT
    } lsq_op_e;

    class lsq_agent_cfg extends uvm_object;
        `uvm_object_utils(lsq_agent_cfg)
        uvm_active_passive_enum active = UVM_ACTIVE;
        int unsigned num_rand_trans = 200;
        function new(string name = "lsq_agent_cfg");
            super.new(name);
        endfunction
    endclass

    class lsq_seq_item extends uvm_sequence_item;
        `uvm_object_utils(lsq_seq_item)

        rand lsq_op_e op;
        rand int unsigned slot;
        rand int unsigned addr;
        rand int unsigned data;
        rand int unsigned rob;
        rand int unsigned tag;
        rand int unsigned lq_idx;
        rand int unsigned sq_idx;
        rand bit [2:0] funct3;
        rand bit [2:0] load_funct3;
        rand bit [2:0] store_funct3;
        rand bit dcache_can_accept_load;
        rand bit dcache_can_accept_store;

        constraint c_ranges {
            slot inside {[0:`N-1]};
            lq_idx inside {[0:`LQ_SZ-1]};
            sq_idx inside {[0:`SQ_SZ-1]};
            rob inside {[0:`ROB_SZ-1]};
            tag inside {[`ARCH_REG_SZ:`PHYS_REG_SZ_R10K-1]};
            addr[1:0] == 2'b00;
            funct3 inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            load_funct3 inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            store_funct3 inside {3'b000, 3'b001, 3'b010};
            (op inside {LSQ_EXEC_STORE, LSQ_RETIRE_STORE}) -> funct3 inside {3'b000, 3'b001, 3'b010};
        }

        function new(string name = "lsq_seq_item");
            super.new(name);
            slot = 0;
            addr = 32'h100;
            data = 32'h0;
            rob = 0;
            tag = `ARCH_REG_SZ;
            lq_idx = 0;
            sq_idx = 0;
            funct3 = 3'b010;
            load_funct3 = 3'b010;
            store_funct3 = 3'b010;
            dcache_can_accept_load = 1'b1;
            dcache_can_accept_store = 1'b1;
        endfunction

        function string convert2string();
            return $sformatf("%s slot=%0d lq=%0d sq=%0d rob=%0d tag=%0d addr=%08x data=%08x f3=%03b lf3=%03b sf3=%03b",
                op.name(), slot, lq_idx, sq_idx, rob, tag, addr, data, funct3, load_funct3, store_funct3);
        endfunction
    endclass

    class lsq_obs extends uvm_object;
        `uvm_object_utils(lsq_obs)

        bit reset;
        bit [2:0] load_funct3 [`N-1:0];
        bit [2:0] store_funct3 [`N-1:0];
        logic [`N-1:0] is_load;
        logic [`N-1:0] is_store;
        logic [`N-1:0] is_branch;
        PRF_IDX dest_tag_in [`N-1:0];
        ROB_IDX rob_index [`N-1:0];
        LQ_PACKET load_execute_pack;
        SQ_PACKET store_execute_pack;
        SQ_PACKET store_retire_pack [`N-1:0];
        bit load_retire_valid;
        bit [1:0] load_retire_num;
        bit mispredicted;
        LQ_IDX BS_lq_tail_in;
        SQ_IDX BS_sq_tail_in;
        bit dcache_can_accept_load;
        bit dcache_can_accept_store;
        bit dcache_load_valid;
        LQ_IDX dcache_load_lq_index;
        DATA dcache_load_data;
        bit [1:0] dcache_load_generation;
        SQ_IDX sq_index [`N-1:0];
        LQ_IDX lq_index [`N-1:0];
        SQ_IDX sq_tail_out [`N-1:0];
        logic [`SQ_SZ-1:0] sq_valid_out_mask [`N-1:0];
        SQ_IDX sq_head_out;
        logic [`SQ_SZ-1:0] sq_valid_out;
        logic sq_addr_ready_out [`SQ_SZ-1:0];
        logic sq_data_ready_out [`SQ_SZ-1:0];
        ADDR sq_addr_out [`SQ_SZ-1:0];
        DATA sq_data_out [`SQ_SZ-1:0];
        logic [2:0] sq_funct3_out [`SQ_SZ-1:0];
        SQ_PACKET sq_out;
        LQ_PACKET load_packet;
        bit cdb_req_load;
        LQ_PACKET lq_out;

        function new(string name = "lsq_obs");
            super.new(name);
        endfunction
    endclass
