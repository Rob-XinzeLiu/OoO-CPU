`include "sys_defs.svh"

module testbench; 
    logic clock, reset, mispredicted;
    logic [1:0] dispatched_inst_cnt;
    ROB_IDX     mispredicted_index; 
    PRF_IDX     t_from_freelist[`N-1:0];
    PRF_IDX     told_from_mt[`N-1:0];
    REG_IDX     dest_reg_in[`N-1:0];
    X_C_PACKET  cdb[`N-1:0];

    PRF_IDX     told_to_freelist[`N-1:0];
    PRF_IDX     t_to_amt[`N-1:0];
    REG_IDX     dest_reg_out[`N-1:0];
    ROB_CNT     space_avail;
    ROB_IDX     rob_index[`N-1:0];


    rob dut (
        .clock(clock), .reset(reset), .mispredicted(mispredicted),
        .dispatched_inst_cnt(dispatched_inst_cnt),
        .mispredicted_index(mispredicted_index),
        .t_from_freelist(t_from_freelist),
        .told_from_mt(told_from_mt),
        .cdb(cdb),
        .dest_reg_in(dest_reg_in),
        .told_to_freelist(told_to_freelist),
        .t_to_amt(t_to_amt),
        .dest_reg_out(dest_reg_out),
        .space_avail(space_avail),
        .rob_index(rob_index)
    );


    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    // Reset task
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

    // Dipatch 2 instrucitons
    task dispatch_2way(
        input  PRF_IDX t0, input PRF_IDX to0, input REG_IDX d0,
        input  PRF_IDX t1, input PRF_IDX to1, input REG_IDX d1,
        output ROB_IDX idx0, output ROB_IDX idx1
    );
        dispatched_inst_cnt = 2;
        t_from_freelist[0] = t0; told_from_mt[0] = to0; dest_reg_in[0] = d0;
        t_from_freelist[1] = t1; told_from_mt[1] = to1; dest_reg_in[1] = d1;
        
        #1; 
        idx0 = rob_index[0];
        idx1 = rob_index[1];
        
        @(negedge clock);
        dispatched_inst_cnt = 0;
    endtask


    ROB_IDX inst_idx[8]; // Track index
    bit testing = 0;

    initial begin
        reset_dut();

        $display("\nCase 1: Dispatch 2 and Retire");
        dispatch_2way(10, 5, 1, 11, 6, 2, inst_idx[0], inst_idx[1]);
        
        // CDB broadcasts 2 complete instructions
        cdb[0].valid = 1; cdb[0].complete_index = inst_idx[0];
        cdb[1].valid = 1; cdb[1].complete_index = inst_idx[1];
        @(negedge clock);
        cdb[0].valid = 0; cdb[1].valid = 0;

        assert(told_to_freelist[0] == 5 && told_to_freelist[1] == 6) else begin
            $error("Bug: Sent a wrong tag to the freelist");
            testing = 1;
        end

        assert(t_to_amt[0] == 10 && t_to_amt[1] == 11) else begin
            $error("Bug: Sent a wrong tag to amt");
            testing = 1;
        end
        assert(dest_reg_out[0] == 1 && dest_reg_out[1] == 2) else begin
            $error("Bug: Sent a wrong tag as a dest_reg");
            testing = 1;
        end
        $display("\n told_to_freelist[0] = %0d, told_to_freelist[1] = %0d, t_to_amt[0] = %0d, t_to_amt[1] = %0d", told_to_freelist[0], told_to_freelist[1], t_to_amt[0], t_to_amt[1]);

        // Check retirement
        repeat(2) @(negedge clock);

        assert(dut.head_ptr == 2) else begin
            $error("Bug: Retire-2 failed using complete_index!");
            testing = 1;
        end

        $display("\n--- Time: %0t | Head: %0d | Tail: %0d | Count: %0d ---", 
                     $time, dut.head_ptr, dut.tail_ptr, dut.rob_count);
            for(int i = 0; i < `ROB_SZ; i++) begin
                $display("ROB[%0d]: T=%0d | Told=%0d | Dest=%0d | Ready=%b",
                    i, dut.rob_array[i].t, dut.rob_array[i].told, 
                    dut.rob_array[i].dest_reg_idx, dut.rob_array[i].ready_retire);
            end
        
        @(negedge clock);
        reset_dut();

        $display("\nCase 2: Misprediction Recovery via Index");
        dispatch_2way(20, 15, 3, 21, 16, 4, inst_idx[2], inst_idx[3]);
        
        // Assume inst_idx[2] is a mispredict instruction
        mispredicted = 1;
        mispredicted_index = inst_idx[2]; 
        @(negedge clock);
        mispredicted = 0;

    
        assert(dut.tail_ptr == (inst_idx[2] + 1'b1)) else begin
            $error("Bug: Mispredict Tail recovery failed!");                                  // Check new tail position
            testing = 1;
        end

        assert(dut.rob_count == (ROB_CNT'(inst_idx[2] - dut.head_ptr) + 1'b1)) else begin
            $error("Bug: rob_count incorrect after recovery!");     // Check new rob_count
            testing = 1;
        end

        $display("\n--- Time: %0t | Head: %0d | Tail: %0d | Count: %0d ---", 
                     $time, dut.head_ptr, dut.tail_ptr, dut.rob_count);
            for(int i = 0; i < `ROB_SZ; i++) begin
                $display("ROB[%0d]: T=%0d | Told=%0d | Dest=%0d | Ready=%b",
                    i, dut.rob_array[i].t, dut.rob_array[i].told, 
                    dut.rob_array[i].dest_reg_idx, dut.rob_array[i].ready_retire);
            end
        @(negedge clock);
        reset_dut();

        $display("\nCase 3: The younger instruction is complete, we check that it won't if the older one hasn't retired");
        dispatch_2way(10, 5, 1, 11, 6, 2, inst_idx[0], inst_idx[1]);
        
        // CDB broadcasts 1 complete instructions
        cdb[1].valid = 1; cdb[1].complete_index = inst_idx[1];
        @(negedge clock);
        cdb[0].valid = 0; cdb[1].valid = 0;

        // Check retirement
        repeat(2) @(negedge clock);
        assert(dut.head_ptr == 0 && dut.tail_ptr == 2) else begin
            $error("Bug: Retire the younger instruciton!");
            testing = 1;
        end


        $display("\n--- Time: %0t | Head: %0d | Tail: %0d | Count: %0d ---", 
                     $time, dut.head_ptr, dut.tail_ptr, dut.rob_count);
            for(int i = 0; i < `ROB_SZ; i++) begin
                $display("ROB[%0d]: T=%0d | Told=%0d | Dest=%0d | Ready=%b",
                    i, dut.rob_array[i].t, dut.rob_array[i].told, 
                    dut.rob_array[i].dest_reg_idx, dut.rob_array[i].ready_retire);
            end

        @(negedge clock);
        reset_dut();

        $display("\nCase 4: Check the head_ptr, tail_ptr and space_avail calculations");
        for(int i = 0; i < `ROB_SZ; i += 2) begin
            dispatch_2way(10+i, 5+i, 1+i, 11+i, 6+i, 2+i, inst_idx[i], inst_idx[i+1]);
        end

        assert(dut.tail_ptr == 0) else begin
            $error("Bug: tail_ptr on a wrong entry");
            testing = 1;
        end

        assert(dut.rob_count == `ROB_SZ) else begin
            $error("Bug: wrong space_avail");
            testing = 1;
        end


        $display("\n--- Time: %0t | Head: %0d | Tail: %0d | Count: %0d ---", 
                     $time, dut.head_ptr, dut.tail_ptr, dut.rob_count);
            for(int i = 0; i < `ROB_SZ; i++) begin
                $display("ROB[%0d]: T=%0d | Told=%0d | Dest=%0d | Ready=%b",
                    i, dut.rob_array[i].t, dut.rob_array[i].told, 
                    dut.rob_array[i].dest_reg_idx, dut.rob_array[i].ready_retire);
            end

        cdb[0].valid = 1; cdb[0].complete_index = inst_idx[0];
        cdb[1].valid = 1; cdb[1].complete_index = inst_idx[1];
        @(negedge clock);
        dispatch_2way(3, 2, 9, 2, 1, 10, inst_idx[0], inst_idx[1]);
        


        $display("\n--- Time: %0t | Head: %0d | Tail: %0d | Count: %0d ---", 
                     $time, dut.head_ptr, dut.tail_ptr, dut.rob_count);
            for(int i = 0; i < `ROB_SZ; i++) begin
                $display("ROB[%0d]: T=%0d | Told=%0d | Dest=%0d | Ready=%b",
                    i, dut.rob_array[i].t, dut.rob_array[i].told, 
                    dut.rob_array[i].dest_reg_idx, dut.rob_array[i].ready_retire);
            end
        
        assert(dut.tail_ptr == 2) else begin
            $error("Bug: tail_ptr on a wrong entry");
            testing = 1;
        end

        assert(dut.head_ptr == 2) else begin
            $error("Bug: head_ptr on a wrong entry");
            testing = 1;
        end

        #500;
        $display("\n###############################");
        if(testing == 0) begin
            $display("##   ALL TESTS PASSED (STYLE OK) ##");
        end else begin
            $display("##   Wrong!!! ##");
        end
        $display("###############################");
        $finish;
    end

endmodule





