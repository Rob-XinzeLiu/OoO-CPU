`include "sys_defs.svh"
`timescale 1ns/100ps

module testbench;

    logic               clock, reset;
    logic               [`N-1:0][`MT_SIZE-1:0] mt_snapshot_in;
    logic               resolved;
    B_MASK              resolved_bmask_index;
    logic               mispredicted;
    B_MASK              mispredicted_idx;
    FLIST_IDX           tail_ptr_in     [`N-1:0];
    logic               [`N-1:0] branch_encountered;
    B_MASK              branch_idx      [`N-1:0];
    ROB_IDX             rob_tail_in     [`N-1:0];
    LQ_IDX              lq_tail_in      [`N-1:0];
    SQ_IDX              sq_tail_in      [`N-1:0];

    logic               [`MT_SIZE-1:0] mt_snapshot_out;
    FLIST_IDX           tail_ptr_out;
    ROB_IDX             rob_tail_out;
    logic               [1:0] branch_stack_space_avail;
    LQ_IDX              lq_tail_out;
    SQ_IDX              sq_tail_out;

    branch_stack dut (
        .clock(clock), .reset(reset),
        .mt_snapshot_in(mt_snapshot_in),
        .resolved(resolved), .resolved_bmask_index(resolved_bmask_index),
        .mispredicted(mispredicted), .mispredicted_idx(mispredicted_idx),
        .tail_ptr_in(tail_ptr_in), .branch_encountered(branch_encountered),
        .branch_idx(branch_idx),
        .rob_tail_in(rob_tail_in), .lq_tail_in(lq_tail_in), .sq_tail_in(sq_tail_in),
        .mt_snapshot_out(mt_snapshot_out),
        .tail_ptr_out(tail_ptr_out), .rob_tail_out(rob_tail_out),
        .branch_stack_space_avail(branch_stack_space_avail),
        .lq_tail_out(lq_tail_out), .sq_tail_out(sq_tail_out)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;
    int test_failed = 0;
    int test_num    = 0;

    task automatic reset_dut();
        clock = 0; reset = 1;
        mt_snapshot_in    = '{default: '0};
        resolved          = 0; resolved_bmask_index  = '0;
        mispredicted      = 0; mispredicted_idx      = '0;
        tail_ptr_in       = '{default: '0};
        branch_encountered = '0;
        branch_idx        = '{default: '0};
        rob_tail_in       = '{default: '0};
        lq_tail_in        = '{default: '0};
        sq_tail_in        = '{default: '0};
        @(negedge clock); reset = 0;
        @(negedge clock);
    endtask

    task automatic check(input string msg, input logic cond);
        if (!cond) begin
            $display("  FAIL [T%0d]: %s", test_num, msg);
            test_failed++;
        end
    endtask

    task automatic idle();
        mt_snapshot_in    = '{default: '0};
        resolved          = 0; resolved_bmask_index  = '0;
        mispredicted      = 0; mispredicted_idx      = '0;
        tail_ptr_in       = '{default: '0};
        branch_encountered = '0;
        branch_idx        = '{default: '0};
        rob_tail_in       = '{default: '0};
        lq_tail_in        = '{default: '0};
        sq_tail_in        = '{default: '0};
    endtask

    // Push one branch on slot i, with given checkpoint info
    task automatic push_branch(
        input int         slot,
        input B_MASK      bidx,
        input FLIST_IDX   fl_tail,
        input ROB_IDX     rob_tail,
        input LQ_IDX      lq_tail,
        input SQ_IDX      sq_tail,
        input logic       [`MT_SIZE-1:0] snap
    );
        idle();
        branch_encountered[slot] = 1;
        branch_idx[slot]         = bidx;
        tail_ptr_in[slot]        = fl_tail;
        rob_tail_in[slot]        = rob_tail;
        lq_tail_in[slot]         = lq_tail;
        sq_tail_in[slot]         = sq_tail;
        mt_snapshot_in[slot]     = snap;
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T1: After reset — stack empty, space_avail = 2
    // ---------------------------------------------------------------
    task automatic t1_reset();
        test_num = 1;
        $display("T1: Reset — stack empty, space_avail=2");
        #1;
        check("space_avail=2 after reset", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T2: Push one branch — checkpoint stored, space_avail still 2
    //     (8 slots, only 1 used → still ≥2 free)
    // ---------------------------------------------------------------
    task automatic t2_push_one();
        test_num = 2;
        $display("T2: Push one branch, verify checkpoint");
        @(negedge clock);
        // branch A: bmask=8'h01, fl_tail=5, rob=3, lq=1, sq=2, mt=0xAB...
        logic [`MT_SIZE-1:0] snap_a;
        snap_a = `MT_SIZE'hDEAD_BEEF;
        push_branch(0, 8'h01, FLIST_IDX'(5), ROB_IDX'(3), LQ_IDX'(1), SQ_IDX'(2), snap_a);
        #1;
        check("space_avail=2 with 1 of 8 used", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T3: Resolve branch A — popped, space_avail remains 2
    // ---------------------------------------------------------------
    task automatic t3_resolve();
        test_num = 3;
        $display("T3: Resolve branch A — popped from stack");
        @(negedge clock);
        idle();
        resolved = 1; resolved_bmask_index = 8'h01;
        @(negedge clock);
        idle();
        #1;
        check("space_avail=2 after resolve+pop", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T4: Push two branches, mispredict the first, verify restoration
    //     Stack: [branch_B (older), branch_C (younger)]
    //     Mispredict B → restore B's checkpoint, squash C
    // ---------------------------------------------------------------
    task automatic t4_mispredict_recovery();
        test_num = 4;
        $display("T4: Mispredict older branch, restore checkpoint, squash younger");
        // Push branch B
        logic [`MT_SIZE-1:0] snap_b, snap_c;
        snap_b = `MT_SIZE'hBEEF_1234;
        snap_c = `MT_SIZE'hCAFE_5678;
        push_branch(0, 8'h02, FLIST_IDX'(10), ROB_IDX'(5), LQ_IDX'(2), SQ_IDX'(3), snap_b);
        // Push branch C
        push_branch(0, 8'h04, FLIST_IDX'(15), ROB_IDX'(8), LQ_IDX'(4), SQ_IDX'(5), snap_c);

        @(negedge clock);
        // Mispredict B (8'h02) → restore its checkpoint, squash C
        idle();
        mispredicted = 1; mispredicted_idx = 8'h02;
        #1;
        // mt_snapshot_out, tail_ptr_out, rob_tail_out, lq/sq_tail_out are combinational
        check("mt restored to snap_b",       mt_snapshot_out == snap_b);
        check("fl_tail restored to 10",      tail_ptr_out    == FLIST_IDX'(10));
        check("rob_tail restored to 5",      rob_tail_out    == ROB_IDX'(5));
        check("lq_tail restored to 2",       lq_tail_out     == LQ_IDX'(2));
        check("sq_tail restored to 3",       sq_tail_out     == SQ_IDX'(3));
        @(negedge clock);
        idle();
        // After squash, stack should be empty → space_avail=2
        #1;
        check("space_avail=2 after squash", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T5: Dual dispatch — push two branches in one cycle
    // ---------------------------------------------------------------
    task automatic t5_dual_push();
        test_num = 5;
        $display("T5: Dual dispatch — two branches pushed in one cycle");
        @(negedge clock);
        idle();
        branch_encountered = 2'b11;
        branch_idx[0]     = 8'h08; tail_ptr_in[0] = FLIST_IDX'(20); rob_tail_in[0] = ROB_IDX'(10);
        branch_idx[1]     = 8'h10; tail_ptr_in[1] = FLIST_IDX'(25); rob_tail_in[1] = ROB_IDX'(15);
        mt_snapshot_in[0] = `MT_SIZE'hAAAA_AAAA;
        mt_snapshot_in[1] = `MT_SIZE'hBBBB_BBBB;
        lq_tail_in = '{default: '0}; sq_tail_in = '{default: '0};
        @(negedge clock);
        idle();
        // Two branches in stack → stack_ptr=2, still ≥2 free (8-2=6)
        #1;
        check("space_avail=2 with 2 of 8 used", branch_stack_space_avail == 2'd2);

        // Resolve older one (8'h08): still one left in stack
        resolved = 1; resolved_bmask_index = 8'h08;
        @(negedge clock);
        idle();
        // Mispredict younger (8'h10): restore its checkpoint
        @(negedge clock);
        mispredicted = 1; mispredicted_idx = 8'h10;
        #1;
        check("mt restored to snap[1]", mt_snapshot_out == `MT_SIZE'hBBBB_BBBB);
        check("fl_tail = 25",           tail_ptr_out    == FLIST_IDX'(25));
        check("rob_tail = 15",          rob_tail_out    == ROB_IDX'(15));
        @(negedge clock);
        idle();
        #1;
        check("stack empty after mispredict", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T6: Stack fills to 7 (space_avail=1) then 8 (space_avail=0)
    // ---------------------------------------------------------------
    task automatic t6_stack_full();
        test_num = 6;
        $display("T6: Fill stack to near-full and full");
        // Push 7 branches (bmask 8'h01 .. 8'h40)
        for (int i = 0; i < 7; i++) begin
            push_branch(0, B_MASK'(1 << i), FLIST_IDX'(i), ROB_IDX'(i), LQ_IDX'(0), SQ_IDX'(0), '0);
        end
        #1;
        check("space_avail=1 with 7 of 8 used", branch_stack_space_avail == 2'd1);
        // Push 8th
        push_branch(0, B_MASK'(8'h80), FLIST_IDX'(7), ROB_IDX'(7), LQ_IDX'(0), SQ_IDX'(0), '0);
        #1;
        check("space_avail=0 with 8 of 8 used", branch_stack_space_avail == 2'd0);
        // Resolve oldest (8'h01) → stack_ptr drops to 7
        @(negedge clock);
        idle();
        resolved = 1; resolved_bmask_index = 8'h01;
        @(negedge clock);
        idle();
        #1;
        check("space_avail=1 after one resolve", branch_stack_space_avail == 2'd1);
        // Flush remaining via mispredict on 8'h02
        @(negedge clock);
        mispredicted = 1; mispredicted_idx = 8'h02;
        @(negedge clock);
        idle();
        #1;
        check("space_avail=2 after flush", branch_stack_space_avail == 2'd2);
    endtask

    // ---------------------------------------------------------------
    // T7: Resolve and push in same cycle (common pipelined scenario)
    // ---------------------------------------------------------------
    task automatic t7_resolve_and_push_same_cycle();
        test_num = 7;
        $display("T7: Resolve and push new branch in same cycle");
        // Pre-condition: stack is empty
        // Push branch D
        push_branch(0, 8'h01, FLIST_IDX'(30), ROB_IDX'(20), LQ_IDX'(5), SQ_IDX'(6), `MT_SIZE'hDDDD);
        @(negedge clock);
        // Simultaneously resolve D and push E
        idle();
        resolved = 1; resolved_bmask_index = 8'h01;
        branch_encountered[0] = 1; branch_idx[0] = 8'h02;
        tail_ptr_in[0] = FLIST_IDX'(31); rob_tail_in[0] = ROB_IDX'(21);
        mt_snapshot_in[0] = `MT_SIZE'hEEEE;
        @(negedge clock);
        idle();
        // D resolved and popped; E remains; one entry in stack
        #1;
        check("space_avail=2 (E in stack, 7 free)", branch_stack_space_avail == 2'd2);
        // Mispredict E to clean up
        @(negedge clock);
        mispredicted = 1; mispredicted_idx = 8'h02;
        @(negedge clock);
        idle();
    endtask

    initial begin
        reset_dut();
        t1_reset();
        t2_push_one();
        t3_resolve();
        t4_mispredict_recovery();
        t5_dual_push();
        t6_stack_full();
        t7_resolve_and_push_same_cycle();
        if (test_failed == 0)
            $display("@@@ Passed");
        else
            $display("@@@ Failed (%0d checks failed)", test_failed);
        $finish;
    end

endmodule
