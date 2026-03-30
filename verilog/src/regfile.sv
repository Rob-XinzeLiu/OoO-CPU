/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  regfile.sv                                          //
//                                                                     //
//  Description :  This module creates the Regfile used by the ID and  //
//                 WB Stages of the Pipeline.                          //
//                                                                     //
/////////////////////////////////////////////////////////////////////////
`include "sys_defs.svh"
module regfile #(
    parameter WIDTH      = 32,
    parameter DEPTH      = `PHYS_REG_SZ_R10K,
    parameter BYPASS_EN  = 1, // ensure it is only ever 0 or 1
    parameter READ_PORTS  = 6 // number of read ports
)(
    input         clock, // system clock
    input         reset,
    input PRF_IDX [READ_PORTS-1:0]    read_idx_1, 
    input PRF_IDX [READ_PORTS-1:0]    read_idx_2, 
    input PRF_IDX [`N-1:0] write_idx,
    input logic   [`N-1:0] write_en,
    input DATA    [`N-1:0] write_data,

    output DATA   [READ_PORTS-1:0]    read_out_1, 
    output DATA   [READ_PORTS-1:0]    read_out_2
);
    // Don't read or write when dealing with register 0
    logic [READ_PORTS-1:0] re2; 
    logic [READ_PORTS-1:0] re1;
    logic [1:0] we;

    logic [DEPTH-1:0][WIDTH-1:0]  memData;

    /////////////////////////////
    //                         //
    //      Read Data Logic    //
    //                         //
    /////////////////////////////

    genvar g;
    generate
        for(g=0; g < READ_PORTS; g++) begin: GEN_READS
            logic hit1_w0, hit1_w1;
            logic hit2_w0, hit2_w1;

            assign re1[g] = (read_idx_1[g] != `ZERO_REG);
            assign re2[g] = (read_idx_2[g] != `ZERO_REG);

            assign hit1_w0 = BYPASS_EN && we[0] && (read_idx_1[g] == write_idx[0]);
            assign hit1_w1 = BYPASS_EN && we[1] && (read_idx_1[g] == write_idx[1]);

            assign hit2_w0 = BYPASS_EN && we[0] && (read_idx_2[g] == write_idx[0]);
            assign hit2_w1 = BYPASS_EN && we[1] && (read_idx_2[g] == write_idx[1]);

            assign read_out_1[g] = !re1[g] ? '0 :
                                    hit1_w1 ? write_data[1] :
                                    hit1_w0 ? write_data[0] :
                                    memData[read_idx_1[g]];
            assign read_out_2[g] = !re2[g] ? '0 :
                                    hit2_w1 ? write_data[1] :
                                    hit2_w0 ? write_data[0] :
                                    memData[read_idx_2[g]];
         
        end 
    endgenerate

    always_comb begin
        we[0]  = write_en[0] && (write_idx[0] != `ZERO_REG);
        we[1]  = write_en[1] && (write_idx[1] != `ZERO_REG);        
    end

    /////////////////////////////
    //                         //
    //     Write Data Logic    //
    //                         //
    /////////////////////////////
    //no two instructions should be writing to the same location in MR10K
    always_ff @(posedge clock) begin
        if (reset) begin
            memData        <= '0;
        end else begin
            for(int i = 0; i < `N; ++i)begin
                if(we[i]) begin
                    memData[write_idx[i]] <= write_data[i];
                end
            end
        end
    end
endmodule // regfile