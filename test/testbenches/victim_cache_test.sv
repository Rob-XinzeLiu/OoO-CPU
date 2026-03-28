`timescale 1ns/1ps
`include "sys_defs.svh"

module victim_cache_tb;

    // ----------------------------
    // Clock / reset
    // ----------------------------
    logic clock;
    logic reset;

    initial begin
        clock = 0;
        forever #5 clock = ~clock;
    end

    // ----------------------------
    // DUT inputs
    // ----------------------------
    logic                        dcache_miss_req_valid;
    logic                        req_is_load;
    logic [`DCACHE_TAG_BITS-1:0] dcache_miss_req_tag;
    logic [`DCACHE_SET_BITS-1:0] dcache_miss_req_set;

    logic [$clog2(`DCACHE_LINE_BYTES)-1:0] vc_store_offset;
    MEM_SIZE                     vc_store_size;
    DATA                         vc_store_data;

    logic                        dcache_evicted_valid;
    logic [`DCACHE_TAG_BITS-1:0] dcache_evicted_tag;
    logic [`DCACHE_SET_BITS-1:0] dcache_evicted_set;
    MEM_BLOCK                    dcache_evicted_data;
    logic                        dcache_evicted_dirty;

    // ----------------------------
    // DUT outputs
    // ----------------------------
    logic                        vc_hit;
    MEM_BLOCK                    vc_hit_data;
    logic                        vc_hit_dirty;
    logic                        vc_store_ready;
    logic                        dcache_evicted_ready;

    MEM_COMMAND                  vc2mem_command;
    ADDR                         vc2mem_addr;
    MEM_BLOCK                    vc2mem_data;
    MEM_SIZE                     vc2mem_size;

    // ----------------------------
    // DUT
    // ----------------------------
    victim_cache #(
        .VC_LINES(4),
        .LINE_BYTES(`DCACHE_LINE_BYTES)
    ) dut (
        .clock(clock),
        .reset(reset),

        .dcache_miss_req_valid(dcache_miss_req_valid),
        .req_is_load(req_is_load),
        .dcache_miss_req_tag(dcache_miss_req_tag),
        .dcache_miss_req_set(dcache_miss_req_set),
        .vc_hit(vc_hit),
        .vc_hit_data(vc_hit_data),
        .vc_hit_dirty(vc_hit_dirty),

        .vc_store_offset(vc_store_offset),
        .vc_store_size(vc_store_size),
        .vc_store_data(vc_store_data),
        .vc_store_ready(vc_store_ready),

        .dcache_evicted_valid(dcache_evicted_valid),
        .dcache_evicted_tag(dcache_evicted_tag),
        .dcache_evicted_set(dcache_evicted_set),
        .dcache_evicted_data(dcache_evicted_data),
        .dcache_evicted_dirty(dcache_evicted_dirty),
        .dcache_evicted_ready(dcache_evicted_ready),

        .vc2mem_command(vc2mem_command),
        .vc2mem_addr(vc2mem_addr),
        .vc2mem_data(vc2mem_data),
        .vc2mem_size(vc2mem_size)
    );

    // ----------------------------
    // Helpers
    // ----------------------------
    task tick;
        begin
            @(posedge clock);
            #1;
        end
    endtask

    task clear_inputs;
        begin
            dcache_miss_req_valid = 0;
            req_is_load           = 1;
            dcache_miss_req_tag   = '0;
            dcache_miss_req_set   = '0;

            vc_store_offset       = '0;
            vc_store_size         = BYTE;
            vc_store_data         = '0;

            dcache_evicted_valid  = 0;
            dcache_evicted_tag    = '0;
            dcache_evicted_set    = '0;
            dcache_evicted_data   = '0;
            dcache_evicted_dirty  = 0;
        end
    endtask

    function automatic MEM_BLOCK make_block(input DATA low_word, input DATA high_word);
        MEM_BLOCK blk;
        begin
            blk = '0;
            blk.word_level[0] = low_word;
            blk.word_level[1] = high_word;
            make_block = blk;
        end
    endfunction

    function automatic ADDR make_line_addr(
        input logic [`DCACHE_TAG_BITS-1:0] tag,
        input logic [`DCACHE_SET_BITS-1:0] set
    );
        begin
            make_line_addr = {tag, set, {$clog2(`DCACHE_LINE_BYTES){1'b0}}};
        end
    endfunction

    task expect_true(input logic cond, input string msg);
        begin
            if (!cond) begin
                $display("FAIL: %s", msg);
                $finish;
            end else begin
                $display("PASS: %s", msg);
            end
        end
    endtask

    task expect_false(input logic cond, input string msg);
        begin
            if (cond) begin
                $display("FAIL: %s", msg);
                $finish;
            end else begin
                $display("PASS: %s", msg);
            end
        end
    endtask

    task expect_equal_32(input DATA got, input DATA exp, input string msg);
        begin
            if (got !== exp) begin
                $display("FAIL: %s | got=0x%08x expected=0x%08x", msg, got, exp);
                $finish;
            end else begin
                $display("PASS: %s | value=0x%08x", msg, got);
            end
        end
    endtask

    task expect_equal_16(input logic [15:0] got, input logic [15:0] exp, input string msg);
        begin
            if (got !== exp) begin
                $display("FAIL: %s | got=0x%04x expected=0x%04x", msg, got, exp);
                $finish;
            end else begin
                $display("PASS: %s | value=0x%04x", msg, got);
            end
        end
    endtask

    task expect_equal_8(input logic [7:0] got, input logic [7:0] exp, input string msg);
        begin
            if (got !== exp) begin
                $display("FAIL: %s | got=0x%02x expected=0x%02x", msg, got, exp);
                $finish;
            end else begin
                $display("PASS: %s | value=0x%02x", msg, got);
            end
        end
    endtask

    task expect_equal_addr(input ADDR got, input ADDR exp, input string msg);
        begin
            if (got !== exp) begin
                $display("FAIL: %s | got=0x%h expected=0x%h", msg, got, exp);
                $finish;
            end else begin
                $display("PASS: %s | value=0x%h", msg, got);
            end
        end
    endtask

    task expect_mem_none(input string msg);
        begin
            if (vc2mem_command !== MEM_NONE) begin
                $display("FAIL: %s | vc2mem_command expected MEM_NONE", msg);
                $finish;
            end else begin
                $display("PASS: %s", msg);
            end
        end
    endtask

    task expect_mem_store(input string msg);
        begin
            if (vc2mem_command !== MEM_STORE) begin
                $display("FAIL: %s | vc2mem_command expected MEM_STORE", msg);
                $finish;
            end else begin
                $display("PASS: %s", msg);
            end
        end
    endtask

    // ----------------------------
    // Test sequence
    // ----------------------------
    initial begin
        clear_inputs();

        // reset
        reset = 1;
        tick();
        tick();
        reset = 0;
        tick();

        // =========================================================
        // TEST 1: Insert one clean line into VC
        // =========================================================
        $display("\n===== TEST 1: INSERT ONE CLEAN LINE =====");

        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h12;
        dcache_evicted_set   = 'h3;
        dcache_evicted_data  = make_block(32'h1111_2222, 32'h3333_4444);
        dcache_evicted_dirty = 0;

        #1;
        expect_true(dcache_evicted_ready, "VC accepts first clean line");
        expect_mem_none("No memory write on simple clean insert");

        tick();
        clear_inputs();
        tick();

        // =========================================================
        // TEST 2: Load lookup should hit
        // =========================================================
        $display("\n===== TEST 2: LOAD LOOKUP HIT =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h12;
        dcache_miss_req_set   = 'h3;

        #1;
        expect_true(vc_hit, "VC load lookup hit");
        expect_true(!vc_hit_dirty, "VC line is still clean");
        expect_equal_32(vc_hit_data.word_level[0], 32'h1111_2222, "VC returned correct lower word");
        expect_equal_32(vc_hit_data.word_level[1], 32'h3333_4444, "VC returned correct upper word");
        expect_mem_none("Load hit does not write to memory");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3: Store hit in VC (update lower word)
        // =========================================================
        $display("\n===== TEST 3: STORE HIT IN VC =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 0;
        dcache_miss_req_tag   = 'h12;
        dcache_miss_req_set   = 'h3;
        vc_store_offset       = 3'b000;
        vc_store_size         = WORD;
        vc_store_data         = 32'hDEAD_BEEF;

        #1;
        expect_true(vc_hit, "VC store lookup hit");
        expect_true(vc_store_ready, "VC ready to perform store hit");
        expect_mem_none("Store hit in VC does not write to memory immediately");

        tick();
        clear_inputs();
        tick();

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h12;
        dcache_miss_req_set   = 'h3;

        #1;
        expect_true(vc_hit, "VC still hits after store");
        expect_true(vc_hit_dirty, "VC line is dirty after store");
        expect_equal_32(vc_hit_data.word_level[0], 32'hDEAD_BEEF, "Store updated lower word");
        expect_equal_32(vc_hit_data.word_level[1], 32'h3333_4444, "Upper word stayed the same");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3B: MISS CASE
        // =========================================================
        $display("\n===== TEST 3B: MISS CASE =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h55;
        dcache_miss_req_set   = 'h6;

        #1;
        expect_false(vc_hit, "VC miss lookup does not hit");
        expect_false(vc_store_ready, "VC store ready stays low on load miss");
        expect_mem_none("Miss lookup does not write to memory");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3C: INSERT A NEW LINE FOR SIZE-STORE TESTING
        // =========================================================
        $display("\n===== TEST 3C: INSERT STORE-SIZE TEST LINE =====");

        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h13;
        dcache_evicted_set   = 'h2;
        dcache_evicted_data  = make_block(32'h1122_3344, 32'h5566_7788);
        dcache_evicted_dirty = 0;

        tick();
        clear_inputs();
        tick();

        // =========================================================
        // TEST 3D: BYTE STORE HIT
        // offset 3'b101 => byte_level[5]
        // =========================================================
        $display("\n===== TEST 3D: BYTE STORE HIT =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 0;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;
        vc_store_offset       = 3'b101;
        vc_store_size         = BYTE;
        vc_store_data         = 32'h0000_00AB;

        #1;
        expect_true(vc_hit, "VC byte-store lookup hit");
        expect_true(vc_store_ready, "VC accepts byte store hit");

        tick();
        clear_inputs();
        tick();

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;

        #1;
        expect_true(vc_hit, "VC still hits after byte store");
        expect_true(vc_hit_dirty, "Byte store marks line dirty");
        expect_equal_8(vc_hit_data.byte_level[5], 8'hAB, "Byte store updated selected byte");
        expect_equal_8(vc_hit_data.byte_level[4], 8'h88, "Neighbor byte below unchanged");
        expect_equal_8(vc_hit_data.byte_level[6], 8'h66, "Neighbor byte above unchanged");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3E: HALF STORE HIT
        // offset 3'b010 => half_level[1]
        // =========================================================
        $display("\n===== TEST 3E: HALF STORE HIT =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 0;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;
        vc_store_offset       = 3'b010;
        vc_store_size         = HALF;
        vc_store_data         = 32'h0000_CDEF;

        #1;
        expect_true(vc_hit, "VC half-store lookup hit");
        expect_true(vc_store_ready, "VC accepts half store hit");

        tick();
        clear_inputs();
        tick();

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;

        #1;
        expect_true(vc_hit, "VC still hits after half store");
        expect_equal_16(vc_hit_data.half_level[1], 16'hCDEF, "Half store updated selected half");
        expect_equal_16(vc_hit_data.half_level[0], 16'h3344, "Other lower half unchanged");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3F: UPPER WORD STORE HIT
        // offset 3'b100 => word_level[1]
        // =========================================================
        $display("\n===== TEST 3F: UPPER WORD STORE HIT =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 0;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;
        vc_store_offset       = 3'b100;
        vc_store_size         = WORD;
        vc_store_data         = 32'hA5A5_5A5A;

        #1;
        expect_true(vc_hit, "VC upper-word store lookup hit");
        expect_true(vc_store_ready, "VC accepts upper-word store hit");

        tick();
        clear_inputs();
        tick();

        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h13;
        dcache_miss_req_set   = 'h2;

        #1;
        expect_true(vc_hit, "VC still hits after upper-word store");
        expect_equal_32(vc_hit_data.word_level[1], 32'hA5A5_5A5A, "Upper word store updated word_level[1]");
        expect_equal_16(vc_hit_data.half_level[1], 16'hCDEF, "Earlier half-store data still preserved");
        expect_equal_16(vc_hit_data.half_level[0], 16'h3344, "Untouched half still preserved");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 3G: STORE MISS SHOULD NOT UPDATE ANYTHING
        // =========================================================
        $display("\n===== TEST 3G: STORE MISS =====");

        dcache_miss_req_valid = 1;
        req_is_load           = 0;
        dcache_miss_req_tag   = 'h66;
        dcache_miss_req_set   = 'h7;
        vc_store_offset       = 3'b000;
        vc_store_size         = WORD;
        vc_store_data         = 32'h1234_5678;

        #1;
        expect_false(vc_hit, "Store miss does not hit VC");
        expect_false(vc_store_ready, "Store miss does not assert vc_store_ready");
        expect_mem_none("Store miss does not generate memory write");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 4: Fill VC completely
        // =========================================================
        $display("\n===== TEST 4: FILL VC COMPLETELY =====");

        // line 3
        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h20;
        dcache_evicted_set   = 'h1;
        dcache_evicted_data  = make_block(32'hAAAA_0001, 32'hBBBB_0001);
        dcache_evicted_dirty = 0;
        tick();

        // line 4
        dcache_evicted_tag   = 'h21;
        dcache_evicted_set   = 'h1;
        dcache_evicted_data  = make_block(32'hAAAA_0002, 32'hBBBB_0002);
        tick();

        clear_inputs();
        tick();

        // =========================================================
        // TEST 5: Insert one more line, causing dirty VC eviction
        // Now check direct memory outputs instead of wb_req
        // =========================================================
        $display("\n===== TEST 5: DIRTY VC EVICTION TO MEMORY =====");

        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h30;
        dcache_evicted_set   = 'h2;
        dcache_evicted_data  = make_block(32'h9999_0001, 32'h9999_0002);
        dcache_evicted_dirty = 0;

        #1;
        expect_false(dcache_evicted_ready, "Dirty VC victim blocks overwrite until writeback is handled");
        expect_mem_store("Dirty VC victim generates memory store");
        expect_equal_addr(vc2mem_addr, make_line_addr('h12, 'h3), "VC writes back correct dirty victim address");
        expect_equal_32(vc2mem_data.word_level[0], 32'hDEAD_BEEF, "VC writes back correct lower word");
        expect_equal_32(vc2mem_data.word_level[1], 32'h3333_4444, "VC writes back correct upper word");
        expect_true(vc2mem_size == DOUBLE, "VC writes back full cache line");

        clear_inputs();
        tick();

        // =========================================================
        // TEST 6: LRU REPLACEMENT CHECK
        // Fill fresh VC with A,B,C,D
        // Touch A, then B, then C
        // D should become LRU and get evicted by E
        // =========================================================
        $display("\n===== TEST 6: LRU REPLACEMENT CHECK =====");

        clear_inputs();
        reset = 1;
        tick();
        tick();
        reset = 0;
        tick();

        // Insert A
        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h40;
        dcache_evicted_set   = 'h0;
        dcache_evicted_data  = make_block(32'hAAAA_AAAA, 32'hAAAA_BBBB);
        dcache_evicted_dirty = 0;
        tick();

        // Insert B
        dcache_evicted_tag   = 'h41;
        dcache_evicted_set   = 'h0;
        dcache_evicted_data  = make_block(32'hBBBB_AAAA, 32'hBBBB_BBBB);
        tick();

        // Insert C
        dcache_evicted_tag   = 'h42;
        dcache_evicted_set   = 'h0;
        dcache_evicted_data  = make_block(32'hCCCC_AAAA, 32'hCCCC_BBBB);
        tick();

        // Insert D
        dcache_evicted_tag   = 'h43;
        dcache_evicted_set   = 'h0;
        dcache_evicted_data  = make_block(32'hDDDD_AAAA, 32'hDDDD_BBBB);
        tick();

        clear_inputs();
        tick();

        // Touch A
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h40;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "LRU setup: A hit");
        tick();
        clear_inputs();
        tick();

        // Touch B
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h41;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "LRU setup: B hit");
        tick();
        clear_inputs();
        tick();

        // Touch C
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h42;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "LRU setup: C hit");
        tick();
        clear_inputs();
        tick();

        // Insert E -> should evict D if LRU works
        dcache_evicted_valid = 1;
        dcache_evicted_tag   = 'h44;
        dcache_evicted_set   = 'h0;
        dcache_evicted_data  = make_block(32'hEEEE_AAAA, 32'hEEEE_BBBB);
        dcache_evicted_dirty = 0;

        #1;
        expect_true(dcache_evicted_ready, "LRU test insert is accepted");
        expect_mem_none("LRU test uses clean victim, so no memory write");
        tick();
        clear_inputs();
        tick();

        // D should be gone
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h43;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_false(vc_hit, "LRU evicted D");
        clear_inputs();
        tick();

        // A still present
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h40;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "A still present after LRU replacement");
        clear_inputs();
        tick();

        // B still present
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h41;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "B still present after LRU replacement");
        clear_inputs();
        tick();

        // C still present
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h42;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "C still present after LRU replacement");
        clear_inputs();
        tick();

        // E inserted successfully
        dcache_miss_req_valid = 1;
        req_is_load           = 1;
        dcache_miss_req_tag   = 'h44;
        dcache_miss_req_set   = 'h0;
        #1;
        expect_true(vc_hit, "E inserted successfully as new MRU");
        clear_inputs();
        tick();

        $display("\n===== ALL VC TESTS PASSED =====");
        $finish;
    end

endmodule