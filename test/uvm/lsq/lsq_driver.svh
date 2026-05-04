    class lsq_driver extends uvm_driver #(lsq_seq_item);
        `uvm_component_utils(lsq_driver)
        virtual lsq_if vif;
        bit [1:0] issued_generation [`LQ_SZ];

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual lsq_if)::get(this, "", "lsq_vif", vif))
                `uvm_fatal("NOVIF", "lsq_vif not found")
        endfunction

        function logic [31:0] make_load_inst(bit [2:0] funct3);
            logic [31:0] inst;
            inst = 32'h0;
            inst[6:0] = 7'b0000011;
            inst[14:12] = funct3;
            inst[11:7] = 5'd1;
            inst[19:15] = 5'd2;
            return inst;
        endfunction

        function logic [31:0] make_store_inst(bit [2:0] funct3);
            logic [31:0] inst;
            inst = 32'h0;
            inst[6:0] = 7'b0100011;
            inst[14:12] = funct3;
            inst[19:15] = 5'd2;
            inst[24:20] = 5'd3;
            return inst;
        endfunction

        task drive_item(lsq_seq_item item);
            if (vif.drv_cb.load_packet.valid)
                issued_generation[vif.drv_cb.load_packet.lq_index] = vif.drv_cb.load_packet.generation;

            vif.clear_inputs();
            vif.drv_cb.dcache_can_accept_load  <= item.dcache_can_accept_load;
            vif.drv_cb.dcache_can_accept_store <= item.dcache_can_accept_store;

            case (item.op)
                LSQ_DISP_STORE: begin
                    vif.drv_cb.inst_in_bits[0] <= make_store_inst(item.store_funct3);
                    vif.drv_cb.is_store[0]    <= 1'b1;
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                end
                LSQ_DISP_LOAD: begin
                    vif.drv_cb.inst_in_bits[0] <= make_load_inst(item.load_funct3);
                    vif.drv_cb.is_load[0]     <= 1'b1;
                    vif.drv_cb.dest_tag_in_bits[0] <= PRF_IDX'(item.tag);
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                end
                LSQ_DISP_STORE_LOAD: begin
                    vif.drv_cb.inst_in_bits[0] <= make_store_inst(item.store_funct3);
                    vif.drv_cb.inst_in_bits[1] <= make_load_inst(item.load_funct3);
                    vif.drv_cb.is_store[0]    <= 1'b1;
                    vif.drv_cb.is_load[1]     <= 1'b1;
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                    vif.drv_cb.rob_index[1]   <= ROB_IDX'(item.rob + 1);
                    vif.drv_cb.dest_tag_in_bits[1] <= PRF_IDX'(item.tag + 1);
                end
                LSQ_DISP_LOAD_STORE: begin
                    vif.drv_cb.inst_in_bits[0] <= make_load_inst(item.load_funct3);
                    vif.drv_cb.inst_in_bits[1] <= make_store_inst(item.store_funct3);
                    vif.drv_cb.is_load[0]     <= 1'b1;
                    vif.drv_cb.is_store[1]    <= 1'b1;
                    vif.drv_cb.dest_tag_in_bits[0] <= PRF_IDX'(item.tag);
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                    vif.drv_cb.rob_index[1]   <= ROB_IDX'(item.rob + 1);
                end
                LSQ_DISP_LOAD_LOAD: begin
                    vif.drv_cb.inst_in_bits[0] <= make_load_inst(item.load_funct3);
                    vif.drv_cb.inst_in_bits[1] <= make_load_inst(item.load_funct3);
                    vif.drv_cb.is_load[0]     <= 1'b1;
                    vif.drv_cb.is_load[1]     <= 1'b1;
                    vif.drv_cb.dest_tag_in_bits[0] <= PRF_IDX'(item.tag);
                    vif.drv_cb.dest_tag_in_bits[1] <= PRF_IDX'(item.tag + 1);
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                    vif.drv_cb.rob_index[1]   <= ROB_IDX'(item.rob + 1);
                end
                LSQ_DISP_STORE_STORE: begin
                    vif.drv_cb.inst_in_bits[0] <= make_store_inst(item.store_funct3);
                    vif.drv_cb.inst_in_bits[1] <= make_store_inst(item.store_funct3);
                    vif.drv_cb.is_store[0]    <= 1'b1;
                    vif.drv_cb.is_store[1]    <= 1'b1;
                    vif.drv_cb.rob_index[0]   <= ROB_IDX'(item.rob);
                    vif.drv_cb.rob_index[1]   <= ROB_IDX'(item.rob + 1);
                end
                LSQ_EXEC_STORE: begin
                    vif.drv_cb.store_execute_pack.valid    <= 1'b1;
                    vif.drv_cb.store_execute_pack.sq_index <= SQ_IDX'(item.sq_idx);
                    vif.drv_cb.store_execute_pack.addr     <= ADDR'(item.addr);
                    vif.drv_cb.store_execute_pack.data     <= DATA'(item.data);
                    vif.drv_cb.store_execute_pack.funct3   <= item.funct3;
                    vif.drv_cb.store_execute_pack.rob_index <= ROB_IDX'(item.rob);
                end
                LSQ_EXEC_LOAD: begin
                    vif.drv_cb.load_execute_pack.valid     <= 1'b1;
                    vif.drv_cb.load_execute_pack.lq_index  <= LQ_IDX'(item.lq_idx);
                    vif.drv_cb.load_execute_pack.addr      <= ADDR'(item.addr);
                    vif.drv_cb.load_execute_pack.funct3    <= item.funct3;
                    vif.drv_cb.load_execute_pack.rob_index <= ROB_IDX'(item.rob);
                    vif.drv_cb.load_execute_pack.dest_tag  <= PRF_IDX'(item.tag);
                end
                LSQ_RETIRE_STORE: begin
                    vif.drv_cb.store_retire_pack[0].valid    <= 1'b1;
                    vif.drv_cb.store_retire_pack[0].sq_index <= SQ_IDX'(item.sq_idx);
                end
                LSQ_RETIRE_LOAD: begin
                    vif.drv_cb.load_retire_valid <= 1'b1;
                    vif.drv_cb.load_retire_num   <= (item.data == 2) ? 2'd2 : 2'd1;
                end
                LSQ_CACHE_RETURN: begin
                    vif.drv_cb.dcache_load_packet.valid      <= 1'b1;
                    vif.drv_cb.dcache_load_packet.lq_index   <= LQ_IDX'(item.lq_idx);
                    vif.drv_cb.dcache_load_packet.data       <= DATA'(item.data);
                    vif.drv_cb.dcache_load_packet.generation <= issued_generation[item.lq_idx];
                end
                LSQ_MISPREDICT: begin
                    vif.drv_cb.mispredicted  <= 1'b1;
                    vif.drv_cb.BS_lq_tail_in <= LQ_IDX'(item.lq_idx);
                    vif.drv_cb.BS_sq_tail_in <= SQ_IDX'(item.sq_idx);
                end
                default: begin
                end
            endcase
        endtask

        task run_phase(uvm_phase phase);
            forever begin
                lsq_seq_item item;
                seq_item_port.get_next_item(item);
                @(vif.drv_cb);
                drive_item(item);
                seq_item_port.item_done();
            end
        endtask
    endclass

