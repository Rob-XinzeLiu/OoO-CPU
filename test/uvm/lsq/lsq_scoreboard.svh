    class lsq_scoreboard extends uvm_component;
        `uvm_component_utils(lsq_scoreboard)
        uvm_analysis_imp #(lsq_obs, lsq_scoreboard) obs_imp;

        typedef struct {
            bit valid;
            bit addr_ready;
            bit data_ready;
            bit ready_retire;
            ADDR addr;
            DATA data;
            bit [2:0] funct3;
        } sq_m_t;

        typedef struct {
            bit valid;
            bit addr_ready;
            bit data_ready;
            bit issued;
            bit broadcasted;
            ADDR addr;
            DATA data;
            bit [2:0] funct3;
            logic [`SQ_SZ-1:0] old_mask;
            SQ_IDX sq_tail_position;
            PRF_IDX dest_tag;
            ROB_IDX rob_index;
            bit [1:0] generation;
        } lq_m_t;

        sq_m_t sq [`SQ_SZ];
        lq_m_t lq [`LQ_SZ];
        SQ_IDX sq_head, sq_tail;
        LQ_IDX lq_head, lq_tail;
        int unsigned load_issue_count, fwd_count, store_commit_count, manual_calib_count;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            obs_imp = new("obs_imp", this);
        endfunction

        function void reset_model();
            foreach (sq[i]) sq[i] = '{default: '0};
            foreach (lq[i]) lq[i] = '{default: '0};
            sq_head = '0;
            sq_tail = '0;
            lq_head = '0;
            lq_tail = '0;
            manual_calib_count = 0;
        endfunction

        function bit sq_slot_older(lq_m_t le, int j);
            if (le.sq_tail_position == sq_head)
                return 1'b0;
            if (sq_head <= le.sq_tail_position)
                return (SQ_IDX'(j) >= sq_head) && (SQ_IDX'(j) < le.sq_tail_position);
            return (SQ_IDX'(j) >= sq_head) || (SQ_IDX'(j) < le.sq_tail_position);
        endfunction

        function bit has_unknown_older_store(int li);
            for (int j = 0; j < `SQ_SZ; j++) begin
                if (lq[li].old_mask[j] && sq[j].valid && sq_slot_older(lq[li], j) && !sq[j].addr_ready)
                    return 1'b1;
            end
            return 1'b0;
        endfunction

        function bit has_known_same_word_conflict(int li);
            for (int j = 0; j < `SQ_SZ; j++) begin
                if (lq[li].old_mask[j] && sq[j].valid && sq_slot_older(lq[li], j) &&
                    sq[j].addr_ready && (sq[j].addr[31:2] == lq[li].addr[31:2]) && !sq[j].data_ready)
                    return 1'b1;
            end
            return 1'b0;
        endfunction

        function bit has_partial_overlap_unforwardable(int li);
            logic [3:0] store_mask, load_mask;
            for (int j = 0; j < `SQ_SZ; j++) begin
                if (lq[li].old_mask[j] && sq[j].valid && sq_slot_older(lq[li], j) &&
                    sq[j].addr_ready && sq[j].data_ready &&
                    sq[j].addr[31:2] == lq[li].addr[31:2]) begin
                    store_mask = access_mask(sq[j].funct3, sq[j].addr);
                    load_mask = access_mask(lq[li].funct3, lq[li].addr);
                    if (((store_mask & load_mask) != 4'b0000) &&
                        ((store_mask & load_mask) != load_mask))
                        return 1'b1;
                end
            end
            return 1'b0;
        endfunction

        function void clear_sq_from_tail(SQ_IDX new_tail);
            if (new_tail == sq_tail)
                return;
            if (new_tail < sq_tail) begin
                for (int i = 0; i < `SQ_SZ; i++)
                    if (SQ_IDX'(i) >= new_tail && SQ_IDX'(i) < sq_tail)
                        sq[i] = '{default: '0};
            end else begin
                for (int i = 0; i < `SQ_SZ; i++)
                    if (SQ_IDX'(i) >= new_tail || SQ_IDX'(i) < sq_tail)
                        sq[i] = '{default: '0};
            end
        endfunction

        function void clear_lq_from_tail(LQ_IDX new_tail);
            if (new_tail == lq_tail)
                return;
            if (new_tail < lq_tail) begin
                for (int i = 0; i < `LQ_SZ; i++)
                    if (LQ_IDX'(i) >= new_tail && LQ_IDX'(i) < lq_tail)
                        lq[i].valid = 1'b0;
            end else begin
                for (int i = 0; i < `LQ_SZ; i++)
                    if (LQ_IDX'(i) >= new_tail || LQ_IDX'(i) < lq_tail)
                        lq[i].valid = 1'b0;
            end
        endfunction

        function logic [3:0] access_mask(bit [2:0] funct3, ADDR addr);
            case (funct3[1:0])
                2'b00: return 4'b0001 << addr[1:0];
                2'b01: return 4'b0011 << addr[1:0];
                2'b10: return 4'b1111;
                default: return 4'b0000;
            endcase
        endfunction

        function DATA store_to_word(sq_m_t se);
            DATA word;
            word = '0;
            case (se.funct3[1:0])
                2'b00: begin
                    case (se.addr[1:0])
                        2'b00: word[7:0]   = se.data[7:0];
                        2'b01: word[15:8]  = se.data[7:0];
                        2'b10: word[23:16] = se.data[7:0];
                        2'b11: word[31:24] = se.data[7:0];
                    endcase
                end
                2'b01: begin
                    if (se.addr[1])
                        word[31:16] = se.data[15:0];
                    else
                        word[15:0] = se.data[15:0];
                end
                2'b10: word = se.data;
                default: word = se.data;
            endcase
            return word;
        endfunction

        function DATA load_from_word(lq_m_t le, DATA word);
            logic [7:0] byte_data;
            logic [15:0] half_data;
            case (le.funct3[1:0])
                2'b00: begin
                    case (le.addr[1:0])
                        2'b00: byte_data = word[7:0];
                        2'b01: byte_data = word[15:8];
                        2'b10: byte_data = word[23:16];
                        2'b11: byte_data = word[31:24];
                    endcase
                    return le.funct3[2] ? {24'b0, byte_data} : {{24{byte_data[7]}}, byte_data};
                end
                2'b01: begin
                    half_data = le.addr[1] ? word[31:16] : word[15:0];
                    return le.funct3[2] ? {16'b0, half_data} : {{16{half_data[15]}}, half_data};
                end
                2'b10: return word;
                default: return word;
            endcase
        endfunction

        function bit can_forward_data(int li, output DATA fwd_data);
            bit hit;
            SQ_IDX best;
            logic [3:0] store_mask, load_mask;
            hit = 1'b0;
            best = '0;
            fwd_data = '0;
            for (int off = 0; off < `SQ_SZ; off++) begin
                int j = (int'(lq[li].sq_tail_position) + `SQ_SZ - 1 - off) % `SQ_SZ;
                if (lq[li].old_mask[j] && sq[j].valid && sq_slot_older(lq[li], j) &&
                    sq[j].addr_ready && sq[j].data_ready &&
                    sq[j].addr[31:2] == lq[li].addr[31:2]) begin
                    store_mask = access_mask(sq[j].funct3, sq[j].addr);
                    load_mask = access_mask(lq[li].funct3, lq[li].addr);
                    if ((store_mask & load_mask) == load_mask) begin
                        hit = 1'b1;
                        best = SQ_IDX'(j);
                        break;
                    end
                end
            end
            if (hit) fwd_data = load_from_word(lq[li], store_to_word(sq[best]));
            return hit;
        endfunction

        function bit manual_forward_expected(ROB_IDX rob, output DATA expected);
            expected = '0;
            case (int'(rob))
                1: begin expected = 32'hdead_beef; return 1'b1; end // SW deadbeef -> LW
                4: begin expected = 32'h1234_5678; return 1'b1; end // SW 12345678 -> LW
                `ifdef FWD_WORD
                5: begin expected = 32'haabb_ccdd; return 1'b1; end // SW aabbccdd -> LW
                `else
                5: begin expected = 32'hffff_ff80; return 1'b1; end // SB 80 -> LB
                6: begin expected = 32'h0000_0080; return 1'b1; end // SB 80 -> LBU
                7: begin expected = 32'hffff_8001; return 1'b1; end // SH 8001 -> LH
                8: begin expected = 32'h0000_8001; return 1'b1; end // SH 8001 -> LHU
                9: begin expected = 32'hffff_ffdd; return 1'b1; end // SW aabbccdd -> LB byte 0
                10: begin expected = 32'hffff_ff80; return 1'b1; end // SH 0080 -> LB byte 0
                11: begin expected = 32'h0000_0080; return 1'b1; end // SH 0080 -> LBU byte 0
                12: begin expected = 32'h0000_00dd; return 1'b1; end // SW aabbccdd -> LBU byte 0
                13: begin expected = 32'hffff_ccdd; return 1'b1; end // SW aabbccdd -> LH low half
                14: begin expected = 32'h0000_ccdd; return 1'b1; end // SW aabbccdd -> LHU low half
                `endif
                30: begin expected = 32'h2222_2222; return 1'b1; end // two matching stores -> youngest wins
                default: return 1'b0;
            endcase
        endfunction

        function void check_outputs(lsq_obs obs);
            if (obs.load_retire_valid && obs.load_retire_num > 2'd2)
                `uvm_error("RETIRE_PROTOCOL", "Load retire tried to retire an unsupported number of entries")

            if (obs.store_retire_pack[0].valid && obs.store_retire_pack[1].valid)
                `uvm_error("ONE_WIDE_PIPE_PROTOCOL", "Store retire tried to retire more than one entry in one cycle")

            if (obs.load_packet.valid) begin
                int li = int'(obs.load_packet.lq_index);
                load_issue_count++;
                if (!obs.dcache_can_accept_load)
                    `uvm_error("DCACHE_BACKPRESSURE",
                        $sformatf("LQ issued load LQ[%0d] while dcache_can_accept_load was low", li))
                if (has_unknown_older_store(li))
                    `uvm_error("LOAD_ISSUE_ORDER",
                        $sformatf("Load LQ[%0d] issued to dcache while an older store address is still unknown", li))
                if (has_known_same_word_conflict(li))
                    `uvm_error("LOAD_STORE_HAZARD",
                        $sformatf("Load LQ[%0d] issued despite same-word older store with data not ready", li))
                if (has_partial_overlap_unforwardable(li))
                    `uvm_error("PARTIAL_OVERLAP",
                        $sformatf("Load LQ[%0d] issued to dcache before partially-overlapping older store committed", li))
            end

            if (obs.lq_out.valid) begin
                int li = -1;
                DATA fwd_data;
                DATA manual_data;
                fwd_count++;
                for (int i = 0; i < `LQ_SZ; i++) begin
                    if (lq[i].valid && lq[i].rob_index == obs.lq_out.rob_index && lq[i].dest_tag == obs.lq_out.dest_tag)
                        li = i;
                end
                if (li >= 0 && can_forward_data(li, fwd_data) && obs.lq_out.data !== fwd_data)
                    `uvm_error("FWD_DATA", $sformatf("Forwarded load data mismatch: got %08x expected %08x",
                        obs.lq_out.data, fwd_data))
                if (manual_forward_expected(obs.lq_out.rob_index, manual_data)) begin
                    manual_calib_count++;
                    if (obs.lq_out.data !== manual_data)
                        `uvm_error("FWD_CALIB",
                            $sformatf("Hand-computed forwarding case ROB[%0d] mismatch: got %08x expected %08x",
                                obs.lq_out.rob_index, obs.lq_out.data, manual_data))
                end
            end

            if (obs.sq_out.valid) begin
                store_commit_count++;
                if (!obs.dcache_can_accept_store)
                    `uvm_error("DCACHE_BACKPRESSURE",
                        "SQ committed store while dcache_can_accept_store was low")
                if (!sq[sq_head].valid || !sq[sq_head].ready_retire)
                    `uvm_error("STORE_ORDER", "SQ committed a store that was not the modeled retired head")
                else begin
                    if (obs.sq_out.addr !== sq[sq_head].addr)
                        `uvm_error("STORE_COMMIT_DATA",
                            $sformatf("SQ committed wrong addr: got %08x expected %08x",
                                obs.sq_out.addr, sq[sq_head].addr))
                    if (obs.sq_out.data !== sq[sq_head].data)
                        `uvm_error("STORE_COMMIT_DATA",
                            $sformatf("SQ committed wrong data: got %08x expected %08x",
                                obs.sq_out.data, sq[sq_head].data))
                    if (obs.sq_out.funct3 !== sq[sq_head].funct3)
                        `uvm_error("STORE_COMMIT_DATA",
                            $sformatf("SQ committed wrong funct3: got %03b expected %03b",
                                obs.sq_out.funct3, sq[sq_head].funct3))
                end
            end
        endfunction

        function void update_model(lsq_obs obs);
            if (obs.sq_out.valid) begin
                sq[sq_head] = '{default: '0};
                sq_head++;
            end

            foreach (obs.store_retire_pack[i]) begin
                if (obs.store_retire_pack[i].valid && sq[obs.store_retire_pack[i].sq_index].valid &&
                    sq[obs.store_retire_pack[i].sq_index].addr_ready &&
                    sq[obs.store_retire_pack[i].sq_index].data_ready)
                    sq[obs.store_retire_pack[i].sq_index].ready_retire = 1'b1;
            end

            if (obs.store_execute_pack.valid && sq[obs.store_execute_pack.sq_index].valid) begin
                sq[obs.store_execute_pack.sq_index].addr = obs.store_execute_pack.addr;
                sq[obs.store_execute_pack.sq_index].data = obs.store_execute_pack.data;
                sq[obs.store_execute_pack.sq_index].funct3 = obs.store_execute_pack.funct3;
                sq[obs.store_execute_pack.sq_index].addr_ready = 1'b1;
                sq[obs.store_execute_pack.sq_index].data_ready = 1'b1;
            end

            if (obs.load_packet.valid)
                lq[obs.load_packet.lq_index].issued = 1'b1;

            if (obs.dcache_load_valid) begin
                int li = int'(obs.dcache_load_lq_index);
                if (!lq[li].valid)
                    `uvm_error("CACHE_RETURN", $sformatf("Cache return targeted to invalid LQ[%0d]", li))
                else if (!lq[li].issued)
                    `uvm_error("CACHE_RETURN", $sformatf("Cache return targeted to LQ[%0d] that was not issued", li))
                else if (obs.dcache_load_generation !== lq[li].generation)
                    `uvm_error("CACHE_RETURN",
                        $sformatf("Dcache return generation mismatch for LQ[%0d]: got %0d expected %0d",
                            li, obs.dcache_load_generation, lq[li].generation))
                else begin
                    lq[li].data = obs.dcache_load_data;
                    lq[li].data_ready = 1'b1;
                    lq[li].issued = 1'b0;
                end
            end

            if (obs.load_execute_pack.valid && lq[obs.load_execute_pack.lq_index].valid) begin
                lq[obs.load_execute_pack.lq_index].addr = obs.load_execute_pack.addr;
                lq[obs.load_execute_pack.lq_index].funct3 = obs.load_execute_pack.funct3;
                lq[obs.load_execute_pack.lq_index].addr_ready = 1'b1;
            end

            if (obs.lq_out.valid) begin
                for (int i = 0; i < `LQ_SZ; i++) begin
                    if (lq[i].valid && lq[i].rob_index == obs.lq_out.rob_index && lq[i].dest_tag == obs.lq_out.dest_tag) begin
                        lq[i].data = obs.lq_out.data;
                        lq[i].data_ready = 1'b1;
                        lq[i].broadcasted = 1'b1;
                    end
                end
            end

            if (obs.load_retire_valid) begin
                int n = (obs.load_retire_num == 2) ? 2 : 1;
                repeat (n) begin
                    lq[lq_head].valid = 1'b0;
                    lq_head++;
                end
            end

            if (obs.mispredicted) begin
                clear_sq_from_tail(obs.BS_sq_tail_in);
                clear_lq_from_tail(obs.BS_lq_tail_in);
                sq_tail = obs.BS_sq_tail_in;
                lq_tail = obs.BS_lq_tail_in;
            end else begin
                for (int i = 0; i < `N; i++) begin
                    if (obs.is_store[i]) begin
                        SQ_IDX idx = sq_tail;
                        if (obs.sq_index[i] !== idx)
                            `uvm_error("SQ_ALLOC_INDEX",
                                $sformatf("SQ dispatch slot%0d allocated index %0d, expected %0d",
                                    i, obs.sq_index[i], idx))
                        sq[idx].valid = 1'b1;
                        sq[idx].funct3 = obs.store_funct3[i];
                        sq_tail = idx + 1'b1;
                    end
                    if (obs.is_load[i]) begin
                        LQ_IDX idx = lq_tail;
                        if (obs.lq_index[i] !== idx)
                            `uvm_error("LQ_ALLOC_INDEX",
                                $sformatf("LQ dispatch slot%0d allocated index %0d, expected %0d",
                                    i, obs.lq_index[i], idx))
                        lq[idx].valid = 1'b1;
                        lq[idx].funct3 = obs.load_funct3[i];
                        lq[idx].dest_tag = obs.dest_tag_in[i];
                        lq[idx].rob_index = obs.rob_index[i];
                        lq[idx].old_mask = obs.sq_valid_out_mask[i];
                        lq[idx].sq_tail_position = obs.sq_tail_out[i];
                        lq[idx].generation++;
                        lq_tail = idx + 1'b1;
                    end
                end
            end
        endfunction

        function void write(lsq_obs obs);
            if (obs.reset) begin
                reset_model();
                return;
            end
            check_outputs(obs);
            update_model(obs);
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("LSQ_SB", $sformatf("Observed load_issues=%0d forwarded/broadcasted_loads=%0d store_commits=%0d manual_forward_calibrations=%0d",
                load_issue_count, fwd_count, store_commit_count, manual_calib_count), UVM_LOW)
        endfunction
    endclass

