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
    input                           clock,          // system clock
    input                           reset,          // system reset
    input                           if_valid,       // only go to next PC when true
    input logic                     stop_fetch, // from retire stage, stop fetching new instructions     
    input MISPREDICT_PACKET         mispredict_pack, // mispredict packet from execute stage
    input logic [1:0]               fetch_req,//from fetch buffer
    // From icache
    input MEM_BLOCK                 icache_data,      // data coming back from Instruction memory
    input logic                     icache_valid,
    // From predictor
    input logic                     taken,
    input ADDR                      predicted_addr,
    input logic                     btb_slot,
    // Output
    output F_D_PACKET               if_packet [`N-1:0], // MAKE SURE TO CHANGE DECLARATION IN CPU.SV
    // To icache
    output ADDR                     proc2icache_addr // address sent to Instruction memory
);

    ADDR PC_reg; // PC we are currently fetching
    ADDR next_PC;
    ADDR PC_increase;
    logic two_valid_insts; // if pc is aligned for a 2 wide fetch
    assign proc2icache_addr = mispredict_pack.valid ? mispredict_pack.correct_next_pc : PC_reg;
    assign two_valid_insts = (proc2icache_addr[2] == 1'b0 && fetch_req == 2); // the pc is 8 byte algined 

    logic slot0_taken, slot1_taken;
    logic btb_hit_actual_slot0;

    assign btb_hit_actual_slot0 = ((proc2icache_addr[2] == 1'b0 && btb_slot == 1'b0) || (proc2icache_addr[2] == 1'b1 && btb_slot == 1'b1)); //  slot 0 of this cycle predicted taken

    assign slot0_taken = taken && btb_hit_actual_slot0 && icache_valid && !mispredict_pack.valid;
    assign slot1_taken = taken && (btb_slot == 1) && icache_valid && !mispredict_pack.valid && two_valid_insts;

    // ras
    ADDR            return_addr0, return_addr1;
    logic           return_valid0, return_valid1;
    logic [1:0]     current_head;
    logic [2:0]     current_count;

    // Predecode to get ctype
    function automatic CTYPE predecode_ctype(input logic[31:0] inst);
        logic [6:0] opcode = inst[6:0]; 
        unique case(opcode)
            7'b1100011: predecode_ctype = C_BR;
            7'b1101111: predecode_ctype = C_JAL;
            7'b1100111: predecode_ctype = C_JALR;
            default: predecode_ctype = C_NONE;
        endcase
    endfunction

    always_comb begin
        PC_increase = 'd0;
        if(if_valid && icache_valid && !stop_fetch) begin
            if(if_packet[1].valid) begin
                PC_increase = ADDR'(8);
            end else if(if_packet[0].valid) begin
                PC_increase = ADDR'(4);
            end else begin
                PC_increase = '0;
            end
        end
    end

    always_comb begin
        if (mispredict_pack.valid) begin
            next_PC = mispredict_pack.correct_next_pc; 
        end 
        else if (return_valid0 && if_packet[0].valid) begin
            next_PC = return_addr0; 
        end
        else if (slot0_taken && if_packet[0].valid) begin
            next_PC = predicted_addr; 
        end
        else if (return_valid1 && if_packet[1].valid) begin
            next_PC = return_addr1; 
        end
        else if (slot1_taken && if_packet[1].valid) begin
            next_PC = predicted_addr; 
        end
        else begin
            next_PC = proc2icache_addr + PC_increase; 
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;             // initial PC value is 0 (the memory address where our program starts)
        end else begin
            PC_reg <= next_PC;
        end
    end


    // index into the word (32-bits) of memory that matches this instruction
    assign if_packet[0].inst = (icache_valid) ? icache_data.word_level[proc2icache_addr[2]] : `NOP;
    assign if_packet[0].PC  = proc2icache_addr;
    assign if_packet[0].NPC = proc2icache_addr + 4; // pass PC+4 down pipeline w/instruction
    assign if_packet[0].valid = if_valid && !stop_fetch && icache_valid && (fetch_req >= 1);
    assign if_packet[0].predict_taken = (return_valid0 || if_packet[0].c_type == C_JAL)? 1'b1 : slot0_taken;
    assign if_packet[0].predict_addr = (return_valid0)? return_addr0 : (slot0_taken)? predicted_addr : proc2icache_addr + 4;
    assign if_packet[0].c_type = predecode_ctype(if_packet[0].inst);
    assign if_packet[0].current_head = current_head;
    assign if_packet[0].current_count = current_count;

    assign if_packet[1].inst = (icache_valid && two_valid_insts) ? icache_data.word_level[1] : `NOP;
    assign if_packet[1].PC  = proc2icache_addr + 4;
    assign if_packet[1].NPC = proc2icache_addr + 8; // pass PC+4 down pipeline w/instruction
    assign if_packet[1].valid = if_valid && !stop_fetch && icache_valid && two_valid_insts &&
                                    !(if_packet[0].predict_taken) && (if_packet[0].c_type == C_NONE || if_packet[0].c_type == C_BR);
    assign if_packet[1].predict_taken = (return_valid1 || if_packet[1].c_type == C_JAL)? 1'b1 : slot1_taken;
    assign if_packet[1].predict_addr = (return_valid1)? return_addr1 : (slot1_taken)? predicted_addr : proc2icache_addr + 8;
    assign if_packet[1].c_type = predecode_ctype(if_packet[1].inst);
    assign if_packet[1].current_head = current_head;
    assign if_packet[1].current_count = current_count;

    ras ras_0 (
        .clock(clock),
        .reset(reset),
        // Input
        .inst({icache_data.word_level[1], icache_data.word_level[proc2icache_addr[2]]}),
        .npc({proc2icache_addr + 8, proc2icache_addr + 4}),
        .input_valid({if_packet[1].valid && !mispredict_pack.valid, if_packet[0].valid && !mispredict_pack.valid}),
        .mispredict(mispredict_pack.valid),
        .recovered_head(mispredict_pack.current_head),
        .recovered_count(mispredict_pack.current_count),
        // Output
        .return_addr({return_addr1, return_addr0}),
        .valid_addr({return_valid1, return_valid0}),
        .current_head(current_head),
        .current_count(current_count)
    );

endmodule // stage_if