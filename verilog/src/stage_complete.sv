`include "sys_defs.svh"

module stage_complete(
    input                            clock                 ,
    input                            reset                 ,
    input  X_C_PACKET                x_c_packet       [1:0],

    input  logic                     branch_mispredicted   , 
    //input  logic                     branch_resolved     ,
    input  B_MASK                     mispred_mask_idx     ,
    //input  BMASK                     res_mask_idx        ,
    //data for the regfile
    output X_C_PACKET     [`N-1:0]           cdb           ,
    output logic [`N-1:0]            write_en              ,
    output PRF_IDX [`N-1:0]          prf_index             ,
    output DATA  [`N-1:0]            data_for_prf          
);
    always_comb begin 

        for (int i = 0; i < `N; i++)begin
            write_en[1] = x_c_packet[i].valid && x_c_packet[i].has_dest;
            if(x_c_packet[i].uncond_branch)begin
                data_for_prf[i] = x_c_packet[i].NPC;
            end else begin
                data_for_prf[i] = x_c_packet[i].result;
            end         
            prf_index[i] = x_c_packet[i].complete_tag;
            cdb[i] = x_c_packet[i];   
        end    

        // if(branch_resolved && !branch_mispredicted)begin
        //     for(int i = 0 ; i < `N; i++)begin
        //         if(cdb[i].valid)begin
        //             cdb[i].bmask = cdb[i].bmask & ~(res_mask_index);
        //         end
        //     end
        // end mis
        if(branch_mispredicted)begin
            for(int i = 0; i < `N; i++)begin
                if (cdb[i].valid && (cdb[i].bmask & mispred_mask_idx)) begin
                    cdb[i]  = '0;
                end
            end
        end
    end

endmodule