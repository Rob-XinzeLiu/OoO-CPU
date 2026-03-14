`include "sys_defs.svh"
module rob(
    input logic                 clock                           ,
    input logic                 reset                           ,
    input D_S_PACKET            dispatch_pack           [`N-1:0],
    input logic                 mispredicted                    ,//from execute
    input ROB_IDX               mispredicted_index              ,//from branch stack
    input X_C_PACKET            [`N-1:0]   cdb                  ,//set complete bit
    input COND_BRANCH_PACKET    cond_branch_in                  ,//from execute          

    output RETIRE_PACKET        [`N-1:0] rob_commit             ,//to retire stage
    
    //output logic [1:0]          retire_num                      ,//to retire stage
    output logic [1:0]          rob_space_avail                 ,//to dispatch stage
    output ROB_IDX              rob_index               [`N-1:0] //to rs & branch stack
);

    typedef struct packed {
        PRF_IDX         t;
        PRF_IDX         told;
        logic           ready_retire;//how many inst can we retire per cycle?
        logic           halt;//for tb
        logic           illegal;//for tb
        ADDR            PC;//for debug
        ADDR            NPC;//for debug
        logic           has_dest;//for debug
        REG_IDX         dest_reg_idx;//for debug
        DATA            data;

        //logic is_load;
        //logic is_store;
    } ROB_ENTRY;

    ROB_ENTRY       rob_array           [`ROB_SZ-1:0];
    ROB_ENTRY       next_rob_array      [`ROB_SZ-1:0];
    ROB_IDX         head_ptr, next_head_ptr;
    ROB_IDX         tail_ptr, next_tail_ptr;//tail pointer point to next free slot
    ROB_CNT         rob_count, next_rob_count;//how many entries used
    logic [1:0]   retire_num; //how many instructions can we retire in this cycle

    //output current head ptr to execute stage
    assign          rob_head_ptr_out = head_ptr;

    //dispatch
    logic           dispatch_1, dispatch_2;
    assign          dispatch_1 = (dispatch_pack[0].valid && !dispatch_pack[1].valid);
    assign          dispatch_2 = (dispatch_pack[0].valid && dispatch_pack[1].valid);


    //function for branch recovery
    // function automatic logic is_younger(ROB_IDX current_idx, ROB_IDX head, ROB_IDX tail);
    //     if(head < tail) begin
    //         return current_idx < tail && current_idx >= head;
    //     end else begin
    //         return current_idx >= head || current_idx < tail;
    //     end
    // endfunction
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Combinational Logic    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_comb begin
        //default
        next_head_ptr = head_ptr;
        next_tail_ptr = tail_ptr;
        next_rob_count = rob_count;
        next_rob_array = rob_array;
        rob_commit = '0;
        rob_index = '{default: '0};
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////      Commit(Retire)     ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        retire_num = (rob_array[head_ptr].ready_retire && rob_array[head_ptr + 1 ].ready_retire)? 2 : 
                     (rob_array[head_ptr].ready_retire && !rob_array[head_ptr + 1 ].ready_retire)? 1 : 0;
        

        if(retire_num == 2)begin
            for(int i = 0; i < `N; ++i)begin
                next_rob_array[head_ptr+i].ready_retire = 1'b0;
                rob_commit[i].valid = 1'b1;
                rob_commit[i].halt = rob_array[head_ptr+i].halt;
                rob_commit[i].illegal = rob_array[head_ptr+i].illegal;
                rob_commit[i].PC = rob_array[head_ptr+i].PC;
                rob_commit[i].NPC = rob_array[head_ptr+i].NPC;
                rob_commit[i].has_dest = rob_array[head_ptr+i].has_dest;
                rob_commit[i].dest_reg_idx = rob_array[head_ptr+i].dest_reg_idx;
                rob_commit[i].t_old = rob_array[head_ptr+i].told;
                rob_commit[i].data = rob_array[head_ptr+i].data;

            end
            next_head_ptr = head_ptr + 2;
            next_rob_count = rob_count - 2;

        end else if(retire_num == 1)begin
            rob_commit[0].valid = 1'b1;
            rob_commit[0].halt = rob_array[head_ptr].halt;
            rob_commit[0].illegal = rob_array[head_ptr].illegal;
            rob_commit[0].PC = rob_array[head_ptr].PC;
            rob_commit[0].NPC = rob_array[head_ptr].NPC;
            rob_commit[0].has_dest = rob_array[head_ptr].has_dest;
            rob_commit[0].dest_reg_idx = rob_array[head_ptr].dest_reg_idx;
            rob_commit[0].t_old = rob_array[head_ptr].told;
            rob_commit[0].data = rob_array[head_ptr].data;
            next_head_ptr = head_ptr + 1;
            next_rob_count = rob_count - 1;
            next_rob_array[head_ptr].ready_retire = 1'b0;

        end 

///////////////////////////////////////////////////////////////////////
//////////////////////                          ///////////////////////
//////////////////////          Complete        ///////////////////////
//////////////////////                          ///////////////////////
///////////////////////////////////////////////////////////////////////

        for(int i = 0; i < `N; i++) begin
            if(cdb[i].valid) begin
                next_rob_array[cdb[i].complete_index].ready_retire = 1'b1;
                next_rob_array[cdb[i].complete_index].data = cdb[i].result;
            end
        end

        if(cond_branch_in.valid) begin
                next_rob_array[cond_branch_in.br_rob_idx].ready_retire = 1'b1;
        end

///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Mispredict Recovery    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        if(mispredicted) begin
            next_tail_ptr = mispredicted_index + 1;
            next_rob_count = ROB_CNT'(ROB_IDX'(mispredicted_index - next_head_ptr) + 1'b1) ;
        end

        rob_index[0] = next_tail_ptr;
        rob_index[1] = next_tail_ptr + 1'b1;

///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Enqueue(Dispatch)      ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        if(dispatch_1 && !mispredicted) begin              // Just in case that we dispatch when it's mispredicted
            next_rob_array[tail_ptr].t = dispatch_pack[0].T;
            next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
            next_rob_array[tail_ptr].ready_retire = 1'b0;
            next_rob_array[tail_ptr].halt = dispatch_pack[0].halt;
            next_rob_array[tail_ptr].illegal = dispatch_pack[0].illegal;
            next_rob_array[tail_ptr].PC = dispatch_pack[0].PC;
            next_rob_array[tail_ptr].NPC = dispatch_pack[0].NPC;
            next_rob_array[tail_ptr].has_dest = dispatch_pack[0].has_dest;
            next_rob_array[tail_ptr].dest_reg_idx = dispatch_pack[0].dest_reg_idx;


            next_tail_ptr = tail_ptr + 1;            
            next_rob_count = next_rob_count + 1;
        end else if (dispatch_2 && !mispredicted) begin
            next_rob_array[tail_ptr].t = dispatch_pack[0].T;
            next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
            next_rob_array[tail_ptr].ready_retire = 1'b0;
            next_rob_array[tail_ptr].halt = dispatch_pack[0].halt;
            next_rob_array[tail_ptr].illegal = dispatch_pack[0].illegal;
            next_rob_array[tail_ptr].PC = dispatch_pack[0].PC;
            next_rob_array[tail_ptr].NPC = dispatch_pack[0].NPC;
            next_rob_array[tail_ptr].has_dest = dispatch_pack[0].has_dest;
            next_rob_array[tail_ptr].dest_reg_idx = dispatch_pack[0].dest_reg_idx;            

            next_rob_array[tail_ptr + 1].t = dispatch_pack[1].T;
            next_rob_array[tail_ptr + 1].told = dispatch_pack[1].Told;
            next_rob_array[tail_ptr + 1].ready_retire = 1'b0;
            next_rob_array[tail_ptr + 1].halt = dispatch_pack[1].halt;
            next_rob_array[tail_ptr + 1].illegal = dispatch_pack[1].illegal;
            next_rob_array[tail_ptr + 1].PC = dispatch_pack[1].PC;
            next_rob_array[tail_ptr + 1].NPC = dispatch_pack[1].NPC;
            next_rob_array[tail_ptr + 1].has_dest = dispatch_pack[1].has_dest;
            next_rob_array[tail_ptr + 1].dest_reg_idx = dispatch_pack[1].dest_reg_idx;

            next_tail_ptr = tail_ptr + 2;            
            next_rob_count = next_rob_count + 2;
        end

        rob_space_avail = (`ROB_SZ - next_rob_count >= 2)? 2 :
                          (`ROB_SZ - next_rob_count == 1)? 1 : 0;
    end
    
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Sequential Logic       ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock) begin
        if (reset) begin
           head_ptr <= '0;
           tail_ptr <= '0;
           rob_count <= '0;
           rob_array <= '{default: '0};
        end
        else begin
           head_ptr <= next_head_ptr;
           tail_ptr <= next_tail_ptr;
           rob_count <= next_rob_count;
           rob_array <= next_rob_array;
        end
    end

    
endmodule 