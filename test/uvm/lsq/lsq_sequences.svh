    class lsq_base_seq extends uvm_sequence #(lsq_seq_item);
        `uvm_object_utils(lsq_base_seq)
        function new(string name = "lsq_base_seq");
            super.new(name);
        endfunction

        task send(lsq_op_e op, int unsigned lq = 0, int unsigned sq = 0,
                  int unsigned addr = 32'h100, int unsigned data = 0,
                  bit [2:0] funct3 = 3'b010, int unsigned rob = 0,
                  int unsigned tag = `ARCH_REG_SZ,
                  bit dcache_can_accept_load = 1'b1,
                  bit dcache_can_accept_store = 1'b1);
            lsq_seq_item item = lsq_seq_item::type_id::create("item");
            start_item(item);
            item.op = op;
            item.lq_idx = lq;
            item.sq_idx = sq;
            item.addr = addr;
            item.data = data;
            item.funct3 = funct3;
            item.load_funct3 = funct3;
            item.store_funct3 = (funct3 inside {3'b000, 3'b001, 3'b010}) ? funct3 : 3'b010;
            item.rob = rob;
            item.tag = tag;
            item.dcache_can_accept_load = dcache_can_accept_load;
            item.dcache_can_accept_store = dcache_can_accept_store;
            finish_item(item);
        endtask

        task retire_loads(int unsigned count = 1);
            send(LSQ_RETIRE_LOAD, 0, 0, 32'h100, count);
        endtask

        task forward_case(int unsigned lq, int unsigned sq, int unsigned addr,
                          int unsigned store_data, bit [2:0] store_funct3,
                          bit [2:0] load_funct3, int unsigned store_rob,
                          int unsigned load_rob, int unsigned tag);
            send(LSQ_DISP_STORE, 0, sq, addr, 32'h0, store_funct3, store_rob, tag);
            send(LSQ_DISP_LOAD,  lq, sq, addr, 32'h0, load_funct3,  load_rob,  tag);
            send(LSQ_EXEC_STORE, lq, sq, addr, store_data, store_funct3, store_rob, tag);
            send(LSQ_EXEC_LOAD,  lq, sq, addr, 32'h0, load_funct3,  load_rob,  tag);
            repeat (4) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            send(LSQ_RETIRE_STORE, lq, sq, addr, store_data, store_funct3, store_rob, tag);
            repeat (3) send(LSQ_IDLE);
        endtask

        task youngest_store_forward_case(int unsigned lq, int unsigned older_sq,
                                         int unsigned younger_sq, int unsigned addr,
                                         int unsigned older_data, int unsigned younger_data,
                                         bit [2:0] store_funct3, bit [2:0] load_funct3,
                                         int unsigned older_rob, int unsigned younger_rob,
                                         int unsigned load_rob, int unsigned tag);
            send(LSQ_DISP_STORE, 0, older_sq,   addr, 32'h0, store_funct3, older_rob,   tag);
            send(LSQ_DISP_STORE, 0, younger_sq, addr, 32'h0, store_funct3, younger_rob, tag);
            send(LSQ_DISP_LOAD,  lq, younger_sq, addr, 32'h0, load_funct3, load_rob,    tag);
            send(LSQ_EXEC_STORE, lq, older_sq,   addr, older_data,   store_funct3, older_rob,   tag);
            send(LSQ_EXEC_STORE, lq, younger_sq, addr, younger_data, store_funct3, younger_rob, tag);
            send(LSQ_EXEC_LOAD,  lq, younger_sq, addr, 32'h0, load_funct3, load_rob, tag);
            repeat (4) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            send(LSQ_RETIRE_STORE, lq, older_sq,   addr, older_data,   store_funct3, older_rob,   tag);
            repeat (2) send(LSQ_IDLE);
            send(LSQ_RETIRE_STORE, lq, younger_sq, addr, younger_data, store_funct3, younger_rob, tag);
            repeat (4) send(LSQ_IDLE);
        endtask

        task partial_overlap_case(int unsigned lq, int unsigned sq, int unsigned addr,
                                  int unsigned store_data, bit [2:0] store_funct3,
                                  bit [2:0] load_funct3, int unsigned store_rob,
                                  int unsigned load_rob, int unsigned tag,
                                  int unsigned dcache_data);
            send(LSQ_DISP_STORE, 0, sq, addr, 32'h0, store_funct3, store_rob, tag);
            send(LSQ_DISP_LOAD,  lq, sq, addr, 32'h0, load_funct3,  load_rob,  tag);
            send(LSQ_EXEC_STORE, lq, sq, addr, store_data, store_funct3, store_rob, tag);
            send(LSQ_EXEC_LOAD,  lq, sq, addr, 32'h0, load_funct3,  load_rob,  tag);
            repeat (3) send(LSQ_IDLE);
            send(LSQ_RETIRE_STORE, lq, sq, addr, store_data, store_funct3, store_rob, tag);
            repeat (3) send(LSQ_IDLE);
            send(LSQ_CACHE_RETURN, lq, sq, addr, dcache_data, load_funct3, load_rob, tag);
            repeat (2) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            repeat (2) send(LSQ_IDLE);
        endtask
    endclass

    class lsq_directed_seq extends lsq_base_seq;
        `uvm_object_utils(lsq_directed_seq)
        function new(string name = "lsq_directed_seq");
            super.new(name);
        endfunction

        task body();
            `uvm_info("SEQ", "Directed LSQ scenarios: RS-gated loads, forwarding, cache issue, retire", UVM_LOW)

            // Scenario 1: older store exists, so the RS must wait until the
            // store address/data are known before sending load_execute_pack.
            send(LSQ_DISP_STORE, 0, 0, 32'h100, 32'h0, 3'b010, 0, 32);
            send(LSQ_DISP_LOAD,  0, 0, 32'h100, 32'h0, 3'b010, 1, 33);
            repeat (2) send(LSQ_IDLE);

            // Now resolve the store, then the RS releases the load. Same word
            // and ready data should forward to the load.
            send(LSQ_EXEC_STORE, 0, 0, 32'h100, 32'hDEADBEEF, 3'b010, 0, 32);
            send(LSQ_EXEC_LOAD,  0, 0, 32'h100, 32'h0, 3'b010, 1, 33);
            repeat (3) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            send(LSQ_RETIRE_STORE, 0, 0, 32'h100, 32'hDEADBEEF, 3'b010, 0, 32);
            repeat (3) send(LSQ_IDLE);

            // Scenario 2: no older store conflict; load issues to the cache-model and returns.
            send(LSQ_DISP_LOAD,  1, 0, 32'h200, 32'h0, 3'b100, 2, 34);
            send(LSQ_EXEC_LOAD,  1, 0, 32'h200, 32'h0, 3'b100, 2, 34);
            send(LSQ_CACHE_RETURN, 1, 0, 32'h200, 32'hCAFEBABE, 3'b010, 2, 34);
            repeat (3) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);

            // Scenario 3: store/load same dispatch group. Store is older
            // because it is slot 0, so the RS waits for the store address.
            send(LSQ_DISP_STORE_LOAD, 2, 1, 32'h300, 32'h0, 3'b010, 3, 35);
            send(LSQ_EXEC_STORE, 2, 1, 32'h300, 32'h12345678, 3'b010, 3, 35);
            send(LSQ_EXEC_LOAD, 2, 1, 32'h300, 32'h0, 3'b010, 4, 36);
            repeat (4) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            send(LSQ_RETIRE_STORE, 2, 1, 32'h300, 32'h12345678, 3'b010, 3, 35);
            repeat (3) send(LSQ_IDLE);

            // Scenario 4: hand-computed forwarding calibration cases.
            // These fixed ROB ids are checked against explicit expected data
            // in the scoreboard, independent of the general forwarding model.
            `ifdef FWD_WORD
                forward_case(3, 2, 32'h304, 32'haabbccdd, 3'b010, 3'b010, 5, 5, 37);  // SW -> LW = aabbccdd
            `else
                forward_case(3, 2, 32'h304, 32'h00000080, 3'b000, 3'b000, 5, 5, 37);  // SB -> LB  = ffffff80
                forward_case(4, 3, 32'h308, 32'h00000080, 3'b000, 3'b100, 6, 6, 38);  // SB -> LBU = 00000080
                forward_case(5, 4, 32'h30c, 32'h00008001, 3'b001, 3'b001, 7, 7, 39);  // SH -> LH  = ffff8001
                forward_case(6, 5, 32'h310, 32'h00008001, 3'b001, 3'b101, 8, 8, 40);  // SH -> LHU = 00008001
                forward_case(7, 6, 32'h320, 32'haabbccdd, 3'b010, 3'b000, 9, 9, 41);  // SW -> LB  = ffffffdd
                forward_case(0, 7, 32'h324, 32'h00000080, 3'b001, 3'b000, 10, 10, 42); // SH -> LB  = ffffff80
                forward_case(1, 0, 32'h328, 32'h00000080, 3'b001, 3'b100, 11, 11, 43); // SH -> LBU = 00000080
                forward_case(2, 1, 32'h32c, 32'haabbccdd, 3'b010, 3'b100, 12, 12, 44); // SW -> LBU = 000000dd
                forward_case(3, 2, 32'h330, 32'haabbccdd, 3'b010, 3'b001, 13, 13, 45); // SW -> LH  = ffffccdd
                forward_case(4, 3, 32'h334, 32'haabbccdd, 3'b010, 3'b101, 14, 14, 46); // SW -> LHU = 0000ccdd
            `endif

            // Scenario 5: explicitly cover the remaining 2-wide dispatch
            // legal combinations. Execute/issue/retire are still one-wide in
            // this testbench, matching the core contract.
            send(LSQ_DISP_LOAD_LOAD,   0, 0, 32'h400, 32'h0, 3'b001, 20, 52);
            send(LSQ_DISP_STORE_STORE, 0, 2, 32'h500, 32'h0, 3'b000, 22, 54);
            send(LSQ_DISP_LOAD_STORE,  0, 4, 32'h600, 32'h0, 3'b101, 24, 56);
            repeat (4) send(LSQ_IDLE);

            // Scenario 6: recover speculative dispatches, then prove the
            // recovered tail indices are reusable without stale entries.
            send(LSQ_MISPREDICT, 5, 4);
            repeat (2) send(LSQ_IDLE);
            forward_case(5, 4, 32'h700, 32'hfeedface, 3'b010, 3'b010, 25, 25, 57);

            // Scenario 7: cache backpressure. Loads must not issue to dcache
            // while dcache_can_accept_load is low, and retired stores must not
            // commit while dcache_can_accept_store is low.
            send(LSQ_DISP_LOAD,  6, 0, 32'h740, 32'h0, 3'b010, 26, 58);
            send(LSQ_EXEC_LOAD,  6, 0, 32'h740, 32'h0, 3'b010, 26, 58);
            send(LSQ_IDLE,       0, 0, 32'h0,   32'h0, 3'b010, 0, 0, 1'b0, 1'b1);
            send(LSQ_IDLE);
            send(LSQ_CACHE_RETURN, 6, 0, 32'h740, 32'h01020304, 3'b010, 26, 58);
            repeat (2) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);

            send(LSQ_DISP_STORE, 0, 5, 32'h780, 32'h0, 3'b010, 27, 59);
            send(LSQ_EXEC_STORE, 0, 5, 32'h780, 32'h0badcafe, 3'b010, 27, 59);
            send(LSQ_RETIRE_STORE, 0, 5, 32'h780, 32'h0badcafe, 3'b010, 27, 59);
            send(LSQ_IDLE,       0, 0, 32'h0,   32'h0, 3'b010, 0, 0, 1'b1, 1'b0);
            send(LSQ_IDLE);
            repeat (3) send(LSQ_IDLE);

            // Scenario 8: two older stores both match the same load. The load
            // must forward from the youngest matching store, not the oldest one.
            youngest_store_forward_case(7, 6, 7, 32'h7c0,
                32'h11111111, 32'h22222222, 3'b010, 3'b010, 28, 29, 30, 60);

            // Scenario 9: older store partially overlaps the load but does not
            // fully cover it. This cannot forward; it must wait until the store
            // commits, then issue the load to dcache.
            partial_overlap_case(0, 0, 32'h800,
                32'h000000aa, 3'b000, 3'b001, 31, 15, 61, 32'h0000bbaa);

            // Scenario 10: explicitly drive both queues through empty, half,
            // near-full, full, and wrapped occupancy states.
            send(LSQ_DISP_LOAD_LOAD, 0, 0, 32'h900, 32'h0, 3'b010, 16, 32);
            send(LSQ_DISP_LOAD_LOAD, 0, 0, 32'h904, 32'h0, 3'b010, 18, 34);
            send(LSQ_DISP_LOAD_LOAD, 0, 0, 32'h908, 32'h0, 3'b010, 20, 36);
            send(LSQ_DISP_LOAD_LOAD, 0, 0, 32'h90c, 32'h0, 3'b010, 22, 38);
            repeat (`LQ_SZ / 2) retire_loads(2);

            send(LSQ_DISP_STORE_STORE, 0, 0, 32'ha00, 32'h0, 3'b010, 16, 32);
            send(LSQ_DISP_STORE_STORE, 0, 0, 32'ha04, 32'h0, 3'b010, 18, 34);
            send(LSQ_DISP_STORE_STORE, 0, 0, 32'ha08, 32'h0, 3'b010, 20, 36);
            send(LSQ_DISP_STORE_STORE, 0, 0, 32'ha0c, 32'h0, 3'b010, 22, 38);
            for (int i = 1; i < `SQ_SZ; i++) begin
                send(LSQ_EXEC_STORE, 0, i, 32'ha00 + (i * 4), 32'h1000 + i, 3'b010, 16 + i, 32 + i);
                send(LSQ_RETIRE_STORE, 0, i, 32'ha00 + (i * 4), 32'h1000 + i, 3'b010, 16 + i, 32 + i);
                repeat (2) send(LSQ_IDLE);
            end
            send(LSQ_EXEC_STORE, 0, 0, 32'ha1c, 32'h1008, 3'b010, 24, 40);
            send(LSQ_RETIRE_STORE, 0, 0, 32'ha1c, 32'h1008, 3'b010, 24, 40);
            repeat (3) send(LSQ_IDLE);

            // Scenario 11: long dependency distance. The matching older store
            // is five SQ entries older than the load; younger stores are known
            // non-aliases, so the load can still forward from the far match.
            send(LSQ_DISP_STORE, 0, 1, 32'hb00, 32'h0, 3'b010, 16, 32);
            send(LSQ_DISP_STORE, 0, 2, 32'hb10, 32'h0, 3'b010, 17, 33);
            send(LSQ_DISP_STORE, 0, 3, 32'hb20, 32'h0, 3'b010, 18, 34);
            send(LSQ_DISP_STORE, 0, 4, 32'hb30, 32'h0, 3'b010, 19, 35);
            send(LSQ_DISP_STORE, 0, 5, 32'hb40, 32'h0, 3'b010, 20, 36);
            send(LSQ_DISP_LOAD,  1, 5, 32'hb00, 32'h0, 3'b010, 21, 37);
            send(LSQ_EXEC_STORE, 1, 1, 32'hb00, 32'h33333333, 3'b010, 16, 32);
            send(LSQ_EXEC_STORE, 1, 2, 32'hb10, 32'h44444444, 3'b010, 17, 33);
            send(LSQ_EXEC_STORE, 1, 3, 32'hb20, 32'h55555555, 3'b010, 18, 34);
            send(LSQ_EXEC_STORE, 1, 4, 32'hb30, 32'h66666666, 3'b010, 19, 35);
            send(LSQ_EXEC_STORE, 1, 5, 32'hb40, 32'h77777777, 3'b010, 20, 36);
            send(LSQ_EXEC_LOAD,  1, 5, 32'hb00, 32'h0, 3'b010, 21, 37);
            repeat (4) send(LSQ_IDLE);
            send(LSQ_RETIRE_LOAD);
            for (int i = 1; i <= 5; i++) begin
                send(LSQ_RETIRE_STORE, 0, i, 32'hb00 + ((i - 1) * 16), 32'h33333333 + ((i - 1) * 32'h11111111), 3'b010, 15 + i, 31 + i);
                repeat (2) send(LSQ_IDLE);
            end
        endtask
    endclass

    class lsq_smoke_seq extends lsq_base_seq;
        `uvm_object_utils(lsq_smoke_seq)
        function new(string name = "lsq_smoke_seq");
            super.new(name);
        endfunction
        task body();
            repeat (1000) begin
                lsq_seq_item item = lsq_seq_item::type_id::create("rand_item");
                start_item(item);
                if (!item.randomize() with {
                    op dist {LSQ_IDLE := 30, LSQ_DISP_LOAD := 20, LSQ_DISP_STORE := 20,
                             LSQ_DISP_LOAD_LOAD := 5, LSQ_DISP_STORE_STORE := 5,
                             LSQ_DISP_STORE_LOAD := 5, LSQ_DISP_LOAD_STORE := 5};
                }) `uvm_fatal("SEQ", "randomize failed")
                finish_item(item);
            end
        endtask
    endclass
