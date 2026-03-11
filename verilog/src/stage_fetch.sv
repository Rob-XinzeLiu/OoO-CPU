/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if (
    input           clock,          // system clock
    input           reset,          // system reset
    input           if_valid,       // only go to next PC when true
    input MEM_BLOCK Imem_data,      // data coming back from Instruction memory
    input MISPREDICT_PACKET mispredict_pack, // mispredict packet from execute stage
    input logic [1:0] fetch_req,//from fetch buffer
    input logic       stop_fetch, // from retire stage, stop fetching new instructions

    output F_D_PACKET if_packet [`N-1:0], // MAKE SURE TO CHANGE DECLARATION IN CPU.SV
    output ADDR         Imem_addr // address sent to Instruction memory
);

    ADDR PC_reg; // PC we are currently fetching
    ADDR PC_increase;
    logic two_valid_insts; // if pc is aligned for a 2 wide fetch
    ADDR mispredict_PC;
    assign mispredict_PC = mispredict_pack.valid ? mispredict_pack.correct_next_pc : PC_reg;

    assign two_valid_insts = (mispredict_PC[2] == 1'b0 && fetch_req == 2); // the pc is 8 byte algined   
    assign PC_increase = two_valid_insts ? ADDR'(8) : (fetch_req == 1) ? ADDR'(4) : ADDR'(0);// did we fetch two valid? progress insts by 8, if not only 4    

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;             // initial PC value is 0 (the memory address where our program starts)
        end else if (if_valid && mispredict_pack.valid) begin
            PC_reg <= mispredict_pack.correct_next_pc + PC_increase; // update to a taken branch (does not depend on valid bit)
        end else if (if_valid && !stop_fetch) begin
            PC_reg <= PC_reg + PC_increase;    // or transition to next PC if valid
        end else begin
            PC_reg <= PC_reg;
        end
    end
    
    // address of the instruction we're fetching (64 bit memory lines)
    // mem always gives us 8=2^3 bytes, so ignore the last 3 bits
    assign Imem_addr = {mispredict_PC[31:3], 3'b0};

    // index into the word (32-bits) of memory that matches this instruction
    assign if_packet[0].inst = (if_valid) ? Imem_data.word_level[mispredict_PC[2]] : `NOP;
    assign if_packet[0].PC  = mispredict_PC;
    assign if_packet[0].NPC = mispredict_PC + 4; // pass PC+4 down pipeline w/instruction
    assign if_packet[0].valid = if_valid && !stop_fetch;
    assign if_packet[0].predict_taken = 1'b0;
    assign if_packet[0].predict_addr = mispredict_PC + 4;

    assign if_packet[1].inst = (if_valid && two_valid_insts) ? Imem_data.word_level[1] : `NOP;
    assign if_packet[1].PC  = mispredict_PC + 4;
    assign if_packet[1].NPC = mispredict_PC + 8; // pass PC+4 down pipeline w/instruction
    assign if_packet[1].valid = if_valid && two_valid_insts && !stop_fetch;
    assign if_packet[1].predict_taken = 1'b0;
    assign if_packet[1].predict_addr = mispredict_PC + 8;

endmodule // stage_if