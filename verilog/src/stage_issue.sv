`include "sys_defs.svh"
module stage_issue(
    //from rs
    input D_S_PACKET                        issue_pack                    [5:0] ,
    //from prf
    input DATA          [5:0]               rs1_value                           ,
    input DATA          [5:0]               rs2_value                           ,
    //For branch resolve
    input logic                             resolved                            ,
    input B_MASK                            resolved_bmask_index                , 
    

    output S_X_PACKET                       next_s_x_pack               [5:0]
);

////////////make sure not to latch a valid on mispredict on the top level module (CPU) and the register file is BYPASS_EN = 1
   
    always_comb begin 
        for (int i = 0; i < 'd6; i++)begin
            next_s_x_pack[i].valid = issue_pack[i].valid;
            next_s_x_pack[i].inst = issue_pack[i].inst;
            next_s_x_pack[i].PC = issue_pack[i].PC;
            next_s_x_pack[i].NPC = issue_pack[i].NPC;
            next_s_x_pack[i].opa_select = issue_pack[i].opa_select;
            next_s_x_pack[i].opb_select = issue_pack[i].opb_select;
            next_s_x_pack[i].has_dest = issue_pack[i].has_dest;
            next_s_x_pack[i].alu_func = issue_pack[i].alu_func;
            next_s_x_pack[i].mult = issue_pack[i].mult;
            next_s_x_pack[i].rd_mem = issue_pack[i].rd_mem;
            next_s_x_pack[i].wr_mem = issue_pack[i].wr_mem;
            next_s_x_pack[i].cond_branch = issue_pack[i].cond_branch;
            next_s_x_pack[i].jalr = issue_pack[i].jalr;
            next_s_x_pack[i].jal = issue_pack[i].jal;
            next_s_x_pack[i].csr_op = issue_pack[i].csr_op;
            next_s_x_pack[i].halt = issue_pack[i].halt;
            next_s_x_pack[i].illegal = issue_pack[i].illegal;
            next_s_x_pack[i].bmask_index = issue_pack[i].bmask_index;
            next_s_x_pack[i].bmask = issue_pack[i].bmask;
            next_s_x_pack[i].rob_index = issue_pack[i].rob_index;
            next_s_x_pack[i].T = issue_pack[i].T;
            next_s_x_pack[i].t1 = issue_pack[i].t1;
            next_s_x_pack[i].t2 = issue_pack[i].t2;
            next_s_x_pack[i].rs1_value = rs1_value[i];
            next_s_x_pack[i].rs2_value = rs2_value[i];
            next_s_x_pack[i].predict_taken = issue_pack[i].predict_taken;
            next_s_x_pack[i].predict_addr = issue_pack[i].predict_addr;  
            next_s_x_pack[i].c_type = issue_pack[i].c_type;
            next_s_x_pack[i].current_count = issue_pack[i].current_count;
            next_s_x_pack[i].current_head = issue_pack[i].current_head;   
            next_s_x_pack[i].sq_index = issue_pack[i].sq_index;
            next_s_x_pack[i].lq_index = issue_pack[i].lq_index;
        end

        if (resolved) begin
                for (int i = 0; i < `N + 1; i++) begin
                    if (next_s_x_pack[i].valid) begin
                        next_s_x_pack[i].bmask = next_s_x_pack[i].bmask & ~(resolved_bmask_index);
                    end
                end
            end
    end

endmodule