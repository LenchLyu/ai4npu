`timescale 1ns / 1ps

module conv2d #(
    parameter int DATA_WIDTH  = 8,
    parameter int FILTER_SIZE = 3
)(
    input  wire clk,
    input  wire rst_n,

    input  wire filter_valid,
    output wire filter_ready,

    input  wire input_feature_map_valid,
    output wire input_feature_map_ready,

    input  wire signed [DATA_WIDTH-1:0]
        input_feature_map [FILTER_SIZE*FILTER_SIZE-1:0],
    input  wire signed [DATA_WIDTH-1:0]
        filter [FILTER_SIZE*FILTER_SIZE-1:0],

    output reg signed
        [2*DATA_WIDTH+$clog2(FILTER_SIZE*FILTER_SIZE)-1:0]
        conv_result,
    output reg conv_result_valid
);

    localparam int MAC_NUMBER = FILTER_SIZE * FILTER_SIZE;
    localparam int ACC_WIDTH  = 2*DATA_WIDTH + $clog2(MAC_NUMBER);

    localparam logic IDLE = 1'b0;
    localparam logic CALC = 1'b1  ;

    reg state;

    reg signed [DATA_WIDTH-1:0] feature_map_reg [MAC_NUMBER-1:0];
    reg signed [DATA_WIDTH-1:0] filter_reg      [MAC_NUMBER-1:0];

    reg signed [2*DATA_WIDTH-1:0] product;
    reg signed [ACC_WIDTH-1:0]    conv_sum;

    integer i;
    integer j;

    // 这一版要求 filter 和特征图同时到达，作为一组完成握手。
    // 只有两边都 valid，才同时向两边给出 ready。

    assign filter_ready = rst_n && (state == IDLE) && input_feature_map_valid;

    assign input_feature_map_ready = rst_n && (state == IDLE) && filter_valid;


    // 9 个有符号乘积求和。3×3、INT8 时：
    // 乘积为 16 位，累加结果为 16 + clog2(9) = 20 位。
    always @(*) begin
        product  = '0;
        conv_sum = '0;

        for (j = 0; j < MAC_NUMBER; j = j + 1) begin
            product  = feature_map_reg[j] * filter_reg[j];
            conv_sum = conv_sum + product;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            conv_result       <= '0;
            conv_result_valid <= 1'b0;

            for (i = 0; i < MAC_NUMBER; i = i + 1) begin
                feature_map_reg[i] <= '0;
                filter_reg[i]      <= '0;
            end
        end else begin
            // 默认只让 valid 持续一个时钟周期
            conv_result_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (filter_valid && filter_ready &&
                        input_feature_map_valid &&
                        input_feature_map_ready) begin

                        for (i = 0; i < MAC_NUMBER; i = i + 1) begin
                            feature_map_reg[i] <= input_feature_map[i];
                            filter_reg[i]      <= filter[i];
                        end

                        state <= CALC;
                    end
                end

                CALC: begin
                    conv_result       <= conv_sum;
                    conv_result_valid <= 1'b1;
                    state             <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule