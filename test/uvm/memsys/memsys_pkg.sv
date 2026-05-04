// memsys_pkg.sv - UVM tests for Dcache + MSHR + victim cache + write buffer.
`ifndef MEMSYS_PKG_SV
`define MEMSYS_PKG_SV
`include "sys_defs.svh"

import uvm_pkg::*;

package memsys_pkg;
    import uvm_pkg::*;
    import sys_defs_pkg::*;
    `include "uvm_macros.svh"

    typedef enum logic [4:0] {
        MEMSYS_IDLE,
        MEMSYS_LOAD,
        MEMSYS_STORE,
        MEMSYS_ACCEPT_MEM,
        MEMSYS_RETURN_MEM,
        MEMSYS_EXPECT_RSP,
        MEMSYS_EXPECT_TRUE_MISS,
        MEMSYS_EXPECT_ACCEPT,
        MEMSYS_EXPECT_WB_STORE
    } memsys_op_e;

    class memsys_seq_item extends uvm_sequence_item;
        `uvm_object_utils(memsys_seq_item)

        rand memsys_op_e op;
        rand int unsigned cycles;
        rand int unsigned addr;
        rand int unsigned data;
        rand int unsigned block;
        rand int unsigned lq_idx;
        rand bit [1:0] generation;
        rand bit [2:0] funct3;
        rand bit [3:0] mem_tag;
        rand bit grant;
        rand bit expect_valid;
        rand bit expect_dcache_hit;
        rand bit expect_vc_hit;
        rand bit expect_wb_hit;
        rand bit expect_miss_queue_full;

        constraint c_basic {
            cycles inside {[1:80]};
            lq_idx inside {[0:`LQ_SZ-1]};
            funct3 inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101};
            mem_tag inside {[1:`NUM_MEM_TAGS]};
            addr[1:0] == 2'b00;
        }

        function new(string name = "memsys_seq_item");
            super.new(name);
            op = MEMSYS_IDLE;
            cycles = 1;
            addr = 32'h1000;
            data = 32'h0;
            block = 64'h0;
            lq_idx = 0;
            generation = 0;
            funct3 = 3'b010;
            mem_tag = 1;
            grant = 1'b1;
            expect_valid = 1'b1;
            expect_dcache_hit = 1'b0;
            expect_vc_hit = 1'b0;
            expect_wb_hit = 1'b0;
            expect_miss_queue_full = 1'b0;
        endfunction

        function string convert2string();
            return $sformatf("%s addr=%08x data=%08x block=%016x lq=%0d gen=%0d f3=%03b tag=%0d",
                op.name(), addr, data, block, lq_idx, generation, funct3, mem_tag);
        endfunction
    endclass

    class memsys_base_seq extends uvm_sequence #(memsys_seq_item);
        `uvm_object_utils(memsys_base_seq)
        int unsigned next_lq = 0;
        int unsigned next_tag = 1;

        function new(string name = "memsys_base_seq");
            super.new(name);
        endfunction

        function automatic int unsigned line_addr(int unsigned tag, int unsigned set = 0);
            return (tag << (`DCACHE_SET_BITS + `DCACHE_OFFSET_BITS)) |
                   (set << `DCACHE_OFFSET_BITS);
        endfunction

        task send(memsys_op_e op, int unsigned addr = 32'h0, int unsigned data = 32'h0,
                  longint unsigned block = 64'h0, bit [2:0] funct3 = 3'b010,
                  int unsigned lq = 0, int unsigned tag = 1, bit grant = 1'b1,
                  bit expect_valid = 1'b1, bit exp_dh = 1'b0,
                  bit exp_vh = 1'b0, bit exp_wh = 1'b0,
                  bit exp_full = 1'b0, int unsigned cycles = 1);
            memsys_seq_item item = memsys_seq_item::type_id::create("item");
            start_item(item);
            item.op = op;
            item.addr = addr;
            item.data = data;
            item.block = block[63:0];
            item.funct3 = funct3;
            item.lq_idx = lq;
            item.generation = lq[1:0];
            item.mem_tag = tag[3:0];
            item.grant = grant;
            item.expect_valid = expect_valid;
            item.expect_dcache_hit = exp_dh;
            item.expect_vc_hit = exp_vh;
            item.expect_wb_hit = exp_wh;
            item.expect_miss_queue_full = exp_full;
            item.cycles = cycles;
            finish_item(item);
        endtask

        task idle(int unsigned cycles = 1, bit grant = 1'b1);
            send(MEMSYS_IDLE, .cycles(cycles), .grant(grant));
        endtask

        task load(input int unsigned addr, input int unsigned lq, input bit [2:0] funct3 = 3'b010,
                  input bit exp_dh = 1'b0, input bit exp_vh = 1'b0, input bit exp_wh = 1'b0);
            send(MEMSYS_LOAD, addr, 0, 0, funct3, lq, 1, 1'b1, 1'b1, exp_dh, exp_vh, exp_wh);
        endtask

        task store(input int unsigned addr, input int unsigned data, input bit [2:0] funct3 = 3'b010,
                   input bit exp_dh = 1'b0, input bit exp_vh = 1'b0, input bit exp_wh = 1'b0);
            send(MEMSYS_STORE, addr, data, 0, funct3, 0, 1, 1'b1, 1'b1, exp_dh, exp_vh, exp_wh);
        endtask

        task accept_mem(input int unsigned tag, input int unsigned expected_addr = 0);
            send(MEMSYS_ACCEPT_MEM, .addr(expected_addr), .tag(tag));
        endtask

        task return_mem(input int unsigned tag, input longint unsigned block);
            send(MEMSYS_RETURN_MEM, .block(block), .tag(tag));
            idle(2);
        endtask

        task expect_rsp(input int unsigned data, input int unsigned lq,
                        input bit exp_dh = 1'b0, input bit exp_vh = 1'b0, input bit exp_wh = 1'b0);
            send(MEMSYS_EXPECT_RSP, .data(data), .lq(lq),
                 .exp_dh(exp_dh), .exp_vh(exp_vh), .exp_wh(exp_wh));
        endtask

        task expect_true_miss();
            send(MEMSYS_EXPECT_TRUE_MISS);
        endtask

        task expect_accept(input bit can_load, input bit can_store, input bit full = 1'b0);
            send(MEMSYS_EXPECT_ACCEPT, .data({30'b0, can_store, can_load}), .exp_full(full));
        endtask

        task fill_line(input int unsigned addr, input longint unsigned block, input int unsigned lq);
            int unsigned tag;
            tag = ((next_tag - 1) % `NUM_MEM_TAGS) + 1;
            next_tag++;
            load(addr, lq);
            expect_true_miss();
            accept_mem(tag, addr);
            return_mem(tag, block);
            expect_rsp(block[31:0], lq);
            idle();
        endtask

        task body();
        endtask
    endclass

    class memsys_directed_seq extends memsys_base_seq;
        `uvm_object_utils(memsys_directed_seq)
        function new(string name = "memsys_directed_seq");
            super.new(name);
        endfunction

        task body();
            int unsigned a0, a1, a2, a3, a4, a5, a6, a7, a8, a9;
            `uvm_info("SEQ", "Directed memory-subsystem scenarios: hits, misses, VC/WB hits, fullness backpressure", UVM_LOW)

            a0 = line_addr(0, 0);
            a1 = line_addr(1, 0);
            a2 = line_addr(2, 0);
            a3 = line_addr(3, 0);
            a4 = line_addr(4, 0);
            a5 = line_addr(5, 0);
            a6 = line_addr(6, 0);
            a7 = line_addr(7, 0);
            a8 = line_addr(8, 0);
            a9 = line_addr(9, 0);

            // Cold miss, refill, then back-to-back dcache hits.
            fill_line(a0, 64'h1111_2222_AAAA_0000, 0);
            load(a0, 1, 3'b010, 1'b1);
            expect_rsp(32'hAAAA_0000, 1, 1'b1);
            load(a0 + 4, 2, 3'b010, 1'b1);
            expect_rsp(32'h1111_2222, 2, 1'b1);

            // MSHR full/backpressure: keep memory from accepting requests and
            // issue enough independent misses to fill the FIFO.
            for (int i = 0; i < `MSHR_ENTRIES; i++) begin
                load(line_addr(16 + i, 1), i % `LQ_SZ);
                expect_true_miss();
                idle(1, 1'b0);
            end
            expect_accept(1'b0, 1'b0, 1'b1);
            idle(2, 1'b1);
            // Drain in rounds of NUM_MEM_TAGS to avoid tag collision when
            // MSHR_ENTRIES > NUM_MEM_TAGS (16 vs 15 in the default config).
            begin
                int unsigned drained, chunk;
                drained = 0;
                while (drained < `MSHR_ENTRIES) begin
                    chunk = (`MSHR_ENTRIES - drained < `NUM_MEM_TAGS) ?
                            (`MSHR_ENTRIES - drained) : `NUM_MEM_TAGS;
                    for (int j = 0; j < int'(chunk); j++)
                        accept_mem(j + 1);
                    for (int j = 0; j < int'(chunk); j++)
                        return_mem(j + 1, 64'hCA00_0000_0000_0000 + drained + j);
                    drained += chunk;
                end
            end
            idle(4);

            // Populate one set, dirty a0, age it, then evict it into victim cache.
            fill_line(a1, 64'h2222_2222_BBBB_0001, 3);
            fill_line(a2, 64'h3333_3333_CCCC_0002, 4);
            fill_line(a3, 64'h4444_4444_DDDD_0003, 5);
            store(a0, 32'hDEAD_BEEF, 3'b010, 1'b1);
            idle();
            load(a1, 6, 3'b010, 1'b1); expect_rsp(32'hBBBB_0001, 6, 1'b1);
            load(a2, 7, 3'b010, 1'b1); expect_rsp(32'hCCCC_0002, 7, 1'b1);
            load(a3, 0, 3'b010, 1'b1); expect_rsp(32'hDDDD_0003, 0, 1'b1);
            fill_line(a4, 64'h5555_5555_EEEE_0004, 1);
            load(a0, 2, 3'b010, 1'b0, 1'b1);
            expect_rsp(32'hDEAD_BEEF, 2, 1'b0, 1'b1);

            // Push more dirty evictions through VC. This attempts to cover
            // write-buffer hits and always checks that WB emits stores.
            store(a1, 32'h0101_0101, 3'b010, 1'b1);
            store(a2, 32'h0202_0202, 3'b010, 1'b1);
            store(a3, 32'h0303_0303, 3'b010, 1'b1);
            store(a4, 32'h0404_0404, 3'b010, 1'b1);
            fill_line(a5, 64'h6666_6666_F00D_0005, 3);
            fill_line(a6, 64'h7777_7777_F00D_0006, 4);
            fill_line(a7, 64'h8888_8888_F00D_0007, 5);
            fill_line(a8, 64'h9999_9999_F00D_0008, 6);
            idle(8, 1'b0);
            send(MEMSYS_EXPECT_WB_STORE);

            // Continue pressure until the VC cannot accept because WB is full.
            for (int i = 0; i < `WB_ENTRIES + 3; i++) begin
                fill_line(line_addr(32 + i, 0), 64'hABCD_0000_0000_0000 + i, i % `LQ_SZ);
                idle(1, 1'b0);
            end
            expect_accept(1'b0, 1'b0, 1'b1);
            idle(10, 1'b1);
        endtask
    endclass

    class memsys_smoke_seq extends memsys_base_seq;
        `uvm_object_utils(memsys_smoke_seq)
        function new(string name = "memsys_smoke_seq");
            super.new(name);
        endfunction
        task body();
            // Track in-flight tags so RETURN_MEM only references accepted tags.
            int unsigned pending[$];
            repeat (200) begin
                memsys_seq_item item = memsys_seq_item::type_id::create("rand_item");
                start_item(item);

                if (pending.size() == 0) begin
                    // No accepted transactions yet; RETURN_MEM is not legal.
                    if (!item.randomize() with {
                        op dist {MEMSYS_IDLE := 45, MEMSYS_LOAD := 30, MEMSYS_STORE := 15,
                                 MEMSYS_ACCEPT_MEM := 10};
                        addr[2:0] == 3'b000;
                    }) `uvm_fatal("SEQ", "randomize failed")
                end else if (pending.size() >= `NUM_MEM_TAGS) begin
                    // All tags in use; avoid issuing another ACCEPT_MEM.
                    if (!item.randomize() with {
                        op dist {MEMSYS_IDLE := 50, MEMSYS_LOAD := 20, MEMSYS_STORE := 10,
                                 MEMSYS_RETURN_MEM := 20};
                        addr[2:0] == 3'b000;
                    }) `uvm_fatal("SEQ", "randomize failed")
                end else begin
                    if (!item.randomize() with {
                        op dist {MEMSYS_IDLE := 35, MEMSYS_LOAD := 22, MEMSYS_STORE := 13,
                                 MEMSYS_ACCEPT_MEM := 15, MEMSYS_RETURN_MEM := 15};
                        addr[2:0] == 3'b000;
                    }) `uvm_fatal("SEQ", "randomize failed")
                end

                // Assign a legal tag based on the chosen operation.
                if (item.op == MEMSYS_ACCEPT_MEM) begin
                    bit found;
                    found = 1'b0;
                    for (int t = 1; t <= `NUM_MEM_TAGS && !found; t++) begin
                        bit in_use;
                        in_use = 1'b0;
                        foreach (pending[k]) if (int'(pending[k]) == t) in_use = 1'b1;
                        if (!in_use) begin item.mem_tag = t[3:0]; found = 1'b1; end
                    end
                    if (found) pending.push_back(item.mem_tag);
                    else       item.op = MEMSYS_IDLE;
                end else if (item.op == MEMSYS_RETURN_MEM) begin
                    int unsigned idx;
                    idx = $urandom_range(0, pending.size() - 1);
                    item.mem_tag = pending[idx][3:0];
                    pending.delete(idx);
                end

                finish_item(item);
            end
        endtask
    endclass

    class memsys_driver extends uvm_driver #(memsys_seq_item);
        `uvm_component_utils(memsys_driver)
        virtual memsys_if vif;
        int unsigned req_count, miss_count, rsp_count, vc_hit_count, wb_hit_count;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual memsys_if)::get(this, "", "memsys_vif", vif))
                `uvm_fatal("NOVIF", "memsys_vif not found")
        endfunction

        task check_rsp(memsys_seq_item item);
            int waited;
            waited = 0;
            while (item.expect_valid && !vif.drv_cb.cache_resp_data.valid && waited < 20) begin
                @(vif.drv_cb);
                vif.clear_core_req();
                vif.clear_mem_rsp();
                vif.drv_cb.grant <= item.grant;
                waited++;
            end
            if (vif.drv_cb.cache_resp_data.valid !== item.expect_valid)
                `uvm_error("RSP", $sformatf("response valid mismatch exp=%0b got=%0b item=%s",
                    item.expect_valid, vif.drv_cb.cache_resp_data.valid, item.convert2string()))
            if (item.expect_valid) begin
                if (vif.drv_cb.cache_resp_data.valid) rsp_count++;
                if (vif.drv_cb.cache_resp_data.data !== DATA'(item.data))
                    `uvm_error("RSP", $sformatf("response data mismatch exp=%08x got=%08x",
                        DATA'(item.data), vif.drv_cb.cache_resp_data.data))
                if (vif.drv_cb.cache_resp_data.lq_index !== LQ_IDX'(item.lq_idx))
                    `uvm_error("RSP", $sformatf("response lq mismatch exp=%0d got=%0d",
                        item.lq_idx, vif.drv_cb.cache_resp_data.lq_index))
            end
            if (item.expect_dcache_hit && !vif.drv_cb.dcache_hit)
                `uvm_error("HIT", "expected dcache hit but got miss")
            if (item.expect_vc_hit && !vif.drv_cb.vc_hit)
                `uvm_error("HIT", "expected victim-cache hit but got miss")
            if (item.expect_wb_hit && !vif.drv_cb.wb_hit)
                `uvm_error("HIT", "expected write-buffer hit but got miss")
        endtask

        task drive_item(memsys_seq_item item);
            vif.clear_core_req();
            vif.clear_mem_rsp();
            vif.drv_cb.grant <= item.grant;

            case (item.op)
                MEMSYS_IDLE: begin
                    repeat (item.cycles - 1) begin
                        @(vif.drv_cb);
                        vif.clear_core_req();
                        vif.clear_mem_rsp();
                        vif.drv_cb.grant <= item.grant;
                    end
                end
                MEMSYS_LOAD: begin
                    req_count++;
                    vif.drv_cb.load_req_pack.valid      <= 1'b1;
                    vif.drv_cb.load_req_pack.addr       <= ADDR'(item.addr);
                    vif.drv_cb.load_req_pack.funct3     <= item.funct3;
                    vif.drv_cb.load_req_pack.lq_index   <= LQ_IDX'(item.lq_idx);
                    vif.drv_cb.load_req_pack.generation <= item.generation;
                    #1;
                    if (!item.expect_dcache_hit && !item.expect_vc_hit && !item.expect_wb_hit && !vif.drv_cb.miss_request.valid)
                        `uvm_info("MISS_SOFT", $sformatf("load did not produce immediate miss_request: %s", item.convert2string()), UVM_MEDIUM)
                end
                MEMSYS_STORE: begin
                    req_count++;
                    vif.drv_cb.store_req_pack.valid  <= 1'b1;
                    vif.drv_cb.store_req_pack.addr   <= ADDR'(item.addr);
                    vif.drv_cb.store_req_pack.data   <= DATA'(item.data);
                    vif.drv_cb.store_req_pack.funct3 <= item.funct3;
                    #1;
                    if (item.expect_dcache_hit && !vif.drv_cb.dcache_hit)
                        `uvm_error("HIT", "expected store dcache hit but got miss")
                    if (item.expect_vc_hit && !vif.drv_cb.vc_hit)
                        `uvm_error("HIT", "expected store victim-cache hit but got miss")
                    if (item.expect_wb_hit && !vif.drv_cb.wb_hit)
                        `uvm_error("HIT", "expected store write-buffer hit but got miss")
                end
                MEMSYS_ACCEPT_MEM: begin
                    int waited;
                    waited = 0;
                    while (vif.drv_cb.mshr2mem_command != 2'h1 && waited < 80) begin
                        @(vif.drv_cb);
                        vif.clear_core_req();
                        vif.clear_mem_rsp();
                        vif.drv_cb.grant <= item.grant;
                        waited++;
                    end
                    if (vif.drv_cb.mshr2mem_command != 2'h1)
                        `uvm_error("MEM", $sformatf("timed out waiting for MSHR MEM_LOAD for tag %0d", item.mem_tag))
                    if (item.addr != 0 && vif.drv_cb.mshr2mem_addr !== ADDR'(item.addr))
                        `uvm_error("MEM", $sformatf("MSHR addr mismatch exp=%08x got=%08x for tag %0d",
                            item.addr, vif.drv_cb.mshr2mem_addr, item.mem_tag))
                    vif.drv_cb.mem2proc_transaction_tag <= MEM_TAG'(item.mem_tag);
                    vif.drv_cb.grant <= 1'b1;
                end
                MEMSYS_RETURN_MEM: begin
                    vif.drv_cb.mem2proc_data_tag <= MEM_TAG'(item.mem_tag);
                    vif.drv_cb.mem2proc_data     <= MEM_BLOCK'(item.block);
                end
                MEMSYS_EXPECT_RSP: begin
                    #1;
                    check_rsp(item);
                end
                MEMSYS_EXPECT_TRUE_MISS: begin
                    #1;
                    miss_count++;
                    if (!vif.drv_cb.miss_request.valid)
                        `uvm_error("MISS", "expected a dcache miss_request but valid was not asserted")
                    if (vif.drv_cb.dcache_hit || vif.drv_cb.vc_hit || vif.drv_cb.wb_hit)
                        `uvm_error("MISS", $sformatf("expected true miss, got dh=%0b vh=%0b wh=%0b",
                            vif.drv_cb.dcache_hit, vif.drv_cb.vc_hit, vif.drv_cb.wb_hit))
                end
                MEMSYS_EXPECT_ACCEPT: begin
                    #1;
                    if (vif.drv_cb.dcache_can_accept_load !== item.data[0])
                        `uvm_error("ACCEPT", $sformatf("load accept exp=%0b got=%0b",
                            item.data[0], vif.drv_cb.dcache_can_accept_load))
                    if (vif.drv_cb.dcache_can_accept_store !== item.data[1])
                        `uvm_error("ACCEPT", $sformatf("store accept exp=%0b got=%0b",
                            item.data[1], vif.drv_cb.dcache_can_accept_store))
                    if (item.expect_miss_queue_full && !vif.drv_cb.miss_queue_full && !vif.drv_cb.wb_full)
                        `uvm_error("ACCEPT", "expected MSHR or write-buffer full backpressure but neither was full")
                end
                MEMSYS_EXPECT_WB_STORE: begin
                    #1;
                    if (vif.drv_cb.wb2mem_command != 2'h2)
                        `uvm_error("WB", "expected write buffer to issue MEM_STORE but command was not asserted")
                end
                default: begin
                end
            endcase

            if (vif.drv_cb.vc_hit) vc_hit_count++;
            if (vif.drv_cb.wb_hit) wb_hit_count++;
        endtask

        task run_phase(uvm_phase phase);
            vif.apply_reset();
            forever begin
                memsys_seq_item item;
                seq_item_port.get_next_item(item);
                @(vif.drv_cb);
                drive_item(item);
                seq_item_port.item_done();
            end
        endtask

        function void report_phase(uvm_phase phase);
            `uvm_info("DRV_SUMMARY", $sformatf("requests=%0d misses=%0d responses=%0d vc_hits=%0d wb_hits=%0d",
                req_count, miss_count, rsp_count, vc_hit_count, wb_hit_count), UVM_LOW)
        endfunction
    endclass

    class memsys_obs extends uvm_object;
        `uvm_object_utils(memsys_obs)
        bit reset;
        bit load_valid;
        bit store_valid;
        bit rsp_valid;
        bit miss_valid;
        bit dcache_hit;
        bit vc_hit;
        bit wb_hit;
        bit miss_queue_full;
        bit wb_full;
        bit can_load;
        bit can_store;
        bit [1:0] mshr_cmd;
        bit [1:0] wb_cmd;
        // Response payload — enables scoreboard to check data-path invariants.
        DATA    rsp_data;
        LQ_IDX  rsp_lq_index;
        // Memory command addresses — used to verify alignment invariants.
        ADDR    mshr_addr;
        ADDR    wb_addr;
        function new(string name = "memsys_obs");
            super.new(name);
        endfunction
    endclass

    class memsys_monitor extends uvm_component;
        `uvm_component_utils(memsys_monitor)
        virtual memsys_if vif;
        uvm_analysis_port #(memsys_obs) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual memsys_if)::get(this, "", "memsys_vif", vif))
                `uvm_fatal("NOVIF", "memsys_vif not found")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                memsys_obs obs;
                @(vif.mon_cb);
                obs = memsys_obs::type_id::create("obs");
                obs.reset = vif.mon_cb.reset;
                obs.load_valid = vif.mon_cb.load_req_pack.valid;
                obs.store_valid = vif.mon_cb.store_req_pack.valid;
                obs.rsp_valid = vif.mon_cb.cache_resp_data.valid;
                obs.miss_valid = vif.mon_cb.miss_request.valid;
                obs.dcache_hit = vif.mon_cb.dcache_hit;
                obs.vc_hit = vif.mon_cb.vc_hit;
                obs.wb_hit = vif.mon_cb.wb_hit;
                obs.miss_queue_full = vif.mon_cb.miss_queue_full;
                obs.wb_full = vif.mon_cb.wb_full;
                obs.can_load = vif.mon_cb.dcache_can_accept_load;
                obs.can_store = vif.mon_cb.dcache_can_accept_store;
                obs.mshr_cmd    = vif.mon_cb.mshr2mem_command;
                obs.wb_cmd      = vif.mon_cb.wb2mem_command;
                obs.rsp_data    = vif.mon_cb.cache_resp_data.data;
                obs.rsp_lq_index = vif.mon_cb.cache_resp_data.lq_index;
                obs.mshr_addr   = vif.mon_cb.mshr2mem_addr;
                obs.wb_addr     = vif.mon_cb.wb2mem_addr;
                ap.write(obs);
            end
        endtask
    endclass

    class memsys_scoreboard extends uvm_component;
        `uvm_component_utils(memsys_scoreboard)
        uvm_analysis_imp #(memsys_obs, memsys_scoreboard) obs_imp;
        int unsigned true_misses, dcache_hits, vc_hits, wb_hits, mshr_full_cycles, wb_full_cycles;
        int unsigned wb_stores, mshr_loads, responses;

        covergroup cg;
            option.per_instance = 1;
            cp_access: coverpoint {last_obs.load_valid, last_obs.store_valid} {
                bins idle  = {2'b00};
                bins load  = {2'b10};
                bins store = {2'b01};
            }
            cp_hit_kind: coverpoint {last_obs.dcache_hit, last_obs.vc_hit, last_obs.wb_hit} {
                bins dcache       = {3'b100};
                bins victim       = {3'b010};
                bins write_buffer = {3'b001};
                bins true_miss    = {3'b000};
            }
            // Meaningful backpressure states instead of raw 4-bit explosion.
            cp_backpressure: coverpoint {last_obs.miss_queue_full, last_obs.wb_full} {
                bins neither      = {2'b00};
                bins mshr_full    = {2'b10};
                bins wb_full_only = {2'b01};
                bins both_full    = {2'b11};
            }
            cp_can_accept: coverpoint {last_obs.can_load, last_obs.can_store} {
                bins both_accept  = {2'b11};
                bins load_only    = {2'b10};
                bins neither      = {2'b00};
                // can_store && !can_load is illegal (caught by scoreboard assertion)
            }
            cp_mem_cmd: coverpoint last_obs.mshr_cmd {
                bins no_cmd   = {2'h0};
                bins mem_load = {2'h1};
            }
            cp_wb_cmd: coverpoint last_obs.wb_cmd {
                bins no_cmd    = {2'h0};
                bins mem_store = {2'h2};
            }
            // Cross: which hit type occurs under each access kind.
            cx_access_hit: cross cp_access, cp_hit_kind {
                // Stores cannot produce a dcache/vc/wb load-hit response in the same cycle.
                ignore_bins store_load_hit = binsof(cp_access.store) &&
                                             (binsof(cp_hit_kind.dcache) ||
                                              binsof(cp_hit_kind.victim) ||
                                              binsof(cp_hit_kind.write_buffer));
            }
        endgroup

        memsys_obs last_obs;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            obs_imp = new("obs_imp", this);
            last_obs = new("last_obs");
            cg = new();
        endfunction

        function void write(memsys_obs obs);
            last_obs = obs;
            if (obs.reset) return;
            cg.sample();

            if (obs.miss_valid && !obs.dcache_hit && !obs.vc_hit && !obs.wb_hit) true_misses++;
            if (obs.dcache_hit) dcache_hits++;
            if (obs.vc_hit) vc_hits++;
            if (obs.wb_hit) wb_hits++;
            if (obs.miss_queue_full) mshr_full_cycles++;
            if (obs.wb_full) wb_full_cycles++;
            if (obs.wb_cmd == 2'h2) wb_stores++;
            if (obs.mshr_cmd == 2'h1) mshr_loads++;
            if (obs.rsp_valid) responses++;

            if (obs.miss_valid && (obs.dcache_hit || obs.vc_hit || obs.wb_hit))
                `uvm_error("INV", "miss_request.valid asserted while a cache-side hit was reported")
            if (obs.can_store && !obs.can_load)
                `uvm_error("INV", "store accept high while load accept low")
            // MSHR and WB must only issue block-aligned addresses.
            if (obs.mshr_cmd == 2'h1 &&
                obs.mshr_addr[`DCACHE_OFFSET_BITS-1:0] !== '0)
                `uvm_error("INV", $sformatf("MSHR MEM_LOAD address not block-aligned: %08x", obs.mshr_addr))
            if (obs.wb_cmd == 2'h2 &&
                obs.wb_addr[`DCACHE_OFFSET_BITS-1:0] !== '0)
                `uvm_error("INV", $sformatf("WB MEM_STORE address not block-aligned: %08x", obs.wb_addr))
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCOREBOARD", $sformatf(
                "responses=%0d true_misses=%0d dcache_hits=%0d vc_hits=%0d wb_hits=%0d mshr_loads=%0d wb_stores=%0d mshr_full_cycles=%0d wb_full_cycles=%0d",
                responses, true_misses, dcache_hits, vc_hits, wb_hits, mshr_loads, wb_stores,
                mshr_full_cycles, wb_full_cycles), UVM_LOW)
            if (true_misses == 0) `uvm_error("COVER", "no true dcache misses observed")
            if (dcache_hits == 0) `uvm_error("COVER", "no dcache hits observed")
            if (vc_hits == 0) `uvm_error("COVER", "no victim-cache hits observed")
            if (wb_hits == 0) `uvm_error("COVER", "no write-buffer hits observed")
            if (mshr_full_cycles == 0 && wb_full_cycles == 0) `uvm_error("COVER", "no full/backpressure cycles observed")
            if (wb_stores == 0) `uvm_error("COVER", "write buffer never issued MEM_STORE")
        endfunction
    endclass

    class memsys_agent extends uvm_agent;
        `uvm_component_utils(memsys_agent)
        uvm_sequencer #(memsys_seq_item) seqr;
        memsys_driver drv;
        memsys_monitor mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr = uvm_sequencer #(memsys_seq_item)::type_id::create("seqr", this);
            drv = memsys_driver::type_id::create("drv", this);
            mon = memsys_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    class memsys_env extends uvm_env;
        `uvm_component_utils(memsys_env)
        memsys_agent agent;
        memsys_scoreboard sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = memsys_agent::type_id::create("agent", this);
            sb = memsys_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(sb.obs_imp);
        endfunction
    endclass

    class memsys_directed_test extends uvm_test;
        `uvm_component_utils(memsys_directed_test)
        memsys_env env;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = memsys_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            memsys_directed_seq seq;
            phase.raise_objection(this);
            seq = memsys_directed_seq::type_id::create("seq");
            seq.start(env.agent.seqr);
            repeat (20) @(env.agent.drv.vif.drv_cb);
            phase.drop_objection(this);
        endtask
        function void report_phase(uvm_phase phase);
            if (uvm_report_server::get_server().get_severity_count(UVM_ERROR) == 0 &&
                uvm_report_server::get_server().get_severity_count(UVM_FATAL) == 0)
                $display("@@@ Passed");
            else
                $display("@@@ Failed");
        endfunction
    endclass

    class memsys_smoke_test extends memsys_directed_test;
        `uvm_component_utils(memsys_smoke_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_phase(uvm_phase phase);
            memsys_smoke_seq seq;
            phase.raise_objection(this);
            seq = memsys_smoke_seq::type_id::create("seq");
            seq.start(env.agent.seqr);
            repeat (50) @(env.agent.drv.vif.drv_cb);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
`endif
