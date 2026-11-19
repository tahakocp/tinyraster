// Feeds triangles from a text file, logs every pixel as "tri cycle x y rrggbb".
`timescale 1ns/1ps
module tb_tinyraster;
    parameter SW = 64;
    parameter SH = 48;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic in_valid = 0;
    logic in_ready;
    logic signed [11:0] x0, y0, x1, y1, x2, y2;
    logic [23:0] c0, c1, c2;
    logic px_valid, tri_done;
    logic [10:0] px_x, px_y;
    logic [23:0] px_rgb;

    tinyraster #(.SW(SW), .SH(SH)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
        .rgb0(c0), .rgb1(c1), .rgb2(c2),
        .px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .tri_done(tri_done)
    );

    integer fin, fout, fstat, n, cycle, tri_start;
    integer ax0, ay0, ax1, ay1, ax2, ay2;
    reg [1023:0] infile, outfile;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (px_valid) $fdisplay(fout, "%0d %0d %0d %0d %06x", n, cycle - tri_start, px_x, px_y, px_rgb);
    end

    initial begin
        if (!$value$plusargs("tris=%s", infile)) infile = "tris.txt";
        if (!$value$plusargs("out=%s", outfile)) outfile = "pixels.txt";
        fin = $fopen(infile, "r");
        fout = $fopen(outfile, "w");
        if (fin == 0 || fout == 0) begin
            $display("cannot open files");
            $finish;
        end
        cycle = 0;
        n = 0;
        repeat (4) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        while (!$feof(fin)) begin
            fstat = $fscanf(fin, "%d %d %d %d %d %d %h %h %h\n", ax0, ay0, ax1, ay1, ax2, ay2, c0, c1, c2);
            if (fstat == 9) begin
                x0 = ax0; y0 = ay0; x1 = ax1; y1 = ay1; x2 = ax2; y2 = ay2;
                while (!in_ready) @(posedge clk);
                in_valid <= 1;
                tri_start = cycle + 1;
                @(posedge clk);
                in_valid <= 0;
                @(posedge clk);
                while (!tri_done) @(posedge clk);
                @(posedge clk);
                $display("TRI %0d cycles %0d", n, cycle - tri_start);
                n = n + 1;
            end
        end
        repeat (4) @(posedge clk);
        $fclose(fout);
        $display("done: %0d triangles", n);
        $finish;
    end
endmodule
