    class lsq_coverage extends uvm_subscriber #(lsq_obs);
        `uvm_component_utils(lsq_coverage)

        bit dispatch_load;
        bit dispatch_store;
        int unsigned dispatch_load_count;
        int unsigned dispatch_store_count;
        int unsigned dispatch_pattern;
        bit load_execute;
        bit store_execute;
        bit load_to_dcache;
        bit dcache_return;
        bit load_broadcast;
        bit store_retire;
        bit store_commit;
        bit mispredict_seen;
        bit dcache_load_backpressure;
        bit dcache_store_backpressure;
        bit lq_wrap_dispatch;
        bit sq_wrap_dispatch;
        bit saw_lq_nonzero;
        bit saw_sq_nonzero;
        bit older_store_visible;
        bit same_word_sq_match;
        bit sq_forward_data_ready;
        bit partial_overlap_seen;
        int unsigned lq_occupancy;
        int unsigned sq_occupancy;
        int unsigned dependency_distance;
        bit cov_lq_valid [`LQ_SZ];
        logic [`SQ_SZ-1:0] cov_lq_old_mask [`LQ_SZ];
        SQ_IDX cov_lq_sq_tail [`LQ_SZ];
        LQ_IDX cov_lq_head;
        int unsigned load_funct3;
        int unsigned store_funct3;
        int unsigned load_issue_slot;

        covergroup cg;
            option.per_instance = 1;

            cp_dispatch_load: coverpoint dispatch_load {
                bins seen = {1};
            }

            cp_dispatch_store: coverpoint dispatch_store {
                bins seen = {1};
            }

            cp_dispatch_load_count: coverpoint dispatch_load_count {
                bins zero = {0};
                bins one  = {1};
                bins two  = {2};
            }

            cp_dispatch_store_count: coverpoint dispatch_store_count {
                bins zero = {0};
                bins one  = {1};
                bins two  = {2};
            }

            cp_dispatch_pattern: coverpoint dispatch_pattern {
                bins none        = {0};
                bins load_only   = {1};
                bins store_only  = {2};
                bins load_load   = {3};
                bins store_store = {4};
                bins store_load  = {5};
                bins load_store  = {6};
            }

            cp_load_execute: coverpoint load_execute {
                bins seen = {1};
            }

            cp_store_execute: coverpoint store_execute {
                bins seen = {1};
            }

            cp_load_to_dcache: coverpoint load_to_dcache {
                bins seen = {1};
            }

            cp_dcache_return: coverpoint dcache_return {
                bins seen = {1};
            }

            cp_load_broadcast: coverpoint load_broadcast {
                bins seen = {1};
            }

            cp_store_retire: coverpoint store_retire {
                bins seen = {1};
            }

            cp_store_commit: coverpoint store_commit {
                bins seen = {1};
            }

            cp_mispredict_seen: coverpoint mispredict_seen {
                bins seen = {1};
            }

            cp_dcache_load_backpressure: coverpoint dcache_load_backpressure {
                bins seen = {1};
            }

            cp_dcache_store_backpressure: coverpoint dcache_store_backpressure {
                bins seen = {1};
            }

            cp_lq_wrap_dispatch: coverpoint lq_wrap_dispatch {
                bins seen = {1};
            }

            cp_sq_wrap_dispatch: coverpoint sq_wrap_dispatch {
                bins seen = {1};
            }

            cp_older_store_visible: coverpoint older_store_visible {
                bins none = {0};
                bins some = {1};
            }

            cp_same_word_sq_match: coverpoint same_word_sq_match {
                bins match = {1};
            }

            cp_sq_forward_ready: coverpoint sq_forward_data_ready {
                bins ready = {1};
            }

            cp_partial_overlap_seen: coverpoint partial_overlap_seen {
                bins seen = {1};
            }

            cp_lq_occupancy: coverpoint lq_occupancy {
                bins empty     = {0};
                bins low       = {[1:2]};
                bins half      = {[3:4]};
                bins near_full = {[5:`LQ_SZ-1]};
                bins full      = {`LQ_SZ};
            }

            cp_sq_occupancy: coverpoint sq_occupancy {
                bins empty     = {0};
                bins low       = {[1:2]};
                bins half      = {[3:4]};
                bins near_full = {[5:`SQ_SZ-1]};
                bins full      = {`SQ_SZ};
            }

            cp_dependency_distance: coverpoint dependency_distance iff (load_execute) {
                bins none = {0};
                bins one  = {1};
                bins two  = {2};
                bins mid  = {[3:5]};
                bins far  = {[6:`SQ_SZ]};
            }

            cp_load_funct3: coverpoint load_funct3 {
                bins lb  = {3'b000};
                bins lh  = {3'b001};
                bins lw  = {3'b010};
                bins lbu = {3'b100};
                bins lhu = {3'b101};
            }

            cp_store_funct3: coverpoint store_funct3 {
                bins sb = {3'b000};
                bins sh = {3'b001};
                bins sw = {3'b010};
            }

            cp_load_issue_slot: coverpoint load_issue_slot {
                bins lq_slots[] = {[0:`LQ_SZ-1]};
            }

            cross cp_load_to_dcache, cp_older_store_visible;
            cross cp_load_broadcast, cp_same_word_sq_match, cp_sq_forward_ready;
            cross cp_dispatch_pattern, cp_load_broadcast;
            cross cp_store_funct3, cp_load_funct3 iff (load_execute && same_word_sq_match && sq_forward_data_ready);
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        function void write(lsq_obs t);
            if (t.reset) begin
                saw_lq_nonzero = 1'b0;
                saw_sq_nonzero = 1'b0;
                lq_occupancy = 0;
                sq_occupancy = 0;
                cov_lq_head = '0;
                foreach (cov_lq_valid[i]) begin
                    cov_lq_valid[i] = 1'b0;
                    cov_lq_old_mask[i] = '0;
                    cov_lq_sq_tail[i] = '0;
                end
            end

            dispatch_load = |t.is_load;
            dispatch_store = |t.is_store;
            dispatch_load_count = int'(t.is_load[0]) + int'(t.is_load[1]);
            dispatch_store_count = int'(t.is_store[0]) + int'(t.is_store[1]);
            if (t.is_load[0] && t.is_load[1])
                dispatch_pattern = 3;
            else if (t.is_store[0] && t.is_store[1])
                dispatch_pattern = 4;
            else if (t.is_store[0] && t.is_load[1])
                dispatch_pattern = 5;
            else if (t.is_load[0] && t.is_store[1])
                dispatch_pattern = 6;
            else if (dispatch_load)
                dispatch_pattern = 1;
            else if (dispatch_store)
                dispatch_pattern = 2;
            else
                dispatch_pattern = 0;
            load_execute = t.load_execute_pack.valid;
            store_execute = t.store_execute_pack.valid;
            load_to_dcache = t.load_packet.valid;
            dcache_return = t.dcache_load_valid;
            load_broadcast = t.lq_out.valid;
            store_retire = t.store_retire_pack[0].valid || t.store_retire_pack[1].valid;
            store_commit = t.sq_out.valid;
            mispredict_seen = t.mispredicted;
            dcache_load_backpressure = !t.dcache_can_accept_load;
            dcache_store_backpressure = !t.dcache_can_accept_store;
            lq_wrap_dispatch = 1'b0;
            sq_wrap_dispatch = 1'b0;
            older_store_visible = t.load_execute_pack.valid && (t.sq_valid_out != '0);
            same_word_sq_match = 1'b0;
            sq_forward_data_ready = 1'b0;
            partial_overlap_seen = 1'b0;
            dependency_distance = 0;
            load_funct3 = t.load_packet.valid ? t.load_packet.funct3 :
                          t.load_execute_pack.valid ? t.load_execute_pack.funct3 :
                          t.lq_out.valid ? 3'b010 : 3'b010;
            store_funct3 = t.store_execute_pack.valid ? t.store_execute_pack.funct3 :
                           t.sq_out.valid ? t.sq_out.funct3 : 3'b010;
            load_issue_slot = t.load_packet.valid ? int'(t.load_packet.lq_index) :
                              t.load_execute_pack.valid ? int'(t.load_execute_pack.lq_index) : 0;

            if (t.load_execute_pack.valid) begin
                int unsigned best_distance = `SQ_SZ + 1;
                int li = int'(t.load_execute_pack.lq_index);
                load_funct3 = t.load_execute_pack.funct3;
                for (int i = 0; i < `SQ_SZ; i++) begin
                    if (t.sq_valid_out[i]
                     && t.sq_addr_ready_out[i]
                     && (t.sq_addr_out[i][31:2] == t.load_execute_pack.addr[31:2])) begin
                        logic [3:0] store_mask;
                        logic [3:0] load_mask;
                        int unsigned distance;
                        same_word_sq_match = 1'b1;
                        store_funct3 = t.sq_funct3_out[i];
                        if (t.sq_data_ready_out[i])
                            sq_forward_data_ready = 1'b1;
                        if (cov_lq_valid[li] && cov_lq_old_mask[li][i]) begin
                            distance = (int'(cov_lq_sq_tail[li]) + `SQ_SZ - i) % `SQ_SZ;
                            if (distance == 0)
                                distance = `SQ_SZ;
                            if (distance < best_distance)
                                best_distance = distance;
                        end
                        case (t.sq_funct3_out[i][1:0])
                            2'b00: store_mask = 4'b0001 << t.sq_addr_out[i][1:0];
                            2'b01: store_mask = 4'b0011 << t.sq_addr_out[i][1:0];
                            2'b10: store_mask = 4'b1111;
                            default: store_mask = 4'b0000;
                        endcase
                        case (t.load_execute_pack.funct3[1:0])
                            2'b00: load_mask = 4'b0001 << t.load_execute_pack.addr[1:0];
                            2'b01: load_mask = 4'b0011 << t.load_execute_pack.addr[1:0];
                            2'b10: load_mask = 4'b1111;
                            default: load_mask = 4'b0000;
                        endcase
                        if (((store_mask & load_mask) != 4'b0000) &&
                            ((store_mask & load_mask) != load_mask))
                            partial_overlap_seen = 1'b1;
                    end
                end
                if (best_distance <= `SQ_SZ)
                    dependency_distance = best_distance;
            end

            for (int i = 0; i < `N; i++) begin
                if (t.is_load[i]) begin
                    if (saw_lq_nonzero && t.lq_index[i] == '0)
                        lq_wrap_dispatch = 1'b1;
                    if (t.lq_index[i] != '0)
                        saw_lq_nonzero = 1'b1;
                    cov_lq_valid[t.lq_index[i]] = 1'b1;
                    cov_lq_old_mask[t.lq_index[i]] = t.sq_valid_out_mask[i];
                    cov_lq_sq_tail[t.lq_index[i]] = t.sq_tail_out[i];
                end
                if (t.is_store[i]) begin
                    if (saw_sq_nonzero && t.sq_index[i] == '0)
                        sq_wrap_dispatch = 1'b1;
                    if (t.sq_index[i] != '0)
                        saw_sq_nonzero = 1'b1;
                end
            end

            if (t.load_retire_valid) begin
                int n = (t.load_retire_num == 2) ? 2 : 1;
                repeat (n) begin
                    cov_lq_valid[cov_lq_head] = 1'b0;
                    cov_lq_head++;
                end
            end

            if (t.mispredicted) begin
                lq_occupancy = 0;
                sq_occupancy = 0;
                cov_lq_head = t.BS_lq_tail_in;
                foreach (cov_lq_valid[i]) cov_lq_valid[i] = 1'b0;
            end else begin
                int lq_next = int'(lq_occupancy) + int'(dispatch_load_count);
                int sq_next = int'(sq_occupancy) + int'(dispatch_store_count);
                if (t.load_retire_valid)
                    lq_next -= (t.load_retire_num == 2) ? 2 : 1;
                if (t.sq_out.valid)
                    sq_next -= 1;
                if (lq_next < 0)
                    lq_next = 0;
                if (sq_next < 0)
                    sq_next = 0;
                if (lq_next > `LQ_SZ)
                    lq_next = `LQ_SZ;
                if (sq_next > `SQ_SZ)
                    sq_next = `SQ_SZ;
                lq_occupancy = lq_next;
                sq_occupancy = sq_next;
            end

            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("LSQ_COV",
                $sformatf("Functional coverage = %0.2f%%", cg.get_inst_coverage()),
                UVM_LOW)
        endfunction
    endclass

