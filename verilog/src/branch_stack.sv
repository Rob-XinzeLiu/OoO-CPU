`include "sys_defs.svh"

module branch_stack (
    input logic                                         clock                            ,
    input logic                                         reset                            ,
    input logic [`MT_SIZE-1:0]                          mt_snapshot_in           [`N-1:0],   //from maptable
    input logic                                         mispredicted                     ,   //from execute stage
    input B_MASK                                        mispredicted_idx                 ,   //from execute stage
    input logic [`FLIST_SIZE-1:0]                       tail_ptr_in              [`N-1:0],   //from freelist
    input logic                                         branch_encountered       [`N-1:0],   //from dispatch stage
    input B_MASK                                        branch_idx               [`N-1:0],   //from dispatch stage
    input X_C_PACKET                                    x_c_pack                 [`N-1:0],   //from execute stage , retire branch stack entry                          
    
    output logic [`MT_SIZE-1:0]                         mt_snapshot_out                  ,   //to maptable
    output logic [`FLIST_SIZE-1:0]                      tail_ptr_out                     ,   //to freelist
    output logic                                        stack_full                       ,   //to dispatch stage
    output logic                                        stack_empty                      ,   //to dispatch stage
    output logic [$clog2(`BRANCH_STACK_DEPTH)-1:0]      space_avail                          //to dispatch stage
);

    typedef struct packed {
        B_MASK                         branch_idx;
        logic [`MT_SIZE-1:0]           maptable;
        logic [`FLIST_SIZE-1:0]        freelist_tail_idx;
        logic                          resolved;
                  
        //TODO : LSQ, PC
    } checkpoint_t;

    checkpoint_t stack              [`BRANCH_STACK_DEPTH-1:0];
    checkpoint_t stack_next         [`BRANCH_STACK_DEPTH-1:0];

    logic [$clog2(`BRANCH_STACK_DEPTH+1)-1:0] stack_ptr, stack_ptr_next, stack_ptr_temp;//always point to the top of the stack
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
        for(i = 0; i<`N; i++)begin
            if(x_c_pack[i].valid  && !x_c_pack[i].mispredicted) begin
                stack_next[x_c_pack[i].bmask_index].resolved = '1; //send branch index to branch stack from execute stage
            end
        end

        //step 2 : mispredict logic
        if(mispredicted) begin
            mt_snapshot_out = stack[mispredicted_idx].maptable;
            tail_ptr_out = stack[mispredicted_idx].freelist_tail_idx;
            //TODO: send LSQ, PC out
            //clear all the younger entries
            for (i = mispredicted_idx + 1; i<`BRANCH_STACK_DEPTH; i++) begin
                stack_next[i].resolved = '0; 
            end
            stack_ptr_next = mispredicted_idx + 1; //point to the next free entry, keep that mispredicted entry
        end

        //step 3 : pop logic 
        int first_not_resolved = 0;
        for(i = 0; i < stack_ptr_next; i++)begin
            if(!stack_next[i].resolved) begin
                first_not_resolved = i;
                break;
            end
        end

        stack_ptr_next = stack_ptr_next - first_not_resolved; //pop all the resolved entries

        for(i = first_not_resolved; i<`STACK_DEPTH; i++)begin
            stack_next[i-first_not_resolved] = stack_next[i];
            stack_next[i] = '0;
        end

        space_avail = `BRANCH_STACK_DEPTH - stack_ptr_next;
    
        //step 4 : enqueue logic
        stack_ptr_temp = stack_ptr_next;
        for(i = 0; i<`N; i++)begin
            if(branch_encountered[i]) begin
                stack_next[stack_ptr_next].branch_idx = branch_idx[i];
                stack_next[stack_ptr_next].maptable = mt_snapshot_in[i];
                stack_next[stack_ptr_next].freelist_tail_idx = tail_ptr_in[i];
                stack_ptr_temp = stack_ptr_temp + 1;
                //TODO: LSQ, PC
            end
        end
        stack_ptr_next = stack_ptr_temp;

        stack_empty = (stack_ptr_next == 0);
        stack_full  = (stack_ptr_next == `BRANCH_STACK_DEPTH);
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
            stack_empty <= 1'b1;
            stack_full <= 1'b0;
            space_avail <= `BRANCH_STACK_DEPTH;
        end else begin
            stack_ptr <= stack_ptr_next;
            stack <= stack_next;
        end
    end
endmodule