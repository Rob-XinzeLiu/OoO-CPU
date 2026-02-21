`include "sys_defs.svh"

module testbench; 
    logic clock, reset, mispredicted;
    logic [1:0] dispatched_inst_cnt;
    ROB_IDX     mispredicted_index; 
    PRF_IDX     t_from_freelist[`N-1:0];
    PRF_IDX     told_from_mt[`N-1:0];
    X_C_PACKET  cdb[`N-1:0];

    // DUT Outputs
    PRF_IDX     told_to_freelist[`N-1:0];
    ROB_CNT     space_avail;
    ROB_IDX     rob_index[`N-1:0];

    // Instantiate the rob
    rob dut (
        .clock(clock), .reset(reset), .mispredicted(mispredicted),
        .dispatched_inst_cnt(dispatched_inst_cnt),
        .mispredicted_index(mispredicted_index),
        .t_from_freelist(t_from_freelist),
        .told_from_mt(told_from_mt),
        .cdb(cdb),
        .told_to_freelist(told_to_freelist),
        .space_avail(space_avail),
        .rob_index(rob_index)
    );

    task reset_dut();
        clock = 0; reset = 1;
        mispredicted = 0; dispatched_inst_cnt = 0;
        mispredicted_index = 0;
        for(int i=0; i<`N; i++) cdb[i] = '0;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        $display(">>> System Reset Done.");
    endtask

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    bit test_failed = 0; 

    always @(posedge clock) begin
        if (!reset) begin
            if (rob_index[0] !== dut.tail_ptr || rob_index[1] != dut.tail_ptr + 1'b1) begin
                $error("Bug: rob_index is incorrect!");
                test_failed = 1;
            end 
        end
    end

    initial begin 
        reset_dut();


        // --- Case 1: Standard 2-way Dispatch & Retire ---
        $display("\nCase 1: Dispatch 2 and Retire (Check Data Integrity)");
        dispatched_inst_cnt = 2;
        t_from_freelist[0] = 10; told_from_mt[0] = 5; 
        t_from_freelist[1] = 11; told_from_mt[1] = 6; 
        @(negedge clock);
        dispatched_inst_cnt = 0; 

        cdb[0].valid = 1; cdb[0].complete_index = 0; 
        cdb[1].valid = 1; cdb[1].complete_index = 1;
        @(negedge clock);
        
        assert(told_to_freelist[0] == 5 && told_to_freelist[1] == 6) else begin
            $error("Case 1 Fail: Retirement Told tags mismatch! Got %0d, %0d", told_to_freelist[0], told_to_freelist[1]);
            test_failed = 1; 
        end

        cdb[0].valid = 0; cdb[1].valid = 0;
        repeat(2) @(negedge clock); 
        assert(dut.head_ptr == 2) else begin 
            $error("Case 1 Fail: Head pointer did not advance to 2!"); 
            test_failed = 1; 
        end


        // --- Case 2: Misprediction Recovery via Index ---
        $display("\nCase 2: Branch Misprediction (Flush youngest instructions)");
    
        dispatched_inst_cnt = 2;
        t_from_freelist[0] = 20; told_from_mt[0] = 15;
        t_from_freelist[1] = 21; told_from_mt[1] = 16;
        @(negedge clock);
        dispatched_inst_cnt = 0;

        mispredicted = 1;
        mispredicted_index = 2; 
        @(negedge clock);
        mispredicted = 0;


        // ASSERTION: Tail should be at mispredicted_index + 1
        assert(dut.tail_ptr == 3) else begin 
            $error("Case 2 Fail: Tail recovery incorrect! Got %0d, expected 3", dut.tail_ptr); 
            test_failed = 1; 
        end
        // Since Head=2 and Tail=3, rob_count must be 1 (only the branch remains)
        assert(dut.rob_count == 1) else begin 
            $error("Case 2 Fail: rob_count mismatch after recovery!"); 
            test_failed = 1; 
        end


        // --- Case 3: In-Order Retirement Check ---
        $display("\nCase 3: Out-of-Order Completion (Younger ready, Older not)");
        reset_dut();

        dispatched_inst_cnt = 2;
        t_from_freelist[0] = 30; told_from_mt[0] = 20;
        t_from_freelist[1] = 31; told_from_mt[1] = 21;
        @(negedge clock);
        dispatched_inst_cnt = 0;


        // CDB completes index 1 (younger)
        cdb[0].valid = 1; cdb[0].complete_index = 1; 
        @(negedge clock);
        cdb[1].valid = 0;
        
        repeat(2) @(negedge clock);
        // ASSERTION: Head must NOT move if the oldest instruction isn't ready
        assert(dut.head_ptr == 0 && dut.tail_ptr == 2 && dut.rob_array[0].ready_retire == 0) else begin 
            $error("Case 3 Fail: Head cannot move if the older instruction hasn't retired"); 
            test_failed = 1; 
        end


        // --- Case 4: Full ROB & Wrap-around Check ---
        $display("\nCase 4: Fill ROB to test pointer wrap-around");
        reset_dut();
        
        // Loop to fill the buffer (Assuming ROB_SZ is 32)
        for(int i = 0; i < `ROB_SZ; i += 2) begin
            dispatched_inst_cnt = 2;
            t_from_freelist[0] = i; t_from_freelist[1] = i+1;
            @(negedge clock);
        end
        dispatched_inst_cnt = 0;

        // ASSERTION: Tail must wrap back to 0 if ROB is full
        assert(dut.tail_ptr == 0) else begin 
            $error("Case 4 Fail: Tail pointer wrap-around failed!"); 
            test_failed = 1; 
        end
        assert(space_avail == 0) else begin 
            $error("Case 4 Fail: space_avail should be 0!"); 
            test_failed = 1; 
        end

        // --- Case 5: Standard 1-way Dispatch & Retire ---
        reset_dut();

        $display("\nCase 5: Dispatch 1 and Retire (Check Data Integrity)");
        dispatched_inst_cnt = 1;
        t_from_freelist[0] = 10; told_from_mt[0] = 5; 
        @(negedge clock);
        dispatched_inst_cnt = 0;


        cdb[0].valid = 1; cdb[0].complete_index = 0; 


        
        assert(told_to_freelist[0] == 5) else begin
            $error("Case 5 Fail: Retirement Told tags mismatch! Got %0d", told_to_freelist[0]);
            test_failed = 1; 
        end

        cdb[0].valid = 0; cdb[1].valid = 0;
        repeat(2) @(negedge clock); 
        assert(dut.head_ptr == 1) else begin 
            $error("Case 5 Fail: Head pointer did not advance to 1!"); 
            test_failed = 1; 
        end



        // --- Case 6: Clear ready_retire in rob when we dispatch new instructions ---
        reset_dut();

        $display("\nCase 6: Clear ready_retire in rob when we retire instructions");
        dispatched_inst_cnt = 1;
        t_from_freelist[0] = 10; told_from_mt[0] = 5; 
        @(negedge clock);
        dispatched_inst_cnt = 0;


        cdb[0].valid = 1; cdb[0].complete_index = 0; 
        @(negedge clock);

        cdb[0].valid = 0; cdb[1].valid = 0;
        repeat(2) @(negedge clock); 



        assert(dut.rob_array[0].ready_retire == 1'b0) else begin
            $error("Case 6 Fail: Didn't clear the ready_retire bit");
            test_failed = 1; 
        end


        // --- Final Result ---
        #500;
        $display("\n############################################");
        if(test_failed == 0) begin
            $display("##   ALL TESTS PASSED! ##");
        end else begin
            $display("##   VERIFICATION FAILED! BUGS DETECTED   ##");
        end
        $display("############################################");
        $finish;
    end


endmodule