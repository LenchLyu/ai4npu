`timescale 1ns / 1ps

// Fixed first implementation for mnist_int8_reference_v1.
// One input packet: weights, little-endian INT32 biases, then one INT8 image.
// One output packet: 10 little-endian INT32 logits.
module mnist_stream_core (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET aresetn" *)
    input  wire aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 8, HAS_TKEEP 1, HAS_TLAST 1" *)
    input  wire [63:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [7:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 8, HAS_TKEEP 1, HAS_TLAST 1" *)
    output wire [63:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output wire [7:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire m_axis_tready,
    output reg frame_error
);

    localparam integer FRAME_BYTES = 3196;
    localparam [3:0] LOAD = 0, C1_GO = 1, C1_WAIT = 2,
        P1_GO = 3, P1_WAIT = 4, C2_GO = 5, C2_WAIT = 6,
        P2_GO = 7, P2_WAIT = 8, FC = 9, SEND = 10, ERROR_STATE = 11;

    reg [3:0] state;
    reg signed [7:0] c1_weight [0:35];
    reg signed [31:0] c1_bias [0:3];
    reg signed [7:0] c2_weight [0:287];
    reg signed [31:0] c2_bias [0:7];
    reg signed [7:0] fc_weight [0:1999];
    reg signed [31:0] fc_bias [0:9];
    reg signed [7:0] image_mem [0:783];
    reg signed [7:0] pool1_mem [0:675];
    reg signed [7:0] pool2_mem [0:199];
    reg signed [31:0] logits [0:9];

    reg [63:0] beat_data;
    reg [7:0] beat_keep;
    reg beat_last, beat_pending;
    reg [2:0] lane;
    reg [12:0] byte_count;
    wire [7:0] current_byte = beat_data[8*lane +: 8];

    reg [3:0] out_ch;
    reg [3:0] pool_y, pool_x;
    reg [1:0] sub, in_ch;
    reg signed [31:0] partial_acc;
    reg signed [7:0] pool_values [3:0];

    reg [7:0] fc_index;
    reg [3:0] fc_class;
    reg signed [31:0] fc_acc;
    reg [2:0] send_index;

    assign s_axis_tready = aresetn && (state == LOAD) && !beat_pending;
    assign m_axis_tvalid = (state == SEND);
    assign m_axis_tdata = (state == SEND)
                        ? {logits[2*send_index+1], logits[2*send_index]}
                        : 64'b0;
    assign m_axis_tkeep = 8'hff;
    assign m_axis_tlast = (state == SEND) && (send_index == 4);

    reg signed [7:0] pe_input [8:0];
    reg signed [7:0] pe_filter [8:0];
    wire pe_input_ready, pe_filter_ready;
    wire signed [19:0] pe_result;
    wire pe_result_valid;
    wire pe_valid = (state == C1_GO) || (state == C2_GO);

    integer k;
    always @(*) begin
        for (k = 0; k < 9; k = k + 1) begin
            pe_input[k] = 0;
            pe_filter[k] = 0;
            if (state == C1_GO) begin
                pe_input[k] = image_mem[
                    (2*pool_y + (sub/2) + (k/3))*28 +
                    2*pool_x + (sub%2) + (k%3)];
                pe_filter[k] = c1_weight[out_ch*9+k];
            end else if (state == C2_GO) begin
                pe_input[k] = pool1_mem[
                    in_ch*169 +
                    (2*pool_y + (sub/2) + (k/3))*13 +
                    2*pool_x + (sub%2) + (k%3)];
                pe_filter[k] = c2_weight[(out_ch*4+in_ch)*9+k];
            end
        end
    end

    conv2d #(.DATA_WIDTH(8), .FILTER_SIZE(3)) pe (
        .clk(aclk), .rst_n(aresetn),
        .filter_valid(pe_valid), .filter_ready(pe_filter_ready),
        .input_feature_map_valid(pe_valid),
        .input_feature_map_ready(pe_input_ready),
        .input_feature_map(pe_input), .filter(pe_filter),
        .conv_result(pe_result), .conv_result_valid(pe_result_valid)
    );

    wire pool_ready, pool_valid;
    wire signed [7:0] pool_result;
    wire pool_start = (state == P1_GO) || (state == P2_GO);
    wire pool_take = (state == P1_WAIT) || (state == P2_WAIT);
    maxpool2d #(.DATA_WIDTH(8)) pool (
        .clk(aclk), .rst_n(aresetn),
        .pool_input_valid(pool_start), .pool_input_ready(pool_ready),
        .pool_output_ready(pool_take), .pool_output_valid(pool_valid),
        .pool_input(pool_values), .pool_output(pool_result)
    );

    wire signed [31:0] pe_ext = {{12{pe_result[19]}}, pe_result};
    wire signed [31:0] c1_acc = c1_bias[out_ch] + pe_ext;
    wire signed [31:0] c2_acc = c2_bias[out_ch] + partial_acc + pe_ext;
    wire signed [15:0] fc_product =
        $signed(pool2_mem[fc_index]) * $signed(fc_weight[fc_class*200+fc_index]);

    // ReLU, nearest-even rounding, then unsigned-range saturation [0,127].
    function automatic [7:0] requant_relu(input signed [31:0] value, input integer shift);
        reg [31:0] quotient, remainder, half;
        begin
            if (value <= 0) begin
                requant_relu = 0;
            end else begin
                quotient = $unsigned(value) >> shift;
                remainder = $unsigned(value) & ((32'h1 << shift)-1);
                half = 32'h1 << (shift-1);
                if ((remainder > half) || ((remainder == half) && quotient[0]))
                    quotient = quotient + 1;
                requant_relu = (quotient > 127) ? 8'd127 : quotient[7:0];
            end
        end
    endfunction

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= LOAD;
            beat_pending <= 0;
            byte_count <= 0;
            lane <= 0;
            frame_error <= 0;
            out_ch <= 0;
            pool_y <= 0;
            pool_x <= 0;
            sub <= 0;
            in_ch <= 0;
            partial_acc <= 0;
            fc_index <= 0;
            fc_class <= 0;
            fc_acc <= 0;
            send_index <= 0;
        end else begin
            case (state)
                LOAD: begin
                    if (!beat_pending) begin
                        if (s_axis_tvalid && s_axis_tready) begin
                            beat_data <= s_axis_tdata;
                            beat_keep <= s_axis_tkeep;
                            beat_last <= s_axis_tlast;
                            lane <= 0;
                            beat_pending <= 1;
                        end
                    end else begin
                        if (beat_keep[lane]) begin
                            if (byte_count >= FRAME_BYTES) begin
                                frame_error <= 1;
                                state <= ERROR_STATE;
                            end else begin
                                if (byte_count < 36)
                                    c1_weight[byte_count] <= current_byte;
                                else if (byte_count < 52)
                                    c1_bias[(byte_count-36)/4][8*((byte_count-36)%4) +: 8] <= current_byte;
                                else if (byte_count < 340)
                                    c2_weight[byte_count-52] <= current_byte;
                                else if (byte_count < 372)
                                    c2_bias[(byte_count-340)/4][8*((byte_count-340)%4) +: 8] <= current_byte;
                                else if (byte_count < 2372)
                                    fc_weight[byte_count-372] <= current_byte;
                                else if (byte_count < 2412)
                                    fc_bias[(byte_count-2372)/4][8*((byte_count-2372)%4) +: 8] <= current_byte;
                                else
                                    image_mem[byte_count-2412] <= current_byte;
                                byte_count <= byte_count + 1;
                            end
                        end
                        if (lane == 7) begin
                            beat_pending <= 0;
                            if (beat_last) begin
                                if (byte_count + (beat_keep[lane] ? 1 : 0) == FRAME_BYTES) begin
                                    out_ch <= 0;
                                    pool_y <= 0;
                                    pool_x <= 0;
                                    sub <= 0;
                                    in_ch <= 0;
                                    partial_acc <= 0;
                                    state <= C1_GO;
                                end else begin
                                    frame_error <= 1;
                                    state <= ERROR_STATE;
                                end
                            end
                        end else
                            lane <= lane + 1;
                    end
                end
                C1_GO: if (pe_input_ready && pe_filter_ready) state <= C1_WAIT;
                C1_WAIT: if (pe_result_valid) begin
                    pool_values[sub] <= requant_relu(c1_acc, 8);
                    if (sub == 3) begin sub <= 0; state <= P1_GO; end
                    else begin sub <= sub + 1; state <= C1_GO; end
                end
                P1_GO: if (pool_ready) state <= P1_WAIT;
                P1_WAIT: if (pool_valid && pool_take) begin
                    pool1_mem[out_ch*169 + pool_y*13 + pool_x] <= pool_result;
                    state <= C1_GO;
                    if (pool_x < 12) pool_x <= pool_x + 1;
                    else begin
                        pool_x <= 0;
                        if (pool_y < 12) pool_y <= pool_y + 1;
                        else begin
                            pool_y <= 0;
                            if (out_ch < 3) out_ch <= out_ch + 1;
                            else begin out_ch <= 0; state <= C2_GO; end
                        end
                    end
                end
                C2_GO: if (pe_input_ready && pe_filter_ready) state <= C2_WAIT;
                C2_WAIT: if (pe_result_valid) begin
                    if (in_ch < 3) begin
                        partial_acc <= partial_acc + pe_ext;
                        in_ch <= in_ch + 1;
                        state <= C2_GO;
                    end else begin
                        pool_values[sub] <= requant_relu(c2_acc, 7);
                        partial_acc <= 0;
                        in_ch <= 0;
                        if (sub == 3) begin sub <= 0; state <= P2_GO; end
                        else begin sub <= sub + 1; state <= C2_GO; end
                    end
                end
                P2_GO: if (pool_ready) state <= P2_WAIT;
                P2_WAIT: if (pool_valid && pool_take) begin
                    pool2_mem[out_ch*25 + pool_y*5 + pool_x] <= pool_result;
                    state <= C2_GO;
                    if (pool_x < 4) pool_x <= pool_x + 1;
                    else begin
                        pool_x <= 0;
                        if (pool_y < 4) pool_y <= pool_y + 1;
                        else begin
                            pool_y <= 0;
                            if (out_ch < 7) out_ch <= out_ch + 1;
                            else begin
                                out_ch <= 0;
                                fc_index <= 0;
                                fc_class <= 0;
                                fc_acc <= fc_bias[0];
                                state <= FC;
                            end
                        end
                    end
                end
                FC: begin
                    if (fc_index == 199) begin
                        logits[fc_class] <= fc_acc + $signed(fc_product);
                        fc_index <= 0;
                        if (fc_class == 9) begin
                            send_index <= 0;
                            state <= SEND;
                        end else begin
                            fc_class <= fc_class + 1;
                            fc_acc <= fc_bias[fc_class+1];
                        end
                    end else begin
                        fc_acc <= fc_acc + $signed(fc_product);
                        fc_index <= fc_index + 1;
                    end
                end
                SEND: if (m_axis_tvalid && m_axis_tready) begin
                    if (send_index == 4) begin
                        send_index <= 0;
                        byte_count <= 0;
                        state <= LOAD;
                    end else send_index <= send_index + 1;
                end
                ERROR_STATE: state <= ERROR_STATE;
                default: state <= ERROR_STATE;
            endcase
        end
    end
endmodule

