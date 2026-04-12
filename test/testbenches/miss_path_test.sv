`timescale 1ns/1ps
`include "sys_defs.svh"
`include "ISA.svh"

module testbench;

    logic clock, reset;
    logic grant;

    // -------------------------
    // Dcache inputs
    // -------------------------
    LQ_PACKET load_req_pack;
    SQ_PACKET store_req_pack;

    completed_mshr_t com_miss_req;
    logic            miss_returned;
    logic            miss_queue_full;
    MEM_TAG          mem2proc_transaction_tag;

    // -------------------------
    // Dcache outputs
    // -------------------------
    dcache_data_t  cache_resp_data;
    miss_request_t miss_request;

    // -------------------------
    // MSHR signals
    // -------------------------
    MEM_TAG   mem2proc_data_tag;
    MEM_BLOCK mem2proc_data;

    MEM_COMMAND mshr2mem_command;
    ADDR        mshr2mem_addr;
    MEM_SIZE    mshr2mem_size;
    MEM_BLOCK   mshr2mem_data;

    // -------------------------
    // Instantiate DUTs
    // -------------------------

    Dcache dcache (
        .clock(clock),
        .reset(reset),
        .load_req_pack(load_req_pack),
        .store_req_pack(store_req_pack),
        .com_miss_req(com_miss_req),
        .miss_returned(miss_returned),
        .miss_queue_full(miss_queue_full),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .grant(grant),

        .cache_resp_data(cache_resp_data),
        .miss_request(miss_request),

        .wb2mem_command(),
        .wb2mem_addr(),
        .wb2mem_data(),
        .wb2mem_size(),

        .dcache_can_accept_store(),
        .dcache_can_accept_load(),

        .dcache_debug_data(),
        .dcache_debug_tags(),
        .debug_vc_entries(),
        .debug_write_buff()
    );

    mshr mshr (
        .clock(clock),
        .reset(reset),
        .grant(grant),

        .dcache_miss_req(miss_request),

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
        .mshr_wait_for_trans(),
        .mshr_currently_waiting()
    );

    task dump_mshr_outstanding();
        begin
            $display("---- MSHR Outstanding Table ----");
            $display("out_head=%0d out_tail=%0d out_count=%0d req_state=%0d",
                mshr.out_head, mshr.out_tail, mshr.out_count, mshr.req_state);

            for (int i = 0; i < `MSHR_ENTRIES; i++) begin
                $display("OT[%0d] valid=%0b ready=%0b dep=%0b tag=%0d addr=%h set=%0d off=%0d req_is_load=%0b lq=%0d refill=%h",
                    i,
                    mshr.outstanding_table[i].valid,
                    mshr.outstanding_table[i].ready,
                    mshr.outstanding_table[i].dep_miss,
                    mshr.outstanding_table[i].trans_tag,
                    mshr.outstanding_table[i].miss_req_address,
                    mshr.outstanding_table[i].miss_req_set,
                    mshr.outstanding_table[i].miss_req_offset,
                    mshr.outstanding_table[i].req_is_load,
                    mshr.outstanding_table[i].lq_index,
                    mshr.outstanding_table[i].refill_data
                );
            end
            $display("--------------------------------");
        end
    endtask
    task dump_mshr_fifo();
    begin
        $display("---- MSHR Miss FIFO ----");
        $display("miss_head=%0d miss_tail=%0d miss_count=%0d active_valid=%0b active_addr=%h active_set=%0d",
            mshr.miss_head, mshr.miss_tail, mshr.miss_count,
            mshr.active_req.valid, mshr.active_req.miss_req_address, mshr.active_req.miss_req_set);

        for (int i = 0; i < `MSHR_ENTRIES; i++) begin
            $display("FIFO[%0d] valid=%0b dep=%0b addr=%h set=%0d off=%0d load=%0b lq=%0d",
                i,
                mshr.miss_fifo[i].valid,
                mshr.miss_fifo[i].dependent,
                mshr.miss_fifo[i].miss_req_address,
                mshr.miss_fifo[i].miss_req_set,
                mshr.miss_fifo[i].miss_req_offset,
                mshr.miss_fifo[i].req_is_load,
                mshr.miss_fifo[i].lq_index
            );
        end
        $display("------------------------");
    end
endtask
    // -------------------------
    // Clock
    // -------------------------
    always #5 clock = ~clock;

    // -------------------------
    // Helpers
    // -------------------------
    task reset_dut();
        begin
            clock = 0;
            reset = 1;
            grant = 1;

            load_req_pack = '0;
            store_req_pack = '0;

            mem2proc_transaction_tag = 0;
            mem2proc_data_tag = 0;
            mem2proc_data = 0;

            @(negedge clock);
            reset = 0;
            @(negedge clock);

            $display(">>> Reset Done");
        end
    endtask

    task send_load(input ADDR addr, input int lq_idx);
        begin
            load_req_pack = '0;
            load_req_pack.valid = 1;
            load_req_pack.addr = addr;
            load_req_pack.funct3 = {1'b0, WORD};
            load_req_pack.lq_index = lq_idx;
        end
    endtask

    task clear_req();
        begin
            load_req_pack = '0;
            store_req_pack = '0;
        end
    endtask

    // -------------------------
    // TEST
    // -------------------------
    initial begin
    reset_dut();

    $display("\n=== Back-to-Back Store/Store/Store/Load Test ===");

    // -------------------------
    // Cycle 1: store to ff1c (set=3)
    // -------------------------
    store_req_pack = '0;
    store_req_pack.valid  = 1;
    store_req_pack.addr   = 32'h0000_ff1c;
    store_req_pack.data   = 32'hAAAA_AAAA;
    store_req_pack.funct3 = {1'b0, WORD}; // SW
    @(negedge clock);
    clear_req();

    // -------------------------
    // Cycle 2: store to ff18 (same block)
    // -------------------------
    store_req_pack = '0;
    store_req_pack.valid  = 1;
    store_req_pack.addr   = 32'h0000_ff18;
    store_req_pack.data   = 32'hBBBB_BBBB;
    store_req_pack.funct3 = {1'b0, WORD};
    @(negedge clock);
    clear_req();

    // -------------------------
    // Cycle 3: store to ff14 (different set)
    // -------------------------
    store_req_pack = '0;
    store_req_pack.valid  = 1;
    store_req_pack.addr   = 32'h0000_ff14;
    store_req_pack.data   = 32'hCCCC_CCCC;
    store_req_pack.funct3 = {1'b0, WORD};
    @(negedge clock);
    clear_req();

    // -------------------------
    // Accept first miss (ff1c block)
    // -------------------------
    @(posedge clock);
    mem2proc_transaction_tag = 4'd1;
    @(negedge clock);
    mem2proc_transaction_tag = 0;

    @(posedge clock); #1;
    dump_mshr_fifo();
    dump_mshr_outstanding();

    // -------------------------
    // Accept second block (ff14)
    // -------------------------
    @(posedge clock);
    mem2proc_transaction_tag = 4'd2;
    @(negedge clock);
    mem2proc_transaction_tag = 0;
    @(posedge clock); #1;
    dump_mshr_fifo();
    dump_mshr_outstanding();

    // -------------------------
    // Memory returns first block (ff1c/ff18)
    // -------------------------
    mem2proc_data_tag = 4'd1;
    mem2proc_data     = 64'h1111_2222_3333_4444;
    @(posedge clock); #1;
    dump_mshr_fifo();
    dump_mshr_outstanding();

    @(posedge clock);
    #1;

    $display("Resp1: valid=%0b addr=0x%h",
        cache_resp_data.valid,
        cache_resp_data.data
    );

    // -------------------------
    // Memory returns second block (ff14)
    // -------------------------
    mem2proc_data_tag = 4'd2;
    mem2proc_data     = 64'h5555_6666_7777_8888;

    @(posedge clock);
    #1;

    // -------------------------
    // Now load from ff1c (should hit)
    // -------------------------
    send_load(32'h0000_ff1c, 6'd9);
    @(posedge clock);
    #1;

    $display("Final load: valid=%0b lq=%0d data=0x%08h",
        cache_resp_data.valid,
        cache_resp_data.lq_index,
        cache_resp_data.data
    );

    assert(cache_resp_data.valid == 1) else begin
        $error("FAIL: final load did not hit");
    end
    @(posedge clock); #1;
    dump_mshr_fifo();
    dump_mshr_outstanding();

    $display("\n🔥 BACK-TO-BACK TEST PASSED 🔥");
    $finish;
end

endmodule