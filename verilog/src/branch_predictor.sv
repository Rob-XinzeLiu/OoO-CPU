`include "sys_defs.svh"
`include "ISA.svh"
module branch_predicotr(
    input                            clock                  ,
    input                            reset                  ,

    //input from fetch stage, to get the current PC value
    input     ADDR                   proc2icache_addr       ,
    //input from execute stage
    input COND_BRANCH_PACKET         conditional_branch_out , 
    input MISPREDICT_PACKET          mispredict_pack    ,  
    //from dispatch stage, early target mispredict
    input MISPREDICT_PACKET          early_mistarget_pack,         

    //output 
    output logic                     taken                  ,
    output ADDR                      PC_taken_addr          ,
    output logic                     btb_slot
);

typedef enum logic [1:0] {
    high_local  = 2'b00,
    low_local    = 2'b01,
    low_global   = 2'b10,
    high_global = 2'b11
} SELECTOR;

typedef enum logic [1:0] {
    high_not_take    = 2'b00,
    low_not_take     = 2'b01,
    low_take         = 2'b10,
    high_take        = 2'b11
} PATTERN;

    //Branch History Table   // predict taken or not taken 
    //we use tornament predictor do both static and dynamic
        
    localparam local_pattern_size = 16;
    localparam local_pattern_index_size = $clog2(local_pattern_size);
    localparam global_pattern_size = 64;
    localparam global_pattern_index_size = $clog2(global_pattern_size);
    localparam local_branch_size = 32;
    localparam local_branch_index_size =$clog2(local_branch_size);
    localparam local_branch_history_size = 4; 
    localparam global_branch_history_size = 6; 

    logic select_pick;

    //update signal
    logic [local_branch_index_size-1:0] update_idx_BHT;
    logic [local_pattern_index_size -1:0] update_idx_PHT;
    logic [global_pattern_index_size - 1:0] update_idx_gPHT;
    PATTERN PHT_update_unit;
    PATTERN gPHT_update_unit;
    logic update_result_local;
    logic update_result_global;
    SELECTOR selector_update_unit;


    ADDR btb_target;


    logic btb_hit;
    CTYPE btb_c_type;

    btb BTB_out (
        .clock(clock),
        .reset(reset),

        //input 
        .lookup_pc(proc2icache_addr),
        //output
        .btb_hit(btb_hit),      
        .btb_target(btb_target),
        .btb_c_type(btb_c_type),    
        .btb_slot(btb_slot),     

        //input update
        .update_valid(mispredict_pack.valid),
        .update_taken(mispredict_pack.take_branch),
        .update_pc(mispredict_pack.current_PC),
        .update_target(mispredict_pack.correct_next_pc),
        .update_c_type(mispredict_pack.c_type),
        .early_update_valid  (early_mistarget_pack.valid && early_mistarget_pack.c_type == C_JAL),//only update for jal
        .early_update_pc     (early_mistarget_pack.current_PC),
        .early_update_target (early_mistarget_pack.correct_next_pc),
        .early_update_c_type (early_mistarget_pack.c_type)
    );

    //local PHT and BHT 


    //'PHT' is local PHT, 'gPHT' is global PHT
    PATTERN PHT[local_pattern_size-1:0],  gPHT[global_pattern_size-1:0];

    //selector follow global pattern size
    SELECTOR selector[global_pattern_size-1:0];

    //-------------------------------------------------------------------------------


    // static  ----- local predictor

    //'BHT' is local BHT, 'gBHT' is global BHT
    //branch history table
    logic [local_branch_history_size -1:0] BHT [local_branch_size-1:0];
    logic [global_branch_history_size -1:0] gBHT;


    //Branch history table  //
    logic [local_branch_index_size-1:0] index_BHT;
    ADDR actual_lookup_pc;
    logic [local_pattern_index_size-1:0] index_PHT;
    logic taken_local;
    assign actual_lookup_pc = {proc2icache_addr[31:3], btb_slot, 2'b00};


    always_comb begin     
        index_BHT = actual_lookup_pc[6:2];
        index_PHT = BHT[index_BHT];
        taken_local = 1'b0;
        if(btb_hit) begin
            taken_local = PHT[index_PHT][1];
        end
    end

    //-------------------------------------------------------------------------------
    // global

    logic taken_global;
    logic [global_pattern_index_size -1:0] index_gPHT;

    always_comb begin
        taken_global = 1'b0;
        index_gPHT = actual_lookup_pc[7:2] ^ gBHT;
        if(btb_hit) begin
            taken_global = gPHT[index_gPHT][1];      
        end
    end

    //--------------------------------------------------------------------------
    //SELECTOR 
    SELECTOR selector_value; 

    always_comb begin
        selector_value = selector[gBHT];
        select_pick = selector_value[1];
    end

    logic pre_taken;
    assign pre_taken = select_pick? taken_global:taken_local;
    assign taken = (btb_hit && (btb_c_type == C_JAL || btb_c_type == C_JALR))? 1'b1 : ((btb_hit && btb_slot >= proc2icache_addr[2])? pre_taken:'0); // ex: PC = 20, but we try to predict PC = 16
    assign PC_taken_addr = (taken && btb_hit)? btb_target : proc2icache_addr + 4;

    ////--------------------------------------update BHT, PHT, gBHT, selector --------//
    always_comb begin
        update_idx_BHT = conditional_branch_out.PC[6:2];    // Find which branch
        update_idx_PHT = BHT[update_idx_BHT];               // Check branch history
        PHT_update_unit = PHT[update_idx_PHT];
        update_idx_gPHT = conditional_branch_out.PC[7:2]^gBHT;
        gPHT_update_unit = gPHT[update_idx_gPHT];
        update_result_global = gPHT_update_unit[1];
        update_result_local = PHT_update_unit[1];
        selector_update_unit = selector[gBHT];
    end

    always_ff @(posedge clock) begin   
        if(reset) begin
            for(int i=0; i < 32; i++) BHT[i] <= '0; 
            for(int i=0; i < 16; i++) PHT[i] <= high_not_take;
            for(int i=0; i < 64; i++) gPHT[i] <= high_not_take;
            for(int i=0; i < 64; i++) selector[i] <= low_local;
            gBHT <= '0;
        end else begin
            if (conditional_branch_out.valid) begin
                case (PHT_update_unit)
                    high_not_take: PHT[update_idx_PHT] <= conditional_branch_out.result? low_not_take:high_not_take;
                    low_not_take:  PHT[update_idx_PHT] <= conditional_branch_out.result? low_take:high_not_take;
                    low_take:      PHT[update_idx_PHT] <= conditional_branch_out.result? high_take:low_not_take;
                    high_take:     PHT[update_idx_PHT] <= conditional_branch_out.result? high_take:low_take;

                endcase

                case (gPHT_update_unit)
                    high_not_take: gPHT[update_idx_gPHT] <= conditional_branch_out.result? low_not_take:high_not_take;
                    low_not_take:  gPHT[update_idx_gPHT] <= conditional_branch_out.result? low_take:high_not_take;
                    low_take:      gPHT[update_idx_gPHT] <= conditional_branch_out.result? high_take:low_not_take;
                    high_take:     gPHT[update_idx_gPHT] <= conditional_branch_out.result? high_take:low_take;

                endcase

                if (update_result_global != update_result_local) begin
                    if (conditional_branch_out.result == update_result_local) begin
                        case (selector_update_unit)
                            high_local: selector[gBHT] <= high_local;
                            low_local:  selector[gBHT] <= high_local;
                            low_global: selector[gBHT] <= low_local;
                            high_global:selector[gBHT] <= low_global; 
                        endcase 
                    end else if(conditional_branch_out.result == update_result_global) begin
                        case (selector_update_unit)
                            high_local: selector[gBHT] <= low_local;
                            low_local:  selector[gBHT] <= low_global;
                            low_global: selector[gBHT] <= high_global;
                            high_global:selector[gBHT] <= high_global;
                        endcase
                    end

                end
                gBHT <= {gBHT[4:0],conditional_branch_out.result};
                BHT[update_idx_BHT] <= {BHT[update_idx_BHT][2:0],conditional_branch_out.result};
            end
        end
    end
   
endmodule



