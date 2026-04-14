`include "sys_defs.svh"
`include "ISA.svh"
module branch_stack (
    input logic                                         clock                            ,
    input logic                                         reset                            ,
    input logic [`N-1:0][`MT_SIZE-1:0]                          mt_snapshot_in           ,
    input logic                                         resolved                         ,
    input B_MASK                                        resolved_bmask_index             ,
    input logic                                         mispredicted                     ,
    input B_MASK                                        mispredicted_idx                 ,
    input FLIST_IDX                                     tail_ptr_in              [`N-1:0],
    input logic                [`N-1:0]                          branch_encountered      ,
    input B_MASK                                        branch_idx               [`N-1:0],
    input ROB_IDX                                       rob_tail_in             [`N-1:0],
    input LQ_IDX                                        lq_tail_in              [`N-1:0],
    input SQ_IDX                                        sq_tail_in              [`N-1:0],
    
    output logic [`MT_SIZE-1:0]                         mt_snapshot_out                  ,
    output FLIST_IDX                                    tail_ptr_out                     ,
    output ROB_IDX                                      rob_tail_out                    ,
    output logic [1:0]                                  branch_stack_space_avail         ,
    output LQ_IDX                                       lq_tail_out                     ,
    output SQ_IDX                                       sq_tail_out                      
);

    typedef struct packed {
        B_MASK                         branch_idx;
        logic [`MT_SIZE-1:0]           maptable;
        FLIST_IDX              freelist_tail_idx;
        logic                          resolved;
        ROB_IDX                        rob_tail;
        LQ_IDX                          lq_tail;
        SQ_IDX                          sq_tail;
    } checkpoint_t;

    checkpoint_t stack              [`BRANCH_STACK_DEPTH-1:0];
    checkpoint_t stack_next         [`BRANCH_STACK_DEPTH-1:0];

    BSTACK_CNT   stack_ptr, stack_ptr_next, stack_ptr_temp1, stack_ptr_temp2;

    logic found_not_resolved;
    BSTACK_CNT first_not_resolved;

    always_comb begin
        // defaults
        stack_ptr_next     = stack_ptr;
        stack_ptr_temp1    = stack_ptr;
        stack_ptr_temp2    = stack_ptr;
        stack_next         = stack;
        mt_snapshot_out    = '0;
        tail_ptr_out       = '0;
        rob_tail_out       = '0;
        sq_tail_out        = '0;
        lq_tail_out        = '0;
        first_not_resolved = '0;
        found_not_resolved = 1'b0;

        // step 1: mark as resolved
        if (resolved) begin
            for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
                if (i < stack_ptr) begin
                    if (|(stack_next[i].branch_idx & resolved_bmask_index)) begin
                        stack_next[i].resolved = 1'b1;
                    end
                end
            end
        end

        // step 2: mispredict logic
        if (mispredicted) begin
            for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
                if (i < stack_ptr) begin
                    if (stack_next[i].branch_idx == mispredicted_idx) begin
                        mt_snapshot_out  = stack[i].maptable;
                        tail_ptr_out     = stack[i].freelist_tail_idx;
                        rob_tail_out     = stack[i].rob_tail;
                        lq_tail_out      = stack[i].lq_tail;
                        sq_tail_out      = stack[i].sq_tail;
                        stack_ptr_temp1  = BSTACK_CNT'(i);
                    end
                end
            end

            // clear all younger entries
            for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
                if (i >= stack_ptr_temp1 + 1) begin
                    stack_next[i].resolved = '0;
                end
            end
            stack_ptr_next = stack_ptr_temp1;
        end

        // step 3: pop resolved entries from bottom
        for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
            if (i < stack_ptr_next && !found_not_resolved) begin
                if (!stack_next[i].resolved) begin
                    first_not_resolved = BSTACK_CNT'(i);
                    found_not_resolved = 1'b1;
                end
            end
        end

        if (found_not_resolved && first_not_resolved != 0) begin
            stack_ptr_next = stack_ptr_next - first_not_resolved;
            for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
                if (i >= first_not_resolved && i < `BRANCH_STACK_DEPTH) begin
                    stack_next[i - first_not_resolved] = stack_next[i];
                    stack_next[i] = '0;
                end
            end
        end else if (!found_not_resolved) begin
            // all entries are resolved, pop everything
            for (int i = 0; i < `BRANCH_STACK_DEPTH; i++) begin
                stack_next[i] = '0;
            end
            stack_ptr_next = '0;
        end

        // step 4: enqueue new branches
        if (!mispredicted) begin
            stack_ptr_temp2 = stack_ptr_next;
            for (int i = 0; i < `N; i++) begin
                if (branch_encountered[i]) begin
                    stack_next[stack_ptr_temp2].branch_idx        = branch_idx[i];
                    stack_next[stack_ptr_temp2].maptable          = mt_snapshot_in[i];
                    stack_next[stack_ptr_temp2].freelist_tail_idx = tail_ptr_in[i];
                    stack_next[stack_ptr_temp2].rob_tail          = rob_tail_in[i];
                    stack_next[stack_ptr_temp2].lq_tail           = lq_tail_in[i];
                    stack_next[stack_ptr_temp2].sq_tail           = sq_tail_in[i];
                    stack_next[stack_ptr_temp2].resolved          = '0;
                    stack_ptr_temp2 = stack_ptr_temp2 + 1;
                end
            end
            stack_ptr_next = stack_ptr_temp2;
        end

        branch_stack_space_avail = ((`BRANCH_STACK_DEPTH - stack_ptr_next) >= 2) ? 2'd2 :
                                   ((`BRANCH_STACK_DEPTH - stack_ptr_next) == 1) ? 2'd1 : 2'd0;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            stack_ptr <= '0;
            stack     <= '{default: '0};
        end else begin
            stack_ptr <= stack_ptr_next;
            stack     <= stack_next;
        end
    end

endmodule