`timescale 1ns/1ps
`include "sys_defs.svh"
`include "ISA.svh"

module testbench;

    localparam int ENTRIES = 8;

    logic            clock, reset;
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

    bit test_failed = 0;

    mshr #(
        .ENTRIES(ENTRIES)
    ) dut (
        .clock(clock),
        .reset(reset),
        .dcache_miss_req(dcache_miss_req),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .mem2proc_data_tag(mem2proc_data_tag),
        .mem2proc_data(mem2proc_data),
        .mshr2mem_command(mshr2mem_command),
        .mshr2mem_addr(mshr2mem_addr),
        .mshr2mem_size(mshr2mem_size),
        .mshr2mem_data(mshr2mem_data),
        .com_miss_req(com_miss_req),
        .miss_queue_full(miss_queue_full)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    task reset_dut();
        begin
            clock = 0;
            reset = 1;

            dcache_miss_req = '0;
            mem2proc_transaction_tag = '0;
            mem2proc_data_tag = '0;
            mem2proc_data = '0;

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
        input DATA     store_data
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
        end
    endtask

    task clear_miss();
        begin
            dcache_miss_req = '0;
        end
    endtask

    initial begin
        reset_dut();

        // ------------------------------------------------------------
        // Case 1: Enqueue one miss, then move to active request
        // ------------------------------------------------------------
        $display("\nCase 1: Enqueue one miss and move into active request");

        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0);
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

        // ------------------------------------------------------------
        // Case 2: Memory accepts request, outstanding entry created
        // ------------------------------------------------------------
        $display("\nCase 2: Memory accepts request and creates outstanding entry");

        mem2proc_transaction_tag = 4'd3;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        assert(mshr2mem_command == MEM_NONE && dut.req_state == REQ_IDLE) else begin
            $error("Case 2 Fail: FSM did not return to REQ_IDLE after accept.");
            test_failed = 1;
        end

        assert(dut.outstanding_table[0].valid == 1'b1 &&
               dut.outstanding_table[0].trans_tag == 4'd3 &&
               dut.outstanding_table[0].miss_req_address == 32'h0000_0040) else begin
            $error("Case 2 Fail: Outstanding entry not created correctly.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 3: Completion returns matching tag
        // ------------------------------------------------------------     

        $display("\nCase 3: Return data and complete request");

        mem2proc_data_tag = 4'd3;
        mem2proc_data     = 64'h1111_1111_1111_1111;
        #1;

        assert(com_miss_req.valid == 1'b1) else begin
            $error("Case 3 Fail: com_miss_req.valid not asserted.");
            test_failed = 1;
        end

        assert(com_miss_req.miss_req_address == 32'h0000_0040 &&
            com_miss_req.req_is_load == 1'b1 &&
            com_miss_req.miss_req_size == WORD &&
            com_miss_req.refill_data == 64'h1111_1111_1111_1111) else begin
            $error("Case 3 Fail: Completion packet incorrect.");
            test_failed = 1;
        end

        @(negedge clock);
        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        @(negedge clock);

        assert(dut.outstanding_table[0].valid == 1'b0) else begin
            $error("Case 3 Fail: Outstanding entry was not cleared.");
            test_failed = 1;
        end

        // ------------------------------------------------------------
        // Case 4: Queue multiple misses and accept them on consecutive cycles
        // ------------------------------------------------------------
        $display("\nCase 4: Queue 3 misses and accept 3 tags");

        reset_dut();

        send_miss(32'h0000_0040, 1'b1, WORD, 1'b0, '0);
        @(negedge clock);
        send_miss(32'h0000_0080, 1'b1, WORD, 1'b0, '0);
        @(negedge clock);
        send_miss(32'h0000_00C0, 1'b1, WORD, 1'b0, '0);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        // first request should issue
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
        dump_outstanding_table();
        mem2proc_transaction_tag = '0;
        @(negedge clock);   // back toward REQ_IDLE / pop next request
        @(negedge clock);   // now REQ_WAIT_ACCEPT should be driving third issue
        dump_outstanding_table();

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_00C0) else begin
            $error("Case 4 Fail: Third issue incorrect.");
            test_failed = 1;
        end

        mem2proc_transaction_tag = 4'd4;
        @(negedge clock);
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        // ------------------------------------------------------------
        // Case 5: Out-of-order completion
        // ------------------------------------------------------------
       $display("\nCase 5: Out-of-order completion");

        // tag 2
        mem2proc_data_tag = 4'd2;
        mem2proc_data     = 64'h2222_2222_2222_2222;
        #1;
        dump_outstanding_table();
        $display("DEBUG tag2: com_valid=%0b addr=0x%08h refill=0x%016h",
            com_miss_req.valid,
            com_miss_req.miss_req_address,
            com_miss_req.refill_data);

        assert(com_miss_req.valid == 1'b1 &&
            com_miss_req.miss_req_address == 32'h0000_0080 &&
            com_miss_req.refill_data == 64'h2222_2222_2222_2222) else begin
            $error("Case 5 Fail: Completion for tag 2 incorrect.");
            test_failed = 1;
        end
        @(negedge clock);

        // tag 1
        mem2proc_data_tag = 4'd1;
        mem2proc_data     = 64'h1111_1111_1111_1111;
        #1;
        dump_outstanding_table();
        $display("DEBUG tag1: com_valid=%0b addr=0x%08h refill=0x%016h",
            com_miss_req.valid,
            com_miss_req.miss_req_address,
            com_miss_req.refill_data);

        assert(com_miss_req.valid == 1'b1 &&
            com_miss_req.miss_req_address == 32'h0000_0040 &&
            com_miss_req.refill_data == 64'h1111_1111_1111_1111) else begin
            $error("Case 5 Fail: Completion for tag 1 incorrect.");
            test_failed = 1;
        end
        @(negedge clock);

        // tag 4
        mem2proc_data_tag = 4'd4;
        mem2proc_data     = 64'h4444_4444_4444_4444;
        #1;
        dump_outstanding_table();
        $display("DEBUG tag4: com_valid=%0b addr=0x%08h refill=0x%016h",
            com_miss_req.valid,
            com_miss_req.miss_req_address,
            com_miss_req.refill_data);

        assert(com_miss_req.valid == 1'b1 &&
            com_miss_req.miss_req_address == 32'h0000_00C0 &&
            com_miss_req.refill_data == 64'h4444_4444_4444_4444) else begin
            $error("Case 5 Fail: Completion for tag 4 incorrect.");
            test_failed = 1;
        end
        @(negedge clock);

        mem2proc_data_tag = '0;
        mem2proc_data     = '0;
        @(negedge clock);
        // ------------------------------------------------------------
        // Case 6: Retry when memory does not accept
        // ------------------------------------------------------------
        $display("\nCase 6: Retry while transaction tag is 0");

        reset_dut();

        send_miss(32'h0000_0100, 1'b1, WORD, 1'b0, '0);
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

        send_miss(32'h0000_0144, 1'b0, BYTE, 1'b0, 32'h0000_00AB);
        @(negedge clock);
        clear_miss();
        @(negedge clock);

        assert(mshr2mem_command == MEM_LOAD && mshr2mem_addr == 32'h0000_0144) else begin
            $error("Case 7 Fail: Store miss did not issue MEM_LOAD.");
            test_failed = 1;
        end

        // accept request first
        mem2proc_transaction_tag = 4'd7;
        @(negedge clock);
        dump_outstanding_table();
        mem2proc_transaction_tag = '0;
        @(negedge clock);

        // now complete it
        mem2proc_data_tag = 4'd7;
        mem2proc_data     = 64'hAAAA_BBBB_CCCC_DDDD;
        #1;

        $display("DEBUG Case7 completion:");
        $display("  com.valid         = %0b", com_miss_req.valid);
        $display("  com.req_is_load   = %0b", com_miss_req.req_is_load);
        $display("  com.size          = %0d", com_miss_req.miss_req_size);
        $display("  com.store_data    = 0x%08h", com_miss_req.miss_req_data);
        $display("  com.refill_data   = 0x%016h", com_miss_req.refill_data);
        dump_outstanding_table();

        assert(com_miss_req.valid == 1'b1 &&
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

    task dump_outstanding_table();
        begin
            $display("---- OUTSTANDING TABLE DUMP @ %0t ----", $time);
            for (int i = 0; i < ENTRIES; i++) begin
                $display("idx=%0d valid=%0b tag=%0d addr=0x%08h size=%0d load=%0b data=0x%08h",
                    i,
                    dut.outstanding_table[i].valid,
                    dut.outstanding_table[i].trans_tag,
                    dut.outstanding_table[i].miss_req_address,
                    dut.outstanding_table[i].miss_req_size,
                    dut.outstanding_table[i].req_is_load,
                    dut.outstanding_table[i].miss_req_data
                );
            end
            $display("--------------------------------------");
        end
    endtask
endmodule