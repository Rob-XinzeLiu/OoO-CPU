`timescale 1ns/100ps
`include "sys_defs.svh"

// issue_pack slot layout (from rs.sv comment):
//   [0] = mult   [1] = load   [2] = ALU-0   [3] = ALU-1
//   [4] = cond_branch          [5] = store
`define IP_MULT   0
`define IP_LOAD   1
`define IP_ALU0   2
`define IP_ALU1   3
`define IP_CBRANCH 4
`define IP_STORE  5

module testbench;

    logic               clock, reset;
    logic               mispredicted;
    B_MASK              mispredicted_bmask_index;
    ROB_IDX             rob_index       [`N-1:0];
    D_S_PACKET          dispatch_pack   [`N-1:0];
    X_C_PACKET          cdb             [`N-1:0];
    logic               resolved;
    B_MASK              resolved_bmask_index;
    ETB_TAG_PACKET      early_tag_bus   [`N-1:0];
    logic               cdb_gnt_alu     [`N-1:0];
    // SQ inputs (unused in basic tests — tied to 0)
    logic               [`SQ_SZ-1:0] sq_valid_in;
    logic               [`SQ_SZ-1:0] sq_addr_ready_mask;
    SQ_IDX              sq_head_in;

    logic               cdb_req_alu     [`N-1:0];
    D_S_PACKET          issue_pack      [5:0];
    logic               [1:0] rs_empty_entries_num;

    rs dut (
        .clock(clock),
        .reset(reset),
        .mispredicted(mispredicted),
        .mispredicted_bmask_index(mispredicted_bmask_index),
        .rob_index(rob_index),
        .dispatch_pack(dispatch_pack),
        .sq_valid_in(sq_valid_in),
        .sq_addr_ready_mask(sq_addr_ready_mask),
        .sq_head_in(sq_head_in),
        .cdb(cdb),
        .resolved(resolved),
        .resolved_bmask_index(resolved_bmask_index),
        .early_tag_bus(early_tag_bus),
        .cdb_gnt_alu(cdb_gnt_alu),
        .cdb_req_alu(cdb_req_alu),
        .issue_pack(issue_pack),
        .rs_empty_entries_num(rs_empty_entries_num)
    );

    initial clock = 0;
    always #(`CLOCK_PERIOD/2.0) clock = ~clock;

    task automatic tick();
        @(posedge clock);
    endtask

    task automatic reset_dut();
        reset = 1;
        mispredicted          = 0;
        mispredicted_bmask_index = '0;
        resolved              = 0;
        resolved_bmask_index  = '0;
        cdb_gnt_alu           = '{default: '0};
        early_tag_bus         = '{default: '0};
        sq_valid_in           = '0;
        sq_addr_ready_mask    = '0;
        sq_head_in            = '0;
        for (int k = 0; k < `N; k++) begin
            dispatch_pack[k] = '0;
            rob_index[k]     = '0;
            cdb[k]           = '0;
        end
        tick(); tick();
        reset = 0;
        tick();
    endtask

    // Count how many issue_pack slots are valid this cycle
    function automatic int count_issued();
        int c = 0;
        for (int i = 0; i < 6; i++) c += issue_pack[i].valid;
        return c;
    endfunction

    function automatic int count_busy_rs();
        int c = 0;
        for (int i = 0; i < `RS_SZ; i++) c += dut.rs_entry[i].busy;
        return c;
    endfunction

    function automatic B_MASK bm_onehot(int idx);
        B_MASK tmp = '0;
        tmp[idx] = 1'b1;
        return tmp;
    endfunction

    task automatic display_rs_table(string tag);
        $display("\n=== RS TABLE: %s (t=%0t) ===", tag, $time);
        $display("rs_empty_entries_num=%0d", rs_empty_entries_num);
        $display(" idx | busy | mult | load | t1rdy | t2rdy | bmask |   PC");
        for (int i = 0; i < `RS_SZ; i++) begin
            if (dut.next_rs_entry[i].busy) begin
                $display("%4d |  1   |  %0d   |  %0d   |   %0d   |   %0d   | %08b | %08h",
                    i,
                    dut.next_rs_entry[i].mult,
                    dut.next_rs_entry[i].rd_mem,
                    dut.next_rs_entry[i].t1_ready,
                    dut.next_rs_entry[i].t2_ready,
                    dut.next_rs_entry[i].bmask,
                    dut.next_rs_entry[i].PC);
            end
        end
        $display("issue_pack valid: mult=%0d load=%0d alu0=%0d alu1=%0d\n",
            issue_pack[`IP_MULT].valid, issue_pack[`IP_LOAD].valid,
            issue_pack[`IP_ALU0].valid, issue_pack[`IP_ALU1].valid);
    endtask

    // Build a minimal D_S_PACKET for an ALU instruction
    function automatic D_S_PACKET make_alu(
        input PRF_IDX t1, t2,
        input logic t1_ready, t2_ready,
        input ADDR pc = 32'h1000,
        input B_MASK bmask = '0
    );
        D_S_PACKET p;
        p           = '0;
        p.valid     = 1;
        p.t1        = t1;  p.t2  = t2;
        p.t1_ready  = t1_ready;  p.t2_ready = t2_ready;
        p.PC        = pc;
        p.NPC       = pc + 4;
        p.bmask     = bmask;
        p.alu_func  = ALU_ADD;
        p.has_dest  = 1;
        return p;
    endfunction

    function automatic D_S_PACKET make_mult(
        input PRF_IDX t1, t2,
        input logic t1_ready, t2_ready,
        input ADDR pc = 32'h2000
    );
        D_S_PACKET p = make_alu(t1, t2, t1_ready, t2_ready, pc);
        p.mult = 1;
        return p;
    endfunction

    // ==============================================================
    // TEST 0: smoke_wakeup
    //   Dispatch 1 ALU op (t1 not ready), wakeup via ETB, check ALU issue
    // ==============================================================
    task automatic test0_smoke_wakeup();
        $display("\n[TEST0] smoke_wakeup: ALU issues via ETB wakeup");

        dispatch_pack[0] = make_alu(PRF_IDX'(12), PRF_IDX'(13), 0, 1, 32'h1000);
        dispatch_pack[1] = '0;
        rob_index[0]     = ROB_IDX'(3);
        tick(); // enqueue
        dispatch_pack[0] = '0;

        // Wakeup t1=12 via ETB; grant ALU CDB slot
        cdb_gnt_alu[0] = 1;
        early_tag_bus[0].valid = 1; early_tag_bus[0].tag = PRF_IDX'(12);
        tick(); // wakeup + issue
        display_rs_table("after ETB wakeup");

        // ALU goes to issue_pack[2]
        assert (issue_pack[`IP_ALU0].valid)
            else $error("TEST0 FAIL: ALU not issued to pack[%0d]", `IP_ALU0);
        assert (issue_pack[`IP_ALU0].t1 == PRF_IDX'(12))
            else $error("TEST0 FAIL: wrong t1 in issue_pack[ALU0], got %0d", issue_pack[`IP_ALU0].t1);
        assert (issue_pack[`IP_ALU0].t2 == PRF_IDX'(13))
            else $error("TEST0 FAIL: wrong t2 in issue_pack[ALU0], got %0d", issue_pack[`IP_ALU0].t2);
        $display("  PASS test0");

        cdb_gnt_alu = '{default: '0};
        early_tag_bus = '{default: '0};
        tick();
    endtask

    // ==============================================================
    // TEST 1: 1 mult + 1 ALU ready simultaneously
    //   - Dispatch 2 ALU (t1/t2 not ready)
    //   - Then dispatch 1 mult (both ready)
    //   - Wakeup the 2 ALUs via ETB at same time mult arrives
    //   - Expect: mult → pack[0], one ALU → pack[2]
    // ==============================================================
    task automatic test1_1mult_1alu();
        $display("\n[TEST1] 1 mult + 1 ALU issue in same cycle");

        // Cycle 1: dispatch 2 ALU (not ready)
        dispatch_pack[0] = make_alu(PRF_IDX'(12), PRF_IDX'(13), 0, 1, 32'h1000);
        dispatch_pack[1] = make_alu(PRF_IDX'(14), PRF_IDX'(15), 1, 0, 32'h1004);
        rob_index[0] = ROB_IDX'(3); rob_index[1] = ROB_IDX'(4);
        tick();
        display_rs_table("after dispatch 2 ALU");

        // Cycle 2: dispatch 1 mult (both ready) + wakeup the ALU ops via ETB
        dispatch_pack[0] = make_mult(PRF_IDX'(16), PRF_IDX'(17), 1, 1, 32'h2000);
        dispatch_pack[1] = '0;
        rob_index[0]     = ROB_IDX'(5);
        cdb_gnt_alu[0] = 1; cdb_gnt_alu[1] = 1;
        early_tag_bus[0].valid = 1; early_tag_bus[0].tag = PRF_IDX'(12);
        early_tag_bus[1].valid = 1; early_tag_bus[1].tag = PRF_IDX'(15);
        tick();

        dispatch_pack = '{default: '0};
        early_tag_bus = '{default: '0};
        cdb_gnt_alu   = '{default: '0};
        display_rs_table("after mult dispatch + ETB wakeup");

        // Mult should go to issue_pack[0]
        assert (issue_pack[`IP_MULT].valid && issue_pack[`IP_MULT].mult)
            else $error("TEST1 FAIL: mult not in issue_pack[0]");
        // At least one ALU should issue (slot 2 or 3)
        assert (issue_pack[`IP_ALU0].valid || issue_pack[`IP_ALU1].valid)
            else $error("TEST1 FAIL: expected ≥1 ALU issue");
        $display("  PASS test1");
        tick();
    endtask

    // ==============================================================
    // TEST 2: 2 ALU ops issued in the same cycle (ISSUE_2_ALU)
    // ==============================================================
    task automatic test2_2alu();
        $display("\n[TEST2] 2 ALU ops issue simultaneously");

        dispatch_pack[0] = make_alu(PRF_IDX'(12), PRF_IDX'(13), 0, 1, 32'h1000);
        dispatch_pack[1] = make_alu(PRF_IDX'(14), PRF_IDX'(15), 1, 0, 32'h1004);
        rob_index[0] = ROB_IDX'(3); rob_index[1] = ROB_IDX'(4);
        tick();
        dispatch_pack = '{default: '0};

        // Wakeup both, grant both ALU CDB slots
        cdb_gnt_alu[0] = 1; cdb_gnt_alu[1] = 1;
        early_tag_bus[0].valid = 1; early_tag_bus[0].tag = PRF_IDX'(12);
        early_tag_bus[1].valid = 1; early_tag_bus[1].tag = PRF_IDX'(15);
        tick();
        early_tag_bus = '{default: '0};
        cdb_gnt_alu   = '{default: '0};
        display_rs_table("after 2 ALU wakeup");

        // Both ALU slots should fire (pack[2] and pack[3])
        assert (issue_pack[`IP_ALU0].valid)
            else $error("TEST2 FAIL: issue_pack[ALU0] not valid");
        assert (issue_pack[`IP_ALU1].valid)
            else $error("TEST2 FAIL: issue_pack[ALU1] not valid");
        // Mult slot should be empty
        assert (!issue_pack[`IP_MULT].valid)
            else $error("TEST2 FAIL: mult slot spuriously issued");
        $display("  PASS test2");
        tick();
    endtask

    // ==============================================================
    // TEST 3: Mispredict kills entries whose bmask intersects
    // ==============================================================
    task automatic test3_mispredict_kills_matching_bmask();
        $display("\n[TEST3] mispredict kills younger entries");

        // inst A: behind branch bit 0 (will be killed)
        dispatch_pack[0] = make_alu(PRF_IDX'(10), PRF_IDX'(11), 0, 0, 32'h2000, bm_onehot(0));
        // inst B: behind branch bit 1 (should survive)
        dispatch_pack[1] = make_alu(PRF_IDX'(12), PRF_IDX'(13), 0, 0, 32'h3000, bm_onehot(1));
        rob_index[0] = ROB_IDX'(1); rob_index[1] = ROB_IDX'(2);
        tick();
        dispatch_pack = '{default: '0};

        display_rs_table("after dispatch (2 entries)");
        assert (count_busy_rs() == 2) else $error("TEST3 FAIL: expected 2 busy entries");

        // Mispredict branch bit 0: kills inst A, inst B survives
        mispredicted             = 1;
        mispredicted_bmask_index = bm_onehot(0);
        tick();
        mispredicted             = 0;
        mispredicted_bmask_index = '0;

        display_rs_table("after mispredict(bit0)");
        assert (count_busy_rs() == 1)
            else $error("TEST3 FAIL: expected 1 busy entry after mispredict, got %0d", count_busy_rs());
        // The surviving entry should have bmask[1]=1 (inst B at PC=0x3000)
        begin
            bit found = 0;
            for (int i = 0; i < `RS_SZ; i++) begin
                if (dut.rs_entry[i].busy && dut.rs_entry[i].PC == 32'h3000) found = 1;
            end
            assert (found) else $error("TEST3 FAIL: surviving inst B (PC=0x3000) not found");
        end
        $display("  PASS test3");
        tick();
    endtask

    // ==============================================================
    // TEST 4: Branch resolve clears bmask bit (entry survives, mask shrinks)
    // ==============================================================
    task automatic test4_branch_resolve();
        $display("\n[TEST4] bmask bit cleared on branch resolve");

        dispatch_pack[0] = make_alu(PRF_IDX'(10), PRF_IDX'(11), 0, 0, 32'h2000, bm_onehot(0));
        dispatch_pack[1] = make_alu(PRF_IDX'(12), PRF_IDX'(13), 0, 0, 32'h3000, bm_onehot(0) | bm_onehot(1));
        rob_index[0] = ROB_IDX'(1); rob_index[1] = ROB_IDX'(2);
        tick();
        dispatch_pack = '{default: '0};

        // Resolve branch bit 0 → both entries' bmask[0] cleared, still alive
        resolved             = 1;
        resolved_bmask_index = bm_onehot(0);
        tick();
        resolved = 0;

        display_rs_table("after resolve(bit0)");
        assert (count_busy_rs() == 2)
            else $error("TEST4 FAIL: expected 2 entries still busy after resolve");
        // inst B's bmask should now only have bit 1
        begin
            bit ok = 0;
            for (int i = 0; i < `RS_SZ; i++) begin
                if (dut.rs_entry[i].busy && dut.rs_entry[i].PC == 32'h3000) begin
                    ok = (dut.rs_entry[i].bmask == bm_onehot(1));
                end
            end
            assert (ok) else $error("TEST4 FAIL: inst B bmask not correctly masked after resolve");
        end
        $display("  PASS test4");
        tick();
    endtask

    // ==============================================================
    // TEST 5: RS fills up — rs_empty_entries_num reflects occupancy
    // ==============================================================
    task automatic test5_fill_rs();
        $display("\n[TEST5] fill RS, check rs_empty_entries_num");
        int dispatched = 0;
        // Fill RS with RS_SZ/2 pairs of ALU (not ready)
        for (int i = 0; i < `RS_SZ / 2; i++) begin
            dispatch_pack[0] = make_alu(PRF_IDX'(1), PRF_IDX'(2), 0, 0, ADDR'(32'h1000 + i*4));
            dispatch_pack[1] = make_alu(PRF_IDX'(3), PRF_IDX'(4), 0, 0, ADDR'(32'h2000 + i*4));
            rob_index[0] = ROB_IDX'(i*2); rob_index[1] = ROB_IDX'(i*2+1);
            tick();
            dispatched += 2;
            if (dispatched >= `RS_SZ) break;
        end
        dispatch_pack = '{default: '0};
        tick();

        display_rs_table("RS full");
        assert (count_busy_rs() == `RS_SZ)
            else $error("TEST5 FAIL: RS not full, busy=%0d", count_busy_rs());
        // rs_empty_entries_num should be 0 (no free slots ≥ 2)
        assert (rs_empty_entries_num == 2'd0)
            else $error("TEST5 FAIL: rs_empty_entries_num=%0d expected 0", rs_empty_entries_num);
        $display("  PASS test5");
    endtask

    initial begin
        reset_dut();
        test0_smoke_wakeup();

        reset_dut();
        test1_1mult_1alu();

        reset_dut();
        test2_2alu();

        reset_dut();
        test3_mispredict_kills_matching_bmask();

        reset_dut();
        test4_branch_resolve();

        reset_dut();
        test5_fill_rs();

        $display("\n@@@ Passed");
        $finish;
    end

endmodule
