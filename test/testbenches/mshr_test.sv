`timescale 1ns/1ps
`include "sys_defs.svh"
`include "ISA.svh"

module testbench;

    localparam int ENTRIES = 8;

    logic            clock, reset;
    logic            grant;
    miss_request_t   dcache_miss_req;

    MEM_TAG          mem2proc_transaction_tag;
    MEM_TAG          mem2proc_data_tag;
    MEM_BLOCK        mem2proc_data;

    MEM_COMMAND      mshr2mem_command;
    ADDR             mshr2mem_addr;
    MEM_SIZE         mshr2mem_size;
    MEM_BLOCK        mshr2mem_data;
    completed_mshr_t com_miss_req;
    logic            miss_queue_full;
    logic            miss_returned;
    logic            mshr_wait_for_trans;
    logic            mshr_currently_waiting;

    bit test_failed = 0;

    mshr #(
        .ENTRIES(ENTRIES)
    ) dut (
        .clock(clock),
        .reset(reset),
        .grant(grant),
        .dcache_miss_req(dcache_miss_req),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .mem2proc_data_tag(mem2proc_data_tag),
        .mem2proc_data(mem2proc_data),
        .mshr2mem_command(mshr2mem_command),
        .mshr2mem_addr(mshr2mem_addr),
        .mshr2mem_size(mshr2mem_size),
        .mshr2mem_data(mshr2mem_data),
        .com_miss_req(com_miss_req),
        .miss_queue_full(miss_queue_full),
        .miss_returned(miss_returned),
        .mshr_wait_for_trans(mshr_wait_for_trans),
        .mshr_currently_waiting(mshr_currently_waiting)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    task reset_dut();
        begin
            clock                    = 0;
            reset                    = 1;
            grant                    = 1'b1;
            dcache_miss_req          = '0;
            mem2proc_transaction_tag = '0;
            mem2proc_data_tag        = '0;
            mem2proc_data            = '0;

            @(negedge clock);
            reset = 0;
            @(negedge clock);

            $display(">>> System Reset Done.");
        end
    endtask

    task send_miss(
        input ADDR     addr,
        input logic    req_is_load,
        input MEM_SIZE size,
        input logic    unsigned_load,
        input DATA     store_data,
        input logic [$bits(dcache_miss_req.lq_index)-1:0] lq_idx
    );
        begin
            dcache_miss_req.valid             = 1'b1;
            dcache_miss_req.miss_req_address  = addr;
            dcache_miss_req.miss_req_tag      = addr[31:6];
            dcache_miss_req.miss_req_set      = addr[5:3];
            dcache_miss_req.miss_req_offset   = addr[2:0];
            dcache_miss_req.req_is_load       = req_is_load;
            dcache_miss_req.miss_req_size     = size;
            dcache_miss_req.miss_req_unsigned = unsigned_load;
            dcache_miss_req.miss_req_data     = store_data;
            dcache_miss_req.lq_index          = lq_idx;
        end
    endtask

    task clear_miss();
        begin
            dcache_miss_req = '0;
        end
    endtask

    task dump_outstanding_table();
        begin
            $display("---- OUTSTANDING TABLE DUMP @ %0t ----", $time);
            for (int i = 0; i < ENTRIES; i++) begin
                $display("idx=%0d valid=%0b dep=%0b tag=%0d addr=0x%08h size=%0d load=%0b lq=%0d data=0x%08h",
                    i,
                    dut.outstanding_table[i].valid,
                    dut.outstanding_table[i].dep_miss,
                    dut.outstanding_table[i].trans_tag,
                    dut.outstanding_table[i].miss_req_address,
                    dut.outstanding_table[i].miss_req_size,
                    dut.outstanding_table[i].req_is_load,
                    dut.outstanding_table[i].lq_index,
                    dut.outstanding_table[i].miss_req_data
                );
            end
            $display("--------------------------------------");
        end
    endtask

    initial begin
        reset_dut();

        // ------------------------------------------------------------
        // Case 1: Enqueue one miss, then move to active request
        // ------------------------------------------------------------
        $display("\nCase 1: Enqueue one miss and move into active request");

        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0, 6'd3);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(dut.miss_count == 0 && dut.req_state == REQ_WAIT_ACCEPT) else begin
            $error("Case 1 Fail: Expected active request to be popped into REQ_WAIT_ACCEPT.");
            test_failed = 1;
        end

        assert(dut.active_req.miss_req_address == 32'h0000_0040) else begin
            $error("Case 1 Fail: active_req address incorrect.");
            test_failed = 1;
        end

        assert(dut.active_req.lq_index == 6'd3) else begin
            $error("Case 1 Fail: active_req lq_index incorrect.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 2: Memory accepts request, outstanding entry created
        // ------------------------------------------------------------
        $display("\nCase 2: Memory accepts request and creates outstanding entry");

        mem2proc_transaction_tag = 4'd3;
        grant = 1'b1;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(mshr2mem_command == MEM_NONE && dut.req_state == REQ_IDLE) else begin
            $error("Case 2 Fail: FSM did not return to REQ_IDLE after accept.");
            test_failed = 1;
        end

        assert(dut.outstanding_table[0].valid == 1'b1 &&
               dut.outstanding_table[0].dep_miss == 1'b0 &&
               dut.outstanding_table[0].trans_tag == 4'd3 &&
               dut.outstanding_table[0].miss_req_address == 32'h0000_0040 &&
               dut.outstanding_table[0].lq_index == 6'd3) else begin
            $error("Case 2 Fail: Outstanding entry not created correctly.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 3: Completion returns matching tag
        // ------------------------------------------------------------
        $display("\nCase 3: Return data and complete request");

        mem2proc_data_tag = 4'd3;
        mem2proc_data     = 64'h1111_1111_1111_1111;

        @(posedge clock);
        #1;

        assert(com_miss_req.valid == 1'b1) else begin
            $error("Case 3 Fail: com_miss_req.valid not asserted.");
            test_failed = 1;
        end

        assert(com_miss_req.dep_miss == 1'b0 &&
               com_miss_req.miss_req_address == 32'h0000_0040 &&
               com_miss_req.req_is_load == 1'b1 &&
               com_miss_req.miss_req_size == WORD &&
               com_miss_req.lq_index == 6'd3 &&
               com_miss_req.refill_data == 64'h1111_1111_1111_1111) else begin
            $error("Case 3 Fail: Completion packet incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        @(posedge clock);
        #1;

        assert(dut.outstanding_table[0].valid == 1'b0) else begin
            $error("Case 3 Fail: Outstanding entry was not cleared.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 4: Queue multiple misses and accept them on consecutive cycles
        // ------------------------------------------------------------
        $display("\nCase 4: Queue 3 misses and accept 3 tags");

        reset_dut();

        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0, 6'd0);
        @(negedge clock);
        send_miss(32'h0000_0080, 1'b1, WORD, 1'b0, '0, 6'd1);
        @(negedge clock);
        send_miss(32'h0000_00C0, 1'b1, WORD, 1'b0, '0, 6'd2);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0040) else begin
            $error("Case 4 Fail: First issue incorrect.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd1;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0080) else begin
            $error("Case 4 Fail: Second issue incorrect.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd2;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_00C0) else begin
            $error("Case 4 Fail: Third issue incorrect.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd4;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 5: grant must be high for acceptance
        // ------------------------------------------------------------
        $display("\nCase 5: Request waits when grant is low");

        reset_dut();

        send_miss(32'h0000_0180, 1'b1, WORD, 1'b0, '0, 6'd4);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0180) else begin
            $error("Case 5 Fail: Initial issue missing.");
            test_failed = 1;
        end

        grant = 1'b0;
        mem2proc_transaction_tag = 4'd5;
        @(negedge clock);

        assert(dut.req_state == REQ_WAIT_ACCEPT) else begin
            $error("Case 5 Fail: Request should still be waiting when grant is low.");
            test_failed = 1;
        end

        assert(dut.out_count == 0) else begin
            $error("Case 5 Fail: Outstanding entry created even though grant was low.");
            test_failed = 1;
        end

        grant = 1'b1;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(dut.out_count == 1) else begin
            $error("Case 5 Fail: Request not accepted after grant returned high.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 6: Retry when memory does not accept
        // ------------------------------------------------------------
        $display("\nCase 6: Retry while transaction tag is 0");

        reset_dut();

        send_miss(32'h0000_0100, 1'b1, WORD, 1'b0, '0, 6'd2);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0100) else begin
            $error("Case 6 Fail: Initial issue missing.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0100) else begin
            $error("Case 6 Fail: MSHR did not keep retrying.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd6;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(dut.outstanding_table[0].valid == 1'b1 ||
               dut.outstanding_table[1].valid == 1'b1) else begin
            $error("Case 6 Fail: Accepted request did not enter outstanding table.");
            test_failed = 1;
        end

               // ------------------------------------------------------------
        // Case 7: Store miss preserves store metadata
        // ------------------------------------------------------------
        $display("\nCase 7: Store miss metadata preserved");

        reset_dut();

        send_miss(32'h0000_0144, 1'b0, BYTE, 1'b0, 32'h0000_00AB, 6'd0);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0144) else begin
            $error("Case 7 Fail: Store miss did not issue MEM_LOAD.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd7;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        mem2proc_data_tag = 4'd7;
        mem2proc_data     = 64'hAAAA_BBBB_CCCC_DDDD;

        @(posedge clock);
        #1;

        assert(com_miss_req.valid == 1'b1 &&
               com_miss_req.dep_miss == 1'b0 &&
               com_miss_req.req_is_load == 1'b0 &&
               com_miss_req.miss_req_size == BYTE &&
               com_miss_req.miss_req_data == 32'h0000_00AB &&
               com_miss_req.refill_data == 64'hAAAA_BBBB_CCCC_DDDD) else begin
            $error("Case 7 Fail: Store miss completion metadata incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        @(posedge clock);
        #1;

        // ------------------------------------------------------------
        // Case 8: Dependent replay only after first request is already outstanding
        // ------------------------------------------------------------
        $display("\nCase 8: FIFO dependent replay for repeated block");

        reset_dut();

        // A primary miss
        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0, 6'd1);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0040) else begin
            $error("Case 8 Fail: First issue should be A.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd1;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        // B primary miss
        send_miss(32'h0000_0080, 1'b1, WORD, 1'b0, '0, 6'd2);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0080) else begin
            $error("Case 8 Fail: Second issue should be B.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd2;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        // Dependent A miss
        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0, 6'd3);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(!(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0040)) else begin
            $error("Case 8 Fail: Dependent A request incorrectly re-issued to memory.");
            test_failed = 1;
        end

        // Complete A primary
        mem2proc_data_tag = 4'd1;
        mem2proc_data     = 64'hAAAA_AAAA_AAAA_AAAA;
        #1;
        @(posedge clock);
        #1;

        assert(com_miss_req.valid == 1'b1 &&
               com_miss_req.dep_miss == 1'b0 &&
               com_miss_req.miss_req_address == 32'h0000_0040 &&
               com_miss_req.req_is_load == 1'b1 &&
               com_miss_req.miss_req_size == WORD &&
               com_miss_req.lq_index == 6'd1 &&
               com_miss_req.refill_data == 64'hAAAA_AAAA_AAAA_AAAA) else begin
            $error("Case 8 Fail: A primary completion packet incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        @(negedge clock);

        // Complete B primary
        mem2proc_data_tag = 4'd2;
        mem2proc_data     = 64'hBBBB_BBBB_BBBB_BBBB;
        #1;
         @(posedge clock);
        #1;
        assert(com_miss_req.valid == 1'b1 &&
               com_miss_req.dep_miss == 1'b0 &&
               com_miss_req.miss_req_address == 32'h0000_0080 &&
               com_miss_req.req_is_load == 1'b1 &&
               com_miss_req.miss_req_size == WORD &&
               com_miss_req.lq_index == 6'd2 &&
               com_miss_req.refill_data == 64'hBBBB_BBBB_BBBB_BBBB) else begin
            $error("Case 8 Fail: B primary completion packet incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        #1;
         @(posedge clock);
        #1;
        assert(com_miss_req.valid == 1'b1 &&
               com_miss_req.dep_miss == 1'b1 &&
               com_miss_req.miss_req_address == 32'h0000_0040 &&
               com_miss_req.req_is_load == 1'b1 &&
               com_miss_req.miss_req_size == WORD &&
               com_miss_req.lq_index == 6'd3 &&
               com_miss_req.refill_data == '0) else begin
            $error("Case 8 Fail: Dependent A replay packet incorrect.");
            test_failed = 1;
        end

        @(negedge clock);

          // ------------------------------------------------------------
        // Case 9: Back-to-back same-address miss, lq_index 3 then 0
        // ------------------------------------------------------------
        $display("\nCase 9: Same address miss with lq_index 3 then 0");

        reset_dut();

        // First miss
        send_miss(32'h0000_0200, 1'b1, WORD, 1'b0, '0, 6'd3);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD &&
               mshr2mem_addr    == 32'h0000_0200) else begin
            $error("Case 9 Fail: First miss did not issue correctly.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd5;
        grant = 1'b1;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(dut.outstanding_table[dut.out_head].valid == 1'b1 &&
               dut.outstanding_table[dut.out_head].dep_miss == 1'b0 &&
               dut.outstanding_table[dut.out_head].miss_req_address == 32'h0000_0200 &&
               dut.outstanding_table[dut.out_head].lq_index == 6'd3) else begin
            $error("Case 9 Fail: Primary miss not stored correctly.");
            test_failed = 1;
        end

        // Second same-address miss
        send_miss(32'h0000_0200, 1'b1, WORD, 1'b0, '0, 6'd0);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(!(mshr2mem_command == MEM_LOAD &&
                 mshr2mem_addr == 32'h0000_0200 &&
                 dut.req_state == REQ_WAIT_ACCEPT)) else begin
            $error("Case 9 Fail: Same-address dependent miss was reissued to memory.");
            test_failed = 1;
        end

        assert(dut.outstanding_table[(dut.out_head + 1) % ENTRIES].valid == 1'b1 &&
               dut.outstanding_table[(dut.out_head + 1) % ENTRIES].dep_miss == 1'b1 &&
               dut.outstanding_table[(dut.out_head + 1) % ENTRIES].miss_req_address == 32'h0000_0200 &&
               dut.outstanding_table[(dut.out_head + 1) % ENTRIES].lq_index == 6'd0) else begin
            $error("Case 9 Fail: Dependent merged miss not recorded correctly.");
            test_failed = 1;
        end

                // Return primary
        mem2proc_data_tag = 4'd5;
        mem2proc_data     = 64'hCAFE_BABE_1234_5678;

        @(posedge clock);
        #1;

        $display("DEBUG Case 9 primary completion @ %0t", $time);
        $display("  com.valid        = %0b", com_miss_req.valid);
        $display("  com.dep_miss     = %0b", com_miss_req.dep_miss);
        $display("  com.addr         = 0x%08h", com_miss_req.miss_req_address);
        $display("  com.req_is_load  = %0b", com_miss_req.req_is_load);
        $display("  com.size         = %0d", com_miss_req.miss_req_size);
        $display("  com.lq_index     = %0d", com_miss_req.lq_index);
        $display("  com.refill_data  = 0x%016h", com_miss_req.refill_data);
        $display("  out_head         = %0d", dut.out_head);
        $display("  out_tail         = %0d", dut.out_tail);
        $display("  out_count        = %0d", dut.out_count);
        dump_outstanding_table();

        assert(com_miss_req.valid == 1'b1 &&
               com_miss_req.dep_miss == 1'b0 &&
               com_miss_req.miss_req_address == 32'h0000_0200 &&
               com_miss_req.lq_index == 6'd3 &&
               com_miss_req.refill_data == 64'hCAFE_BABE_1234_5678) else begin
            $error("Case 9 Fail: Primary completion incorrect.");
            test_failed = 1;
        end

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