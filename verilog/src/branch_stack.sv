`include "sys_defs.svh"
// TODO: redo

module branch_stack (
    input logic                                         clock                            ,
    input logic                                         reset                            ,
    input logic [`MT_SIZE-1:0]                          mt_snapshot_in           [`N-1:0],   //from maptable inside dispatch stage
    input logic                                         resolved                         ,
    input B_MASK                                        resolved_bmask_index             ,
    input logic                                         mispredicted                     ,   //from execute stage
    input B_MASK                                        mispredicted_idx                 ,   //from execute stage
    input logic [`FLIST_SIZE-1:0]                       tail_ptr_in              [`N-1:0],   //from freelist
    input logic                                         branch_encountered       [`N-1:0],   //from dispatch stage
    input B_MASK                                        branch_idx               [`N-1:0],   //from dispatch stage
    input ADDR                                          pc_snapshop_in           [`N-1:0],   //from dispatch stage     
    input ROB_IDX                                       rob_index_in             [`N-1:0],   //from rob                   
    
    output logic [`MT_SIZE-1:0]                         mt_snapshot_out                  ,   //to maptable
    output logic [`FLIST_SIZE-1:0]                      tail_ptr_out                     ,   //to freelist
    output ROB_IDX                                      rob_index_out                    ,   //to rob
    //output logic                                        stack_full                     ,   //to dispatch stage
    //output logic                                      stack_empty                      ,   //to dispatch stage
    output BSTACK_CNT                                   branch_stack_space_avail         ,   //to dispatch stage
    output ADDR                                         pc_snapshot_out                      //to fetch stage
);

    typedef struct packed {
        B_MASK                         branch_idx;
        logic [`MT_SIZE-1:0]           maptable;
        logic [`FLIST_SIZE-1:0]        freelist_tail_idx;
        logic                          resolved;
        ADDR                           pc;
        ROB_IDX                        rob_index;
                  
        //TODO : LSQ
    } checkpoint_t;

    checkpoint_t stack              [`BRANCH_STACK_DEPTH-1:0];
    checkpoint_t stack_next         [`BRANCH_STACK_DEPTH-1:0];

    BSTACK_CNT   stack_ptr, stack_ptr_next, stack_ptr_temp1, stack_ptr_temp2;//always point to the top of the stack
    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////  Combinational Logic    ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    always_comb begin
        //default
        stack_ptr_next = stack_ptr;
        stack_ptr_temp = stack_ptr;
        stack_next = stack; 
        
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
                if(stack_next[i].branch_idx == mispredicted_bmask_index) begin
                    mt_snapshot_out = stack[i].maptable;
                    tail_ptr_out    = stack[i].freelist_tail_idx;
                    rob_index_out   = stack[i].rob_index;
                    pc_snapshot_out = stack[i].pc;
                    stack_ptr_temp1  = i;
                end
            end

            //clear all the younger entries
            for (i = stack_ptr_temp1 + 1; i < stack_ptr; i++) begin
                stack_next[i].resolved = '0; 
            end
            stack_ptr_next = stack_ptr_temp1; //point to the next free entry
            //TODO: LSQ
        end

        //step 3 : pop logic 
        int first_not_resolved = 0;
        for(i = 0; i < stack_ptr_next; i++)begin
            if(!stack_next[i].resolved) begin
                first_not_resolved = i;
                break;
            end
        end
        
        if(first_not_resolved != 0) begin
            stack_ptr_next = stack_ptr_next - first_not_resolved; //pop all the resolved entries
            for(i = first_not_resolved; i<`STACK_DEPTH; i++)begin
                stack_next[i-first_not_resolved] = stack_next[i];
                stack_next[i] = '0;
            end
        end 

        branch_stack_space_avail = `BRANCH_STACK_DEPTH - stack_ptr_next;
    
        //step 4 : enqueue logic
        stack_ptr_temp2 = stack_ptr_next;
        for(i = 0; i<`N; i++)begin
            if(branch_encountered[i]) begin
                stack_next[stack_ptr_temp2].branch_idx = branch_idx[i];
                stack_next[stack_ptr_temp2].maptable = mt_snapshot_in[i];
                stack_next[stack_ptr_temp2].freelist_tail_idx = tail_ptr_in[i];
                stack_next[stack_ptr_temp2].pc = pc_snapshot_in[i];
                stack_next[stack_ptr_temp2].rob_index = rob_index_in[i];
                stack_ptr_temp2 = stack_ptr_temp2 + 1;
                //TODO: LSQ
            end
        end
        stack_ptr_next = stack_ptr_temp2;

        // stack_empty = (stack_ptr_next == 0);
        // stack_full  = (stack_ptr_next == `BRANCH_STACK_DEPTH);
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
            // stack_empty <= 1'b1;
            // stack_full <= 1'b0;
            branch_stack_space_avail <= `BRANCH_STACK_DEPTH;
        end else begin
            stack_ptr <= stack_ptr_next;
            stack <= stack_next;
        end
    end
endmodule