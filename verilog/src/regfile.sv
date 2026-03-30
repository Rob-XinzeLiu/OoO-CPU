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
    parameter BYPASS_EN  = 1 // ensure it is only ever 0 or 1
)(
    input         clock, // system clock
    input         reset,
    input PRF_IDX [5:0]    read_idx_1, 
    input PRF_IDX [5:0]    read_idx_2, 
    input PRF_IDX [`N-1:0] write_idx,
    input logic   [`N-1:0] write_en,
    input DATA    [`N-1:0] write_data,

    output DATA   [5:0]    read_out_1, 
    output DATA   [5:0]    read_out_2
);
    // Don't read or write when dealing with register 0
    logic [2:0] re2; 
    logic [2:0] re1;
    logic [1:0] we;

    logic [DEPTH-1:0][WIDTH-1:0]  memData;

    /////////////////////////////
    //                         //
    //      Read Data Logic    //
    //                         //
    /////////////////////////////
    assign re1[0] = !(read_idx_1[0] == `ZERO_REG);
    assign re1[1] = !(read_idx_1[1] == `ZERO_REG);
    assign re1[2] = !(read_idx_1[2] == `ZERO_REG);

    assign re2[0] = !(read_idx_2[0] == `ZERO_REG);
    assign re2[1] = !(read_idx_2[1] == `ZERO_REG);
    assign re2[2] = !(read_idx_2[2] == `ZERO_REG);

    assign we[0]  = write_en[0] && (write_idx[0] != `ZERO_REG);
    assign we[1]  = write_en[1] && (write_idx[1] != `ZERO_REG);

    /////// inst 1 ////////
    wire mux10_0 = BYPASS_EN && we[0] && (read_idx_1[0] == write_idx[0]); //read_idx_1 slot 0 needs write_data 0
    wire mux10_1 = BYPASS_EN && we[1] && (read_idx_1[0] == write_idx[1]); // read_idx_1 slot 0 needs write_data 1

    wire mux20_0 = BYPASS_EN && we[0] && (read_idx_2[0] == write_idx[0]); //read_idx_2 slot 0 needs write_data 0
    wire mux20_1 = BYPASS_EN && we[1] && (read_idx_2[0] == write_idx[1]); // read_idx_2 slot 0 needs write_data 1
    
    /////// inst 2 /////////
    wire mux11_0 = BYPASS_EN && we[0] && (read_idx_1[1] == write_idx[0]); //read_idx_1 slot 1 needs write_data 0
    wire mux11_1 = BYPASS_EN && we[1] && (read_idx_1[1] == write_idx[1]); // read_idx_1 slot 1 needs write_data 1

    wire mux21_0 = BYPASS_EN && we[0] && (read_idx_2[1] == write_idx[0]); //read_idx_2 slot 1 needs write_data 0
    wire mux21_1 = BYPASS_EN && we[1] && (read_idx_2[1] == write_idx[1]); // read_idx_2 slot 1 needs write_data 1
    
    ////// branch inst ////// go in slot 2 always
    wire mux12_0 = BYPASS_EN && we[0] && (read_idx_1[2] == write_idx[0]);
    wire mux12_1 = BYPASS_EN && we[1] && (read_idx_1[2] == write_idx[1]);

    wire mux22_0 = BYPASS_EN && we[0] && (read_idx_2[2] == write_idx[0]);
    wire mux22_1 = BYPASS_EN && we[1] && (read_idx_2[2] == write_idx[1]);


    assign read_out_1[0] = !re1[0] ? '0 :
                            mux10_1 ? write_data[1] :
                            mux10_0 ? write_data[0] :
                            memData [read_idx_1[0]];

    assign read_out_1[1] = !re1[1] ? '0 :
                            mux11_1 ? write_data[1] :
                            mux11_0 ? write_data[0] :
                            memData [read_idx_1[1]];

    assign read_out_1[2] = !re1[2] ? '0 : 
                            mux12_1 ? write_data[1] :
                            mux12_0 ? write_data[0] :
                            memData [read_idx_1[2]];


    assign read_out_2[0] = !re2[0] ? '0 :
                            mux20_1 ? write_data[1] :
                            mux20_0 ? write_data[0] :
                            memData [read_idx_2[0]];

    assign read_out_2[1] = !re2[1] ? '0 :
                            mux21_1 ? write_data[1] :
                            mux21_0 ? write_data[0] :
                            memData [read_idx_2[1]];

    assign read_out_2[2] = !re2[2] ? '0 :
                            mux22_1 ? write_data[1] :
                            mux22_0 ? write_data[0] :
                            memData [read_idx_2[2]];

   

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