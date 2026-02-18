`include "sys_defs.svh"

module rs(
    input logic                         clock                  , 
    input logic                         reset                  , 
    input logic                         mispredicted           ,//from execute stage
    input B_MASK                        mispredicted_bmask     ,//from execute stage
    input ROB_IDX                       rob_index      [`N-1:0],//from rob
    input logic [1:0]                   dispatch_num           , //number of instructions dispatched in this cycle
    input D_S_PACKET                    dispatch_pack  [`N-1:0],//from dispatcher
    input X_C_PACKET                    cdb            [`N-1:0],  
    input logic                         resolved               ,
    input B_MASK                        resolved_bmask         ,


    output D_S_PACKET                   issue_pack     [`N-1:0],//to issue stage
    output logic [$clog2(`RS_SZ)-1:0]   empty_entries_num
    
);

    typredef struct packed{
        logic               busy;             
        INST                inst; 
        ADDR                pc;
        ADDR                npc;
        ALU_OPA_SELECT      opa_select;
        ALU_OPB_SELECT      opb_select;
        logic               has_dest;
        ALU_FUNC            alu_func;
        logic               mult;
        logic               rd_mem;
        logic               wr_mem;
        logic               cond_branch;
        logic               uncond_branch;
        logic               csr_op;
        logic               halt;
        logic               illegal;
        B_MASK              bmask_index;
        logic [6:0]         opcode;
        PRF_IDX             t;
        PRF_IDX             t1;
        PRF_IDX             t2;
        logic               t1_ready;
        logic               t2_ready;
        ROB_IDX             rob_index;
        
    } RS_ENTRY;

    RS_ENTRY rs_entry       [`RS_SZ-1:0];
    RS_ENTRY next_rs_entry  [`RS_SZ-1:0];

    logic [`RS_SZ-1:0]      ready_entry_mask;
    logic [`RS_SZ-1:0]      issue_mask;
    logic [`RS_SZ-1:0]      empty_entry_mask, next_empty_entry_mask;//
    logic [`RS_SZ-1:0]      dispatch_mask;

    logic [`RS_SZ-1:0]      dispatch_bus [`N-1:0];
    logic [`RS_SZ-1:0]      issue_bus [`N-1:0];
    logic                   empty_dispatch, empty_issue;

    psel_gen #(.WIDTH(`RS_SZ), .REQS(dispatch_num)) priorty_selector_dispatch(
        .req(empty_entry_mask),
        .gnt(dispatch_mask),
        .gnt_bus(dispatch_bus),
        .empty(empty_dispatch)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS(`N)) priorty_selector_issue(
        .req(ready_entry_mask),
        .gnt(issue_mask),
        .gnt_bus(issue_bus),
        .empty(empty_issue)
    );

    always_comb begin
        //default
        next_rs_entry = rs_entry;
        next_empty_entry_mask = empty_entry_mask;
        ready_entry_mask = '0;

        //update ready bits based on cdb
        if(cdb[0].valid) begin
            for(int j = 0; j < `RS_SZ; j++) begin
                if(rs_entry[j].busy) begin
                    if(rs_entry[j].t1 == cdb[0].complete_tag) begin
                        next_rs_entry[j].t1_ready = 1;
                    end
                    if(rs_entry[j].t2 == cdb[0].complete_tag) begin
                        next_rs_entry[j].t2_ready = 1;
                    end
                end
            end
        end

        if(cdb[1].valid) begin
            for(int j = 0; j < `RS_SZ; j++) begin
                if(rs_entry[j].busy) begin
                    if(rs_entry[j].t1 == cdb[1].complete_tag) begin
                        next_rs_entry[j].t1_ready = 1;
                    end
                    if(rs_entry[j].t2 == cdb[1].complete_tag) begin
                        next_rs_entry[j].t2_ready = 1;
                    end
                end
            end
        end

        //enqueue logic
        if(!empty_dispatch)begin
            for (i=0; i<`RS_SZ; i++)begin
                if(dispatch_bus[0][i]) begin
                    //from dispatch pack 0
                    next_rs_entry[i].inst= dispatch_pack[0].inst;
                    next_rs_entry[i].pc= dispatch_pack[0].pc;
                    next_rs_entry[i].npc= dispatch_pack[0].npc;
                    next_rs_entry[i].opa_select= dispatch_pack[0].opa_select;
                    next_rs_entry[i].opb_select= dispatch_pack[0].opb_select;
                    next_rs_entry[i].has_dest= dispatch_pack[0].has_dest;
                    next_rs_entry[i].alu_func= dispatch_pack[0].alu_func;
                    next_rs_entry[i].mult= dispatch_pack[0].mult;
                    next_rs_entry[i].rd_mem= dispatch_pack[0].rd_mem;
                    next_rs_entry[i].wr_mem= dispatch_pack[0].wr_mem;
                    next_rs_entry[i].cond_branch= dispatch_pack[0].cond_branch;
                    next_rs_entry[i].uncond_branch= dispatch_pack[0].uncond_branch;
                    next_rs_entry[i].csr_op= dispatch_pack[0].csr_op;
                    next_rs_entry[i].halt= dispatch_pack[0].halt;
                    next_rs_entry[i].illegal= dispatch_pack[0].illegal;
                    next_rs_entry[i].bmask_index= dispatch_pack[0].bmask_index;
                    next_rs_entry[i].opcode= dispatch_pack[0].opcode;
                    next_rs_entry[i].t= dispatch_pack[0].t;
                    next_rs_entry[i].t1= dispatch_pack[0].t1;
                    next_rs_entry[i].t2= dispatch_pack[0].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[0].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[0].t2_ready;
                    next_rs_entry[i].busy = 1;
                    //mark as not empty
                    next_empty_entry_mask[i] = 0;
                    //from rob
                    next_rs_entry[i].rob_index = rob_index[0];
                    //update ready bit based on cdb
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end
                end
                if(dispatch_bus[1][i]) begin
                    //from dispatch pack 1
                    next_rs_entry[i].inst= dispatch_pack[1].inst;
                    next_rs_entry[i].pc= dispatch_pack[1].pc;
                    next_rs_entry[i].npc= dispatch_pack[1].npc;
                    next_rs_entry[i].opa_select= dispatch_pack[1].opa_select;
                    next_rs_entry[i].opb_select= dispatch_pack[1].opb_select;
                    next_rs_entry[i].has_dest= dispatch_pack[1].has_dest;
                    next_rs_entry[i].alu_func= dispatch_pack[1].alu_func;
                    next_rs_entry[i].mult= dispatch_pack[1].mult;
                    next_rs_entry[i].rd_mem= dispatch_pack[1].rd_mem;
                    next_rs_entry[i].wr_mem= dispatch_pack[1].wr_mem;
                    next_rs_entry[i].cond_branch= dispatch_pack[1].cond_branch;
                    next_rs_entry[i].uncond_branch= dispatch_pack[1].uncond_branch;
                    next_rs_entry[i].csr_op= dispatch_pack[1].csr_op;
                    next_rs_entry[i].halt= dispatch_pack[1].halt;
                    next_rs_entry[i].illegal= dispatch_pack[1].illegal;
                    next_rs_entry[i].bmask_index= dispatch_pack[1].bmask_index;
                    next_rs_entry[i].opcode= dispatch_pack[1].opcode;
                    next_rs_entry[i].t= dispatch_pack[1].t;
                    next_rs_entry[i].t1= dispatch_pack[1].t1;
                    next_rs_entry[i].t2= dispatch_pack[1].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[1].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[1].t2_ready;
                    next_rs_entry[i].busy = 1;
                    //mark as not empty
                    next_empty_entry_mask[i] = 1;
                    //from rob
                    next_rs_entry[i].rob_index = rob_index[1];
                    //update ready bit based on cdb
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end
                end
            end
        end

        //resolve logic
        if (resolved && !mispredicted) begin
            for (int j = 0; j < RS_SZ; j++) begin
                if (next_rs_entry[j].busy) begin
                    next_rs_entry[j].bmask_index = next_rs_entry[j].bmask_index & ~(resolved_bmask);
                end
            end
        end
        
        //mispredict logic
        if(mispredicted) begin
            for (i = 0; i < `RS_SZ; i++)begin
                if(next_rs_entry[i].busy && (mispredicted_bmask & next_rs_entry[i].bmask_index)) begin
                    next_empty_entry_mask[i] = 1;
                    next_rs_entry[i] = '0;
                end
            end
        end

        //issue and clear 
        for(int j = 0; j < `RS_SZ; j++) begin
            ready_entry_mask[j] = rs_entry[j].busy && rs_entry[j].t1_ready && rs_entry[j].t2_ready;
        end
        if(!empty_issue)begin
            for (i = 0; i<`RS_SZ; i++)begin
                if(issue_bus[0][i]) begin
                    //to issue pack 0
                    issue_pack[0].inst= rs_entry[i].inst;
                    issue_pack[0].pc= rs_entry[i].pc;
                    issue_pack[0].npc= rs_entry[i].npc;
                    issue_pack[0].opa_select= rs_entry[i].opa_select;
                    issue_pack[0].opb_select= rs_entry[i].opb_select;
                    issue_pack[0].has_dest= rs_entry[i].has_dest;
                    issue_pack[0].alu_func= rs_entry[i].alu_func;
                    issue_pack[0].mult= rs_entry[i].mult;
                    issue_pack[0].rd_mem= rs_entry[i].rd_mem;
                    issue_pack[0].wr_mem= rs_entry[i].wr_mem;
                    issue_pack[0].cond_branch= rs_entry[i].cond_branch;
                    issue_pack[0].uncond_branch= rs_entry[i].uncond_branch;
                    issue_pack[0].csr_op= rs_entry[i].csr_op;
                    issue_pack[0].halt= rs_entry[i].halt;
                    issue_pack[0].illegal= rs_entry[i].illegal;
                    issue_pack[0].bmask_index= rs_entry[i].bmask_index;
                    issue_pack[0].opcode= rs_entry[i].opcode;
                    issue_pack[0].t= rs_entry[i].t;
                    issue_pack[0].t1= rs_entry[i].t1;
                    issue_pack[0].t2= rs_entry[i].t2;
                    issue_pack[0].rob_index = rs_entry[i].rob_index;
                    
                    //mark as not busy
                    next_rs_entry[i].busy = 0;
                    //mark as empty
                    next_empty_entry_mask[i] = 1;
                end
                if(issue_bus[1][i]) begin
                    //to issue pack 1
                    issue_pack[1].inst= rs_entry[i].inst;
                    issue_pack[1].pc= rs_entry[i].pc;
                    issue_pack[1].npc= rs_entry[i].npc;
                    issue_pack[1].opa_select= rs_entry[i].opa_select;
                    issue_pack[1].opb_select= rs_entry[i].opb_select;
                    issue_pack[1].has_dest= rs_entry[i].has_dest;
                    issue_pack[1].alu_func= rs_entry[i].alu_func;
                    issue_pack[1].mult= rs_entry[i].mult;
                    issue_pack[1].rd_mem= rs_entry[i].rd_mem;
                    issue_pack[1].wr_mem= rs_entry[i].wr_mem;
                    issue_pack[1].cond_branch= rs_entry[i].cond_branch;
                    issue_pack[1].uncond_branch= rs_entry[i].uncond_branch;
                    issue_pack[1].csr_op= rs_entry[i].csr_op;
                    issue_pack[1].halt= rs_entry[i].halt;
                    issue_pack[1].illegal= rs_entry[i].illegal;
                    issue_pack[1].bmask_index= rs_entry[i].bmask_index;
                    issue_pack[1].opcode= rs_entry[i].opcode;
                    issue_pack[1].t= rs_entry[i].t;
                    issue_pack[1].t1= rs_entry[i].t1;
                    issue_pack[1].t2= rs_entry[i].t2;
                    issue_pack[1].rob_index = rs_entry[i].rob_index;
                
                    //mark as not busy
                    next_rs_entry[i].busy = 0;
                    //mark as empty
                    next_empty_entry_mask[i] = 1;
                end
                //update empty entry count
                if (!next_rs_entry[i].busy) begin
                    empty_entries_num = empty_entries_num + 1;
                end
            end
        end
    end

    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////       sequential logic  ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    always_ff(@posedge clock)begin
        if(reset)begin
            rs_entry <= '{default: '0};
            empty_entry_mask <= '1; //all entries are empty at the beginning
            empty_entries_num <= `RS_SZ;
        end
        else begin
            rs_entry <= next_rs_entry;
            empty_entry_mask <= next_empty_entry_mask;
        end
    end

endmodule