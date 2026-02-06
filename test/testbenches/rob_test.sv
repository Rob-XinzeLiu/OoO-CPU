`include "sys_defs.svh"

module testbnech;
    logic clock, reset, mispredicted;
    logic       [1:0]   dispatched_inst_cnt;
    PRF_IDX             mispredicted_tag;
    PRF_IDX             t_from_freelist[`N-1:0];
    PRF_IDX             told_from_mt[`N-1:0];
    REG_IDX             dest_reg_in[`N-1:0];
    X_C_PACKET          cdb[`N-1:0];

    ROB dut(
        .clock(clock),
        .reset(reset),
        .mispredicted(mispredicted),
        .dispatched_inst_cnt(dispatched_inst_cnt),
        .mispredicted_tag(mispredicted_tag),
        .t_from_freelist(t_from_freelist),
        .told_from_mt(told_from_mt),
        .dest_reg_in(dest_reg_in),
        .cdb(cdb)
    );

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end

    initial begin
        clock = 0;
        reset = 1;
        mispredicted = 0;
        dispatched_inst_cnt = 0;
        mispredicted_tag = 0;
        for(int i=0; i<`N; i++) begin
            t_from_freelist[i] = 0; 
            told_from_mt[i] = 0;
            dest_reg_in[i] = 0;
            cdb[i] = '0;
        end
        @(negedge clock);
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        @(negedge clock);

        // Preload ROB with one instruction
        @(negedge clock);
        dispatched_inst_cnt = 1;
        t_from_freelist[0] = 5;
        told_from_mt[0]    = 1;
        dest_reg_in[0]     = 5'd3;
        @(negedge clock);
        dispatched_inst_cnt = 0;

        @(negedge clock);

        // 1️⃣ Dispatch a NEW instruction
        dispatched_inst_cnt = 1;
        t_from_freelist[0] = 6;
        told_from_mt[0]    = 2;
        dest_reg_in[0]     = 5'd4;

        // 2️⃣ Complete the OLDER instruction
        cdb[0].valid            = 1;
        cdb[0].ready_retire_tag = 5;  // tag of first instruction

        @(negedge clock);
        dispatched_inst_cnt = 2;
        t_from_freelist[0] = 7;
        told_from_mt[0]    = 4;
        dest_reg_in[0]     = 5'd8;
        t_from_freelist[1] = 8;
        told_from_mt[1]    = 9;
        dest_reg_in[1]     = 5'd9;

        @(negedge clock)
        // Deassert everything
        dispatched_inst_cnt = 0;
        cdb[0].valid = 0;



        #1000;
        $finish;
    end





endmodule