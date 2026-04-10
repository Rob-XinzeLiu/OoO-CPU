`include "sys_defs.svh"
`include "ISA.svh"
module branch_stack (
    input logic                                         clock                            ,
    input logic                                         reset                            ,
    input logic [`N-1:0][`MT_SIZE-1:0]                          mt_snapshot_in           ,   //from maptable inside dispatch stage
    input logic                                         resolved                         ,
    input B_MASK                                        resolved_bmask_index             ,
    input logic                                         mispredicted                     ,   //from execute stage
    input B_MASK                                        mispredicted_idx                 ,   //from execute stage
    input FLIST_IDX                                     tail_ptr_in              [`N-1:0],   //from freelist
    input logic                [`N-1:0]                          branch_encountered      ,   //from dispatch stage
    input B_MASK                                        branch_idx               [`N-1:0],   //from dispatch stage    
    input ROB_IDX                                       rob_tail_in             [`N-1:0],   //from rob  
    input LQ_IDX                                        lq_tail_in              [`N-1:0],   //from lq
    input SQ_IDX                                        sq_tail_in              [`N-1:0],   //from sq                  
    
    output logic [`MT_SIZE-1:0]                         mt_snapshot_out                  ,   //to maptable
    output FLIST_IDX                                    tail_ptr_out                     ,   //to freelist
    output ROB_IDX                                      rob_tail_out                    ,   //to rob
    output logic [1:0]                                  branch_stack_space_avail         ,   //to dispatch stage
    output LQ_IDX                                       lq_tail_out                     ,   //to lq
    output SQ_IDX                                       sq_tail_out                         //to sq
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

    BSTACK_CNT   stack_ptr, stack_ptr_next, stack_ptr_temp1, stack_ptr_temp2;//always point to the top of the stack
    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////  Combinational Logic    ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    logic [1:0] first_not_resolved;

    always_comb begin
        //default
        first_not_resolved = 'd0;
        stack_ptr_next = stack_ptr;
        stack_ptr_temp1 = stack_ptr;
        stack_ptr_temp2 = stack_ptr;
        stack_next = stack; 
        mt_snapshot_out = '0;
        tail_ptr_out     = '0;
        rob_tail_out = '0;
        sq_tail_out = '0;
        lq_tail_out = '0;
        
        //step 1 : mark as resolved
        if(resolved) begin
            for(int i = 0; i < stack_ptr; i++) begin
                if(|(stack_next[i].branch_idx & resolved_bmask_index)) begin
                    stack_next[i].resolved = 1'b1;
                end
            end
        end

        //step 2 : mispredict logic

        if(mispredicted) begin
            for(int i = 0; i < stack_ptr; i++) begin
                if(stack_next[i].branch_idx == mispredicted_idx) begin
                    mt_snapshot_out = stack[i].maptable;
                    tail_ptr_out    = stack[i].freelist_tail_idx;
                    rob_tail_out   = stack[i].rob_tail;
                    lq_tail_out    = stack[i].lq_tail;
                    sq_tail_out    = stack[i].sq_tail;
                    stack_ptr_temp1  = i;
                end
            end

            //clear all the younger entries
            for (int i = 0; i < stack_ptr; i++) begin
                if(i >= stack_ptr_temp1 + 1) begin
                    stack_next[i].resolved = '0; 
                end
            end
            stack_ptr_next = stack_ptr_temp1; //point to the next free entry
        end

        //step 3 : pop logic 
        for(int i = 0; i < stack_ptr_next+1; i++)begin
            if(!stack_next[i].resolved) begin
                first_not_resolved = i;
                break;
            end
        end
        
        if(first_not_resolved != 0) begin
            stack_ptr_next = stack_ptr_next - first_not_resolved; //pop all the resolved entries
            for(int i = 0; i<`BRANCH_STACK_DEPTH; i++)begin
                if(i >= first_not_resolved) begin
                    stack_next[i-first_not_resolved] = stack_next[i];
                    stack_next[i] = '0;
                end
            end
        end 
    
        //step 4 : enqueue logic
        if (!mispredicted) begin
            stack_ptr_temp2 = stack_ptr_next;
            for(int i = 0; i < `N; i++) begin
                if(branch_encountered[i]) begin
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
        
        branch_stack_space_avail = (`BRANCH_STACK_DEPTH - stack_ptr_next) >= 2 ? 2 : (`BRANCH_STACK_DEPTH - stack_ptr_next) == 1 ? 1 : 0; 
    end

    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////  Sequential Logic       ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock) begin
        if(reset) begin
            stack_ptr <= '0;
            stack <= '{default: '0};
        end else begin
            stack_ptr <= stack_ptr_next;
            stack <= stack_next;
        end
    end
endmodule