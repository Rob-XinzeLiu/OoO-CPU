`include "sys_defs.svh"
`include "ROB.svh"
module ROB(
    input clk, rst;
    input logic [1:0] dispatched_inst_cnt;
    input logic  mispredicted;
    input logic [`TAG_CNT-1:0] t_from_freelist;
    input logic [`TAG_CNT-1:0] told_from_mt;
    input logic [`TAG_CNT-1:0] ready_retire_tag;
    input ADDR pc;
    input logic [2:0] fu_type;//ask during OH
    input REG_IDX  dest_reg_idx; 
    output logic ready_dispatch;
    output logic [`TAG_CNT-1:0] told_to_freelist;
    output logic [`TAG_CNT-1:0] t_to_amt;
);

