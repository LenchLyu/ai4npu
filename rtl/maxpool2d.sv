`timescale 1ns / 1ps

module maxpool2d#(
    parameter DATA_WIDTH = 8
    )(
    input  wire clk,
    input  wire rst_n,

    input  wire pool_input_valid,
    output wire pool_input_ready,

    input  wire pool_output_ready,
    output wire pool_output_valid,

    input  wire signed [DATA_WIDTH-1:0] pool_input [3:0],
    output reg  signed [DATA_WIDTH-1:0] pool_output
    );

    localparam EMPTY = 2'b 00 ;
    localparam FULL  = 2'b 01 ;

    reg [1:0] state;

    wire signed [DATA_WIDTH-1:0] max_01  ;
    wire signed [DATA_WIDTH-1:0] max_23  ;
    wire signed [DATA_WIDTH-1:0] max_all ;

    assign max_01  = (pool_input[0] >= pool_input[1])? pool_input[0]: pool_input[1] ;
    assign max_23  = (pool_input[2] >= pool_input[3])? pool_input[2]: pool_input[3] ;
    assign max_all = (max_01 >= max_23)? max_01:max_23 ;

    assign pool_output_valid = (state == FULL);
    assign pool_input_ready  = rst_n && ((state == EMPTY)||((state == FULL)&& pool_output_ready));



    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state <= EMPTY;
            pool_output <= '0;
        end
        else begin
            case (state)
                EMPTY:begin
                    if(pool_input_ready && pool_input_valid)begin
                        pool_output <= max_all;
                        state <= FULL;
                    end
                end 
                FULL:begin
                    if(pool_output_ready)begin
                    if (pool_input_valid) begin
                        //后一级取走旧结果，同时有新的输入
                        pool_output <= max_all;
                        state <= FULL;
                    end else begin
                        //后一级取走旧结果，没有新输入
                        state <= EMPTY;
                    end
                    end
                    else begin
                        //后一级未取走旧结果（没有ready）：保持结果和FULL状态
                        state <= FULL;
                    end
                end
                default: state <= EMPTY;
            endcase
        end
    end
endmodule
