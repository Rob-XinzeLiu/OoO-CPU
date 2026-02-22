`include "sys_defs.svh"
module execute_stage(
    input logic                             clock                               , 
    input logic                             reset                               , 
    input S_X_PACKET                        s_x_pack                    [`N-1:0],
    //For branch resolve
    input logic                             resolved                            ,
    input X_C_PACKET                        resolved_bmask_index                ,
    //For branch mispredict
    input logic                             mispredicted                        ,
    input B_MASK                            mispredicted_bmask_index            , 
    
    output X_C_PACKET                       x_c_pack                            ,
);
endmodule