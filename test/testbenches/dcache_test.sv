`timescale 1ns/1ps
`include "sys_defs.svh"
`include "ISA.svh"

module testbench;

    localparam int WAYS  = 4;
    localparam int SETS  = 8;
    localparam int LINES = WAYS * SETS;

    logic            clock, reset;

    LQ_PACKET        load_req_pack;
    SQ_PACKET        store_req_pack;

    completed_mshr_t com_miss_req;
    logic            miss_returned;
    logic            miss_queue_full;

    dcache_data_t    cache_resp_data;
    miss_request_t   miss_request;

    MEM_COMMAND      vc2mem_command;
    ADDR             vc2mem_addr;
    MEM_BLOCK        vc2mem_data;
    MEM_SIZE         vc2mem_size;

    logic            dcache_can_accept_store;
    logic            dcache_can_accept_load;

    bit test_failed = 0;

    Dcache #(
        .WAYS(WAYS),
        .SETS(SETS)
    ) dut (
        .clock(clock),
        .reset(reset),

        .load_req_pack(load_req_pack),
        .store_req_pack(store_req_pack),

        .com_miss_req(com_miss_req),
        .miss_returned(miss_returned),
        .miss_queue_full(miss_queue_full),

        .cache_resp_data(cache_resp_data),
        .miss_request(miss_request),

        .vc2mem_command(vc2mem_command),
        .vc2mem_addr(vc2mem_addr),
        .vc2mem_data(vc2mem_data),
        .vc2mem_size(vc2mem_size),

        .dcache_can_accept_store(dcache_can_accept_store),
        .dcache_can_accept_load(dcache_can_accept_load)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    task reset_dut();
        begin
            clock = 0;
            reset = 1;

            load_req_pack   = '0;
            store_req_pack  = '0;
            com_miss_req    = '0;
            miss_returned   = 1'b0;
            miss_queue_full = 1'b0;

            @(negedge clock);
            reset = 0;
            @(negedge clock);

            $display(">>> System Reset Done.");
        end
    endtask

    task send_load(
        input ADDR     addr,
        input MEM_SIZE size,
        input logic    unsigned_load,
        input logic [$bits(load_req_pack.lq_index)-1:0] lq_idx
    );
        begin
            load_req_pack              = '0;
            store_req_pack             = '0;
            load_req_pack.valid        = 1'b1;
            load_req_pack.addr         = addr;
            load_req_pack.funct3       = {unsigned_load, size};
            load_req_pack.lq_index     = lq_idx;
        end
    endtask

    task send_store(
        input ADDR     addr,
        input MEM_SIZE size,
        input DATA     data
    );
        begin
            load_req_pack              = '0;
            store_req_pack             = '0;
            store_req_pack.valid       = 1'b1;
            store_req_pack.addr        = addr;
            store_req_pack.funct3      = {1'b0, size};
            store_req_pack.data        = data;
        end
    endtask

    task clear_req();
        begin
            load_req_pack  = '0;
            store_req_pack = '0;
        end
    endtask

    task return_miss(
        input ADDR      addr,
        input logic     req_is_load,
        input MEM_SIZE  size,
        input logic     unsigned_load,
        input DATA      req_data,
        input logic [$bits(load_req_pack.lq_index)-1:0] lq_idx,
        input MEM_BLOCK refill_block
    );
        begin
            com_miss_req                       = '0;
            com_miss_req.valid                 = 1'b1;
            com_miss_req.miss_req_address      = addr;
            com_miss_req.miss_req_tag          = addr[31:6];
            com_miss_req.miss_req_set          = addr[5:3];
            com_miss_req.miss_req_offset       = addr[2:0];
            com_miss_req.req_is_load           = req_is_load;
            com_miss_req.miss_req_size         = size;
            com_miss_req.miss_req_unsigned     = unsigned_load;
            com_miss_req.miss_req_data         = req_data;
            com_miss_req.lq_index              = lq_idx;
            com_miss_req.refill_data           = refill_block;
            miss_returned                      = 1'b1;
        end
    endtask

    task clear_return();
        begin
            com_miss_req  = '0;
            miss_returned = 1'b0;
        end
    endtask

    task dump_cache_set(input logic [2:0] set_idx);
        begin
            $display("---- CACHE TAG DUMP SET %0d @ %0t ----", set_idx, $time);
            for (int i = 0; i < WAYS; i++) begin
                $display("way=%0d valid=%0b dirty=%0b tag=0x%0h lru=%0d",
                    i,
                    dut.cache_tags[set_idx][i].valid,
                    dut.cache_tags[set_idx][i].dirty,
                    dut.cache_tags[set_idx][i].tag,
                    dut.cache_tags[set_idx][i].lru_val
                );
            end
            $display("--------------------------------------");
        end
    endtask

    initial begin
        reset_dut();

        // ------------------------------------------------------------
        // Case 1: Refill a load miss into empty cache
        // ------------------------------------------------------------
        $display("\nCase 1: Return one load miss into empty cache");

        return_miss(
            32'h0000_0040,   // addr
            1'b1,            // req_is_load
            WORD,            // size
            1'b0,            // unsigned
            '0,              // req_data
            6'd3,            // lq index
            64'h1122_3344_AABB_CCDD
        );
        #1;

        assert(dut.data_we == 1'b1) else begin
            $error("Case 1 Fail: Expected refill write enable.");
            test_failed = 1;
        end

        assert(dut.data_waddr == dut.flat_idx(3'b000, 0) ||
            dut.data_waddr == dut.flat_idx(3'b000, 1) ||
            dut.data_waddr == dut.flat_idx(3'b000, 2) ||
            dut.data_waddr == dut.flat_idx(3'b000, 3)) else begin
            $error("Case 1 Fail: Refill did not target a way in correct set.");
            test_failed = 1;
        end

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 6'd3 &&
               cache_resp_data.data == 32'hAABB_CCDD) else begin
            $error("Case 1 Fail: Load refill response incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_return();
        @(negedge clock);

        dump_cache_set(3'b000);

        // ------------------------------------------------------------
        // Case 2: Hit on the refilled line
        // ------------------------------------------------------------
        $display("\nCase 2: Load hit on resident line");

        send_load(32'h0000_0040, WORD, 1'b0, 2'd3);
        #1;
        $display("DEBUG Case2 @ %0t:", $time);
        $display("  load_valid        = %0b", load_req_pack.valid);
        $display("  load_addr         = 0x%08h", load_req_pack.addr);

        $display("  curr_req_addr     = 0x%08h", dut.curr_req_addr);
        $display("  req_valid         = %0b", dut.req_valid);
        $display("  cache_ready       = %0b", dut.cache_ready);

        $display("  d_request_set     = %0d", dut.d_request_set);
        $display("  d_request_tag     = 0x%0h", dut.d_request_tag);
        $display("  d_request_offset  = %0d", dut.d_request_offset);

        for (int i = 0; i < 4; i++) begin
            $display("  WAY %0d: valid=%0b tag=0x%0h lru=%0d",
                i,
                dut.cache_tags[dut.d_request_set][i].valid,
                dut.cache_tags[dut.d_request_set][i].tag,
                dut.cache_tags[dut.d_request_set][i].lru_val
            );
        end

        $display("  hit               = %0b", dut.hit);
        $display("  hit_way           = %0d", dut.hit_way);

        $display("  data_re           = %0b", dut.data_re[0]);
        $display("  data_raddr        = %0d", dut.data_raddr[0]);
        $display("  data_rdata        = 0x%016h", dut.data_rdata[0]);

        $display("  selected_read     = 0x%016h", dut.selected_read_data);

        $display("  resp_valid        = %0b", cache_resp_data.valid);
        $display("  resp_data         = 0x%08h", cache_resp_data.data);

        $display("  resp_lq_index     = %0d", cache_resp_data.lq_index);
        $display("  load_lq_index     = %0d", load_req_pack.lq_index);

      

        assert(dut.hit == 1'b1) else begin
            $error("Case 2 Fail: Expected cache hit.");
            test_failed = 1;
        end

        // If this assert fails, it likely means the memDP read timing
        // and the Dcache same-cycle use of data_rdata need to be pipelined.
       assert(cache_resp_data.valid == 1'b1 &&
            cache_resp_data.lq_index == 2'd3 &&
            cache_resp_data.data == 32'hAABB_CCDD) else begin
            $error("Case 2 Fail: Hit response incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 3: Miss request generated for absent line
        // ------------------------------------------------------------
        $display("\nCase 3: Load miss generates miss_request");

        send_load(32'h0000_0080, WORD, 1'b0, 2'd3);
        @(posedge clock);
        #1;

        assert(miss_request.valid == 1'b1) else begin
            $error("Case 3 Fail: miss_request.valid not asserted.");
            test_failed = 1;
        end

        assert(miss_request.miss_req_address == 32'h0000_0080 &&
            miss_request.req_is_load == 1'b1 &&
            miss_request.miss_req_size == WORD &&
            miss_request.lq_index == 2'd3) else begin
            $error("Case 3 Fail: miss_request contents incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 4: Hit-under-miss (non-blocking behavior)
        // ------------------------------------------------------------
        $display("\nCase 4: Hit-under-miss should still succeed");

        // First create an outstanding miss request
        send_load(32'h0000_00C0, WORD, 1'b0, 2'd0);
        @(posedge clock);
        #1;

        assert(miss_request.valid == 1'b1 &&
            miss_request.miss_req_address == 32'h0000_00C0 &&
            miss_request.lq_index == 2'd0) else begin
            $error("Case 4 Fail: Initial miss request not generated.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();

        // While that miss is logically outstanding, hit old resident line
        send_load(32'h0000_0040, WORD, 1'b0, 2'd1);
        #1;

        assert(dut.hit == 1'b1) else begin
            $error("Case 4 Fail: Expected hit-under-miss.");
            test_failed = 1;
        end

        assert(cache_resp_data.valid == 1'b1 &&
            cache_resp_data.lq_index == 2'd1 &&
            cache_resp_data.data == 32'hAABB_CCDD) else begin
            $error("Case 4 Fail: Cache behaved blocking on hit-under-miss.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

                // ------------------------------------------------------------
        // Case 5: Store hit updates resident line
        // ------------------------------------------------------------
        $display("\nCase 5: Store hit merges data into cache line");

        send_store(32'h0000_0040, WORD, 32'hDEAD_BEEF);
        #1;

        assert(dut.hit == 1'b1) else begin
            $error("Case 5 Fail: Expected store hit.");
            test_failed = 1;
        end

        assert(dut.data_we == 1'b1) else begin
            $error("Case 5 Fail: Store hit did not write memDP.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

        send_load(32'h0000_0040, WORD, 1'b0, 2'd2);
        #1;

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 2'd2 &&
               cache_resp_data.data == 32'hDEAD_BEEF) else begin
            $error("Case 5 Fail: Store hit data not preserved.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 6: Store miss refill merges store payload into returned block
        // ------------------------------------------------------------
        $display("\nCase 6: Store miss merges store data into refill block");

        return_miss(
            32'h0000_0144,       // byte offset 4
            1'b0,                // store miss
            BYTE,
            1'b0,
            32'h0000_00AB,
            2'd0,
            64'h1111_2222_3333_4444
        );
        #1;

        assert(dut.data_we == 1'b1) else begin
            $error("Case 6 Fail: Store miss refill did not write cache.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_return();
        @(negedge clock);

        send_load(32'h0000_0144, BYTE, 1'b1, 2'd3);
        #1;

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 2'd3 &&
               cache_resp_data.data == 32'h0000_00AB) else begin
            $error("Case 6 Fail: Store miss merge result incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 7: miss_queue_full blocks new misses
        // ------------------------------------------------------------
        $display("\nCase 7: miss_queue_full blocks acceptance");

        miss_queue_full = 1'b1;
        send_load(32'h0000_0200, WORD, 1'b0, 2'd1);
        @(posedge clock);
        #1;

        assert(dcache_can_accept_load == 1'b0) else begin
            $error("Case 7 Fail: Load should not be accepted when miss queue full.");
            test_failed = 1;
        end

        assert(miss_request.valid == 1'b0) else begin
            $error("Case 7 Fail: Cache generated miss_request while queue full.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();
        miss_queue_full = 1'b0;
        @(negedge clock);

                // ------------------------------------------------------------
        // Case 8: One miss, then two hits, then miss refill
        // ------------------------------------------------------------
        $display("\nCase 8: One miss, two hits, then miss fills later");

        reset_dut();

        // Preload line at 0x40
        return_miss(
            32'h0000_0040,
            1'b1,
            WORD,
            1'b0,
            '0,
            2'd0,
            64'h1122_3344_AABB_CCDD
        );
        #1;
        @(negedge clock);
        clear_return();
        @(negedge clock);

        // Preload line at 0x48
        return_miss(
            32'h0000_0048,
            1'b1,
            WORD,
            1'b0,
            '0,
            2'd1,
            64'h5566_7788_DEAD_BEEF
        );
        #1;
        @(negedge clock);
        clear_return();
        @(negedge clock);

        // Step 1: issue miss to absent line 0x00C0
        send_load(32'h0000_00C0, WORD, 1'b0, 2'd2);
        @(posedge clock);
        #1;

        assert(miss_request.valid == 1'b1 &&
               miss_request.miss_req_address == 32'h0000_00C0 &&
               miss_request.lq_index == 2'd2) else begin
            $error("Case 8 Fail: Initial miss request not generated.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();

        // Step 2: first hit while miss is pending
        send_load(32'h0000_0040, WORD, 1'b0, 2'd0);
        #1;

        assert(dut.hit == 1'b1) else begin
            $error("Case 8 Fail: First hit-under-miss not detected.");
            test_failed = 1;
        end

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 2'd0 &&
               cache_resp_data.data == 32'hAABB_CCDD) else begin
            $error("Case 8 Fail: First hit-under-miss response incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();

        // Step 3: second hit while same miss is still pending
        send_load(32'h0000_0048, WORD, 1'b0, 2'd1);
        #1;

        assert(dut.hit == 1'b1) else begin
            $error("Case 8 Fail: Second hit-under-miss not detected.");
            test_failed = 1;
        end

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 2'd1 &&
               cache_resp_data.data == 32'hDEAD_BEEF) else begin
            $error("Case 8 Fail: Second hit-under-miss response incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_req();

        // Step 4: now finally return the pending miss
        return_miss(
            32'h0000_00C0,
            1'b1,
            WORD,
            1'b0,
            '0,
            2'd2,
            64'h9999_AAAA_BBBB_CCCC
        );
        #1;

        assert(cache_resp_data.valid == 1'b1 &&
               cache_resp_data.lq_index == 2'd2 &&
               cache_resp_data.data == 32'hBBBB_CCCC) else begin
            $error("Case 8 Fail: Miss refill response incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        clear_return();
        @(negedge clock);
        // ------------------------------------------------------------
        // Final Result
        // ------------------------------------------------------------
        #100;
        $display("\n############################################");
        if (test_failed == 0) begin
            $display("##           ALL TESTS PASSED!            ##");
        end else begin
            $display("##     VERIFICATION FAILED! BUGS FOUND    ##");
        end
        $display("############################################");
        $finish;
    end

endmodule