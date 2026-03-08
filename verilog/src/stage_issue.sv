`include "sys_defs.svh"
module stage_issue(
    input logic                             clock                               , 
    input logic                             reset                               , 
    input D_S_PACKET                        issue_pack                    [`N:0],
    //from prf
    input DATA                              rs1_value                     [`N:0],
    input DATA                              rs2_value                     [`N:0],
    //For branch resolve
    input logic                             resolved                            ,
    input B_MASK                            resolved_bmask_index                , 
    //For branch mispredict
    input logic                             mispredicted                        ,
    input B_MASK                            mispredicted_bmask_index            ,
    

    output S_X_PACKET                       next_s_x_pack               [`N:0]
);

////////////make sure not to latch a valid on mispredict on the top level module (CPU) and the register file is BYPASS_EN = 1
    always_comb begin 
        for (int i = 0; i < `N + 1; i++)begin
            next_s_x_pack[i].valid = issue_pack[i].valid;
            next_s_x_pack[i].opa_select = issue_pack[i].opa_select;
            next_s_x_pack[i].opb_select = issue_pack[i].opb_select;
            next_s_x_pack[i].has_dest = issue_pack[i].has_dest;
            next_s_x_pack[i].alu_func = issue_pack[i].alu_func;
            next_s_x_pack[i].mult = issue_pack[i].mult;
            next_s_x_pack[i].rd_mem = issue_pack[i].rd_mem;
            next_s_x_pack[i].wr_mem = issue_pack[i].wr_mem;
            next_s_x_pack[i].cond_branch = issue_pack[i].cond_branch;
            next_s_x_pack[i].uncond_branch = issue_pack[i].uncond_branch;
            next_s_x_pack[i].csr_op = issue_pack[i].csr_op;
            next_s_x_pack[i].halt = issue_pack[i].halt;
            next_s_x_pack[i].illegal = issue_pack[i].illegal;
            next_s_x_pack[i].bmask_index = issue_pack[i].bmask_index;
            next_s_x_pack[i].bmask = issue_pack[i].bmask;
            next_s_x_pack[i].rob_index = issue_pack[i].rob_index;
            next_s_x_pack[i].tag = issue_pack[i].T;
            next_s_x_pack[i].rs1_value = rs1_value[i];
            next_s_x_pack[i].rs2_value = rs2_value[i];
            next_s_x_pack[i].predict_taken = issue_pack[i].predict_taken;
            next_s_x_pack[i].predict_address = issue_pack[i].predict_address;     
        end

        if (resolved && !mispredicted) begin
                for (int i = 0; i < `N + 1; i++) begin
                    if (next_s_x_pack[i].valid) begin
                        next_s_x_pack[i].bmask = next_s_x_pack[i].bmask & ~(resolved_bmask_index);
                    end
                end
            end
    end

endmodule