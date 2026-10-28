`timescale 1ns / 1ps
module tb_mnist_regression;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_last = 0, s_valid = 0;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_last, m_valid;
    reg m_ready = 0;
    wire frame_error;
    reg [7:0] frame [0:9587];
    reg [31:0] expected [0:29];
    integer sample, beat, lane, cycles = 0, received = 0;
    reg stalled = 0;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;

    mnist_stream_core dut (
        .aclk(clk), .aresetn(rst_n),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tlast(s_last), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep), .m_axis_tlast(m_last),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .frame_error(frame_error)
    );

    initial begin
        $readmemh("frames_regression.mem", frame);
        $readmemh("logits_regression.mem", expected);
        repeat (20) @(negedge clk);
        rst_n = 1;
        for (sample = 0; sample < 3; sample = sample + 1) begin
            for (beat = 0; beat < 400; beat = beat + 1) begin
                @(negedge clk);
                s_data = 0;
                s_keep = 0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (beat*8+lane < 3196) begin
                        s_data[8*lane +: 8] = frame[sample*3196+beat*8+lane];
                        s_keep[lane] = 1;
                    end
                end
                s_last = (beat == 399);
                s_valid = 1;
                do @(posedge clk); while (!s_ready);
                @(negedge clk);
                s_valid = 0;
            end
        end
    end

    always @(negedge clk) if (rst_n) m_ready <= ((cycles % 11) >= 4);
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        if (frame_error) $fatal(1, "Frame rejected by core");
        if (stalled && (!m_valid || m_data !== held_data ||
                        m_keep !== held_keep || m_last !== held_last))
            $fatal(1, "AXI stream output changed while stalled");
        stalled <= m_valid && !m_ready;
        if (m_valid && !m_ready) begin
            held_data <= m_data;
            held_keep <= m_keep;
            held_last <= m_last;
        end
        if (m_valid && m_ready) begin
            if (m_keep !== 8'hff || m_data[31:0] !== expected[2*received] ||
                m_data[63:32] !== expected[2*received+1] ||
                m_last !== ((received % 5) == 4))
                $fatal(1, "Logit mismatch at output beat %0d", received);
            if (received == 14) begin
                $display("TEST_PASS: 3 samples, 30 exact logits and output backpressure");
                $finish;
            end
            received <= received + 1;
        end
    end
    initial begin
        #5000000;
        $fatal(1, "Watchdog timeout");
    end
endmodule
