`include "sys_defs.svh"

module stage_complete(
    input  X_C_PACKET                x_c_packet       [`N-1:0],


    //data for the regfile
    output X_C_PACKET     [`N-1:0]           cdb           ,
    output logic [`N-1:0]            write_en              ,
    output PRF_IDX [`N-1:0]          prf_index             ,
    output DATA  [`N-1:0]            data_for_prf          
);
    always_comb begin 
        cdb = '0;
        write_en = '0;
        prf_index = '0;
        data_for_prf = '0;
        for (int i = 0; i < `N; i++)begin
            if(x_c_packet[i].valid)begin
                write_en[i] = '1;    
                data_for_prf[i] = x_c_packet[i].result;         
                prf_index[i] = x_c_packet[i].complete_tag;
                cdb[i] = x_c_packet[i]; 
            end  
        end    

    end

endmodule