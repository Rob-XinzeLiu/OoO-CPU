`include "sys_defs.svh"
`timescale 1ns/100ps

module testbench;

    // ---------- DUT inputs ----------
    logic               clock, reset;
    D_S_PACKET          dispatch_pack   [`N-1:0];
    logic               [`N-1:0] is_branch;
    logic               mispredicted;
    ROB_IDX             rob_tail_in;        // from branch_stack on mispredict
    X_C_PACKET          [`N-1:0] cdb;
    COND_BRANCH_PACKET  cond_branch_in;
    SQ_PACKET           sq_in;
    logic               halt_safe;

    // ---------- DUT outputs ----------
    RETIRE_PACKET       [`N-1:0] rob_commit;
    logic               [1:0] rob_space_avail;
    ROB_IDX             rob_index       [`N-1:0];
    ROB_IDX             rob_tail_out    [`N-1:0];

    rob dut (
        .clock(clock), .reset(reset),
        .dispatch_pack(dispatch_pack), .is_branch(is_branch),
        .mispredicted(mispredicted), .rob_tail_in(rob_tail_in),
        .cdb(cdb), .cond_branch_in(cond_branch_in),
        .sq_in(sq_in), .halt_safe(halt_safe),
        .rob_commit(rob_commit), .rob_space_avail(rob_space_avail),
        .rob_index(rob_index), .rob_tail_out(rob_tail_out)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;
    int test_failed = 0;

    task automatic reset_dut();
        clock = 0; reset = 1; mispredicted = 0; halt_safe = 1;
        dispatch_pack   = '{default: '0};
        is_branch       = '0;
        cdb             = '{default: '0};
        cond_branch_in  = '0;
        sq_in           = '0;
        rob_tail_in     = '0;
        @(negedge clock); reset = 0;
        @(negedge clock);
        $display(">>> Reset done. head=%0d tail=%0d", dut.head_ptr, dut.tail_ptr);
    endtask

    task automatic check(input string msg, input logic cond);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            test_failed++;
        end
    endtask

    task automatic idle();
        dispatch_pack  = '{default: '0};
        is_branch      = '0;
        cdb            = '{default: '0};
        cond_branch_in = '0;
        sq_in          = '0;
        mispredicted   = 0;
    endtask

    // Build a minimal D_S_PACKET for dispatch
    function automatic D_S_PACKET make_pack(
        input PRF_IDX T, Told,
        input logic halt = 0, wr_mem = 0, rd_mem = 0, has_dest = 1
    );
        D_S_PACKET p;
        p         = '0;
        p.valid   = 1;
        p.T       = T;
        p.Told    = Told;
        p.halt    = halt;
        p.wr_mem  = wr_mem;
        p.rd_mem  = rd_mem;
        p.has_dest = has_dest;
        return p;
    endfunction

    // Complete an instruction via CDB (sets ready_retire in next_rob_array)
    task automatic cdb_complete(input ROB_IDX idx, input PRF_IDX tag, input DATA result = '0, input int slot = 0);
        cdb[slot].valid          = 1;
        cdb[slot].complete_index = idx;
        cdb[slot].complete_tag   = tag;
        cdb[slot].result         = result;
    endtask

    // ---------------------------------------------------------------
    // Case 1: 2-way dispatch then retire, check t_old values
    // Timeline: dispatch → CDB → [wait] → rob_commit valid
    // ---------------------------------------------------------------
    task automatic case1_2way_dispatch_retire();
        $display("\nCase 1: 2-way dispatch + retire (data integrity)");
        // Dispatch 2 instructions at ROB[0] and ROB[1]
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(10)), .Told(PRF_IDX'(5)));
        dispatch_pack[1] = make_pack(.T(PRF_IDX'(11)), .Told(PRF_IDX'(6)));
        @(negedge clock);   // posedge latches them
        idle();
        // CDB: complete both instructions
        cdb_complete(ROB_IDX'(0), PRF_IDX'(10), 32'hAABB, 0);
        cdb_complete(ROB_IDX'(1), PRF_IDX'(11), 32'hCCDD, 1);
        @(negedge clock);   // posedge sets ready_retire=1 in rob_array
        idle();
        // Now rob_commit fires combinationally: check t_old
        #1;
        check("Case1: rob_commit[0].valid",     rob_commit[0].valid);
        check("Case1: rob_commit[1].valid",     rob_commit[1].valid);
        check("Case1: t_old[0] == Told p5",     rob_commit[0].t_old == PRF_IDX'(5));
        check("Case1: t_old[1] == Told p6",     rob_commit[1].t_old == PRF_IDX'(6));
        check("Case1: data[0] correct",         rob_commit[0].data  == 32'hAABB);
        @(negedge clock);   // head advances to 2
        idle();
        check("Case1: head advanced to 2", dut.head_ptr == 2);
        check("Case1: ROB space restored", rob_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // Case 2: Misprediction recovery
    // Dispatch 2 more instructions (at [2],[3]), branch at [2]
    // Mispredict: restore tail to rob_tail_out[0] (= 3), squash [3]
    // ---------------------------------------------------------------
    task automatic case2_mispredict();
        $display("\nCase 2: Branch misprediction (flush youngest)");
        // After Case 1: head=2, tail=2
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(20)), .Told(PRF_IDX'(15)));
        dispatch_pack[1] = make_pack(.T(PRF_IDX'(21)), .Told(PRF_IDX'(16)));
        is_branch[0] = 1; // branch at slot 0 → rob_tail_out[0] = tail+1 = 3
        @(negedge clock);
        idle();
        // Save the branch's tail checkpoint (combinationally available before clock)
        // rob_tail_out[0] was valid in the previous cycle's combinational output
        // After posedge: tail=4. Mispredict, restore to 3
        mispredicted = 1;
        rob_tail_in  = ROB_IDX'(3); // tail after dispatching inst[0]
        @(negedge clock);
        idle();
        // After mispredict: tail = 3, head = 2 → 1 entry remains
        check("Case2: tail restored to 3", dut.tail_ptr == ROB_IDX'(3));
        check("Case2: head unchanged at 2", dut.head_ptr == ROB_IDX'(2));
        // free_slots = ROB_SZ - (3-2) = ROB_SZ - 1
        check("Case2: space_avail = 2 (1 entry, 31 free)",
              rob_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // Case 3: Out-of-order completion — older not ready → no retire
    // ---------------------------------------------------------------
    task automatic case3_in_order_retirement();
        $display("\nCase 3: Out-of-order completion (older stalls head)");
        reset_dut();
        // Dispatch 2 instructions at [0] and [1]
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(30)), .Told(PRF_IDX'(20)));
        dispatch_pack[1] = make_pack(.T(PRF_IDX'(31)), .Told(PRF_IDX'(21)));
        @(negedge clock);
        idle();
        // CDB completes only index 1 (younger), index 0 still not ready
        cdb_complete(ROB_IDX'(1), PRF_IDX'(31), '0, 0);
        @(negedge clock);
        idle();
        // rob_array[1].ready_retire=1, rob_array[0].ready_retire=0
        // head must NOT advance (oldest not ready)
        #1;
        check("Case3: no commit while older not ready", !rob_commit[0].valid);
        @(negedge clock);
        check("Case3: head stays at 0",              dut.head_ptr == 0);
        check("Case3: rob_array[0] not ready",       dut.rob_array[0].ready_retire == 0);
        // Now complete index 0 → both retire next cycle
        @(negedge clock);
        cdb_complete(ROB_IDX'(0), PRF_IDX'(30), '0, 0);
        @(negedge clock);
        idle();
        #1;
        check("Case3: both commit after older ready", rob_commit[0].valid && rob_commit[1].valid);
    endtask

    // ---------------------------------------------------------------
    // Case 4: Fill ROB completely — wrap-around, space_avail = 0
    // ---------------------------------------------------------------
    task automatic case4_full_rob();
        $display("\nCase 4: Fill ROB to test wrap-around");
        reset_dut();
        // Dispatch ROB_SZ/2 pairs to fill all slots
        for (int i = 0; i < `ROB_SZ / 2; i++) begin
            @(negedge clock);
            dispatch_pack[0] = make_pack(.T(PRF_IDX'(i*2)),   .Told(PRF_IDX'(0)));
            dispatch_pack[1] = make_pack(.T(PRF_IDX'(i*2+1)), .Told(PRF_IDX'(0)));
        end
        @(negedge clock);
        idle();
        // Tail wraps to 0 (all slots filled)
        check("Case4: tail wrapped to 0",  dut.tail_ptr == ROB_IDX'(0));
        check("Case4: full flag set",      dut.full == 1'b1);
        check("Case4: space_avail = 0",   rob_space_avail == 2'd0);
    endtask

    // ---------------------------------------------------------------
    // Case 5: 1-way dispatch and retire
    // ---------------------------------------------------------------
    task automatic case5_1way_dispatch_retire();
        $display("\nCase 5: 1-way dispatch + retire");
        reset_dut();
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(10)), .Told(PRF_IDX'(5)));
        // dispatch_pack[1].valid = 0 → dispatch_1 path
        @(negedge clock);
        idle();
        cdb_complete(ROB_IDX'(0), PRF_IDX'(10), '0, 0);
        @(negedge clock);
        idle();
        #1;
        check("Case5: rob_commit[0].valid",  rob_commit[0].valid);
        check("Case5: t_old[0] == p5",       rob_commit[0].t_old == PRF_IDX'(5));
        check("Case5: rob_commit[1] invalid", !rob_commit[1].valid);
        @(negedge clock);
        check("Case5: head advanced to 1",   dut.head_ptr == ROB_IDX'(1));
    endtask

    // ---------------------------------------------------------------
    // Case 6: Retired entry's ready_retire is cleared
    // ---------------------------------------------------------------
    task automatic case6_entry_cleared_after_retire();
        $display("\nCase 6: ready_retire cleared after retire");
        reset_dut();
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(10)), .Told(PRF_IDX'(5)));
        @(negedge clock);
        idle();
        cdb_complete(ROB_IDX'(0), PRF_IDX'(10), '0, 0);
        @(negedge clock);
        idle();
        @(negedge clock); // head advances, entry cleared
        // rob_array[0] should now be zeroed (cleared on retire)
        check("Case6: entry cleared after retire",
              dut.rob_array[0].ready_retire == 1'b0 && dut.rob_array[0].valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // Case 7: rob_index output matches tail at dispatch time
    // ---------------------------------------------------------------
    task automatic case7_rob_index_correct();
        $display("\nCase 7: rob_index output matches tail pointer");
        reset_dut();
        @(negedge clock);
        dispatch_pack[0] = make_pack(.T(PRF_IDX'(5)), .Told(PRF_IDX'(1)));
        dispatch_pack[1] = make_pack(.T(PRF_IDX'(6)), .Told(PRF_IDX'(2)));
        #1;
        // rob_index is combinational from current tail
        check("Case7: rob_index[0] == tail",   rob_index[0] == dut.tail_ptr);
        check("Case7: rob_index[1] == tail+1", rob_index[1] == ROB_IDX'(dut.tail_ptr + 1));
        @(negedge clock);
        idle();
    endtask

    initial begin
        reset_dut();
        case1_2way_dispatch_retire();
        case2_mispredict();
        case3_in_order_retirement();
        case4_full_rob();
        case5_1way_dispatch_retire();
        case6_entry_cleared_after_retire();
        case7_rob_index_correct();
        #100;
        if (test_failed == 0)
            $display("\n@@@ Passed");
        else
            $display("\n@@@ Failed (%0d checks failed)", test_failed);
        $finish;
    end

endmodule
