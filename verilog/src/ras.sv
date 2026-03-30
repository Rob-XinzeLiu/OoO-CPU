
`include "sys_defs.svh"

// valid mask becomes 0 only when 

module ras (
    input clock,
    input reset,
    
    input INST  [1:0]                   inst,
    input ADDR  [1:0]                   npc,
    input logic [1:0]                   input_valid,
    input logic                         mispredict,
    input logic [1:0]                   recovered_head,
    input logic [2:0]                   recovered_count,

    output ADDR [1:0]                   return_addr,
    output logic [1:0]                  valid_addr,
    output logic [1:0]                  current_head,
    output logic [2:0]                  current_count
);
    localparam RAS_SIZE = 4;

    typedef struct packed{
        ADDR    PC;
        ADDR    R_PC;
    } RAS_ENTRY;

    RAS_ENTRY ras [RAS_SIZE] ;

    logic [1:0] push, pop;
    logic [$clog2(RAS_SIZE)-1:0] head;
    logic [$clog2(RAS_SIZE):0] count;
    logic [1:0] link_rd;
    logic [1:0] link_rs1;

    // Update logic
    logic [1:0] num_push;
    logic [1:0] num_pop;

    always_comb begin
        link_rd = '0;
        link_rs1 = '0;
        pop = '0;
        push = '0;
        
        for(int i = 0; i < 2; i++) begin
            if(input_valid[i]) begin
                casez(inst[i])
                    `RV32_JAL: begin
                        if(input_valid[i] && (inst[i].j.rd == 5 || inst[i].j.rd == 1)) begin
                            push[i] = 1'b1;
                        end 
                    end
                    `RV32_JALR: begin
                        link_rd[i] = (inst[i].i.rd == 1 || inst[i].i.rd == 5);           // I want to store this return address
                        link_rs1[i] =  (inst[i].i.rs1 == 1 || inst[i].i.rs1 == 5);       // I want to use the return address
                        case({link_rd[i], link_rs1[i]})
                            2'b01: begin        // pop
                                pop[i] = 1;
                            end
                            2'b10: begin        // push
                                push[i] = 1;                            
                            end
                            2'b11: begin        // pop + push
                                if(inst[i].i.rd == inst[i].i.rs1) begin   // jalr ra, ra, 0
                                    push[i] = 1;
                                end else begin
                                    pop[i] = 1;
                                    push[i] = 1;
                                end
                            end
                            default: begin
                                pop[i] = 0;
                                push[i] = 0;
                            end
                        endcase
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

    always_comb begin
        return_addr = '0;
        valid_addr = '0;
        // slot 0 output
        if(pop[0]) begin
            return_addr[0] = ras[(head - 1) % RAS_SIZE].R_PC;
            valid_addr[0] = (count > 0)? 1'b1 : 1'b0;
        end
        // slot 1 output
        if(pop[1]) begin
            if(pop[0] && !push[0]) begin
                return_addr[1] = ras[(head - 2) % RAS_SIZE].R_PC;
                valid_addr[1] = (count > 1)? 1'b1 : 1'b0;
            end else if(push[0]) begin  // Includes 2 cases: !pop[0] && push[0], pop[0] && push[0]
                return_addr[1] = npc[0];
                valid_addr[1] = 1'b1;
            end else begin              // !pop[0] && !push[0]
                return_addr[1] = ras[(head - 1) % RAS_SIZE].R_PC;
                valid_addr[1] = (count > 0)? 1'b1 : 1'b0;
            end
        end
    end

    assign num_pop = pop[0] + pop[1];
    assign num_push = push[0] + push[1];
    assign current_head = head;
    assign current_count = count;

    always_ff @(posedge clock) begin
       if(reset) begin
            ras <= '{default: '0};
            head <= '0;
            count <= '0;
       end else if(mispredict) begin
            head <= recovered_head;
            count <= recovered_count;
       end else begin
            if(push[0]) begin
                ras[(head - num_pop) % RAS_SIZE].R_PC   <= npc[0];
            end
            if(push[1]) begin
                ras[(head - num_pop + push[0]) % RAS_SIZE].R_PC <= npc[1];
            end
            head <= head + num_push - num_pop;
            if(count + num_push < num_pop) begin
                count <= 3'd0;
            end else if(count + num_push - num_pop > 3'd4) begin
                count <= '0;
            end else begin
                count <= count + num_push - num_pop;
            end
       end  
    end

endmodule