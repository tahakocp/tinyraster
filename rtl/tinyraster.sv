// Edge-function triangle rasterizer with gradient-interpolated colour.
// One pixel per clock while scanning; setup costs a fixed ~200 clocks.
// Algorithm and number formats: docs/architecture.md. Bit-exact model: model/raster.c.
module tinyraster #(
    parameter SW = 64,   // screen width, <= 2048
    parameter SH = 48    // screen height, <= 2048
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        in_valid,
    output logic        in_ready,
    input  logic signed [11:0] x0, y0, x1, y1, x2, y2,
    input  logic [23:0] rgb0, rgb1, rgb2,

    output logic        px_valid,
    output logic [10:0] px_x,
    output logic [10:0] px_y,
    output logic [23:0] px_rgb,
    output logic        tri_done
);
    localparam EW = 32;   // edge values; |w| < 2^25 for 12-bit coordinates
    localparam NW = 52;   // division numerator magnitude
    localparam QW = 40;   // colour accumulators, wrap-safe (see architecture.md)

    typedef enum logic [3:0] {
        IDLE, NORM, BBOX, EDGE0, ORIGIN, SUMS, DIV_N, DIV_X, DIV_Y, SCAN
    } state_t;
    state_t state;

    logic signed [11:0] vx [3];
    logic signed [11:0] vy [3];
    logic [7:0]         vc [3][3];
    logic signed [EW-1:0] area;

    // bounding box after clipping
    logic [10:0] minx, maxx, miny, maxy;

    // per-edge step values and fill-rule flags
    logic signed [EW-1:0] ea [3];   // d(w)/dx
    logic signed [EW-1:0] eb [3];   // d(w)/dy
    logic                 etl [3];
    logic signed [EW-1:0] w0 [3];   // w at bbox origin

    // colour numerators and their divided forms, per channel
    logic signed [47:0] nn [3], sx [3], sy [3];
    logic signed [QW-1:0] q0 [3], gx [3], gy [3];

    // scan state
    logic [10:0] cx, cy;
    logic signed [EW-1:0] w [3], wrow [3];
    logic signed [QW-1:0] q [3], qrow [3];

    // dividers, one per colour channel
    logic          div_start;
    logic [NW-1:0] div_num [3];
    logic [NW-1:0] div_quo [3];
    logic [2:0]    div_done;
    logic [2:0]    div_neg;
    logic [26:0]   div_den;

    genvar g;
    generate
        for (g = 0; g < 3; g++) begin : dv
            tr_div #(.NW(NW), .DW(27)) u (
                .clk(clk), .start(div_start), .num(div_num[g]), .den(div_den),
                .done(div_done[g]), .quo(div_quo[g])
            );
        end
    endgenerate

    function automatic logic [NW-1:0] mag(input logic signed [47:0] v);
        logic signed [NW-1:0] ext;
        logic signed [NW-1:0] sh;
        begin
            ext = v;
            sh  = ext <<< 16;
            mag = sh[NW-1] ? -sh : sh;
        end
    endfunction

    function automatic logic signed [QW-1:0] sgn(input logic [NW-1:0] m, input logic neg);
        logic signed [QW-1:0] t;
        begin
            t   = m[QW-1:0];
            sgn = neg ? -t : t;
        end
    endfunction

    function automatic logic tl_edge(input logic signed [11:0] ax, ay, bx, by);
        logic signed [12:0] dx, dy;
        begin
            dx = bx - ax;
            dy = by - ay;
            tl_edge = (dy < 0) || (dy == 0 && dx > 0);
        end
    endfunction

    // combinational views used by several states
    logic signed [12:0] d10x, d10y, d20x, d20y;
    assign d10x = vx[1] - vx[0];
    assign d10y = vy[1] - vy[0];
    assign d20x = vx[2] - vx[0];
    assign d20y = vy[2] - vy[0];

    logic signed [EW-1:0] area_c;
    assign area_c = d10x * d20y - d10y * d20x;

    logic [2:0] covered;
    always_comb begin
        for (int i = 0; i < 3; i++)
            covered[i] = (w[i] > 0) || (w[i] == 0 && etl[i]);
    end

    function automatic logic [7:0] clamp8(input logic signed [QW-1:0] v);
        logic signed [QW-1:0] r;
        begin
            r = (v + 40'sd32768) >>> 16;
            clamp8 = r < 0 ? 8'd0 : (r > 255 ? 8'd255 : r[7:0]);
        end
    endfunction

    logic [1:0] phase;
    logic [5:0] t;
    logic [1:0] ch, ii, wh;
    int k;

    // the shared multiplier: 32-bit edge quantity times a 13-bit operand
    logic signed [EW-1:0] mul_a;
    logic signed [12:0]   mul_b;
    logic signed [EW+12:0] prod;
    assign prod = mul_a * mul_b;
    always_comb begin
        mul_a = '0;
        mul_b = '0;
        if (state == ORIGIN) begin
            case (t[2:1])
                2'd0: begin mul_a = t[0] ? ea[0] : eb[0]; mul_b = t[0] ? $signed({2'b0, minx}) - vx[1] : $signed({2'b0, miny}) - vy[1]; end
                2'd1: begin mul_a = t[0] ? ea[1] : eb[1]; mul_b = t[0] ? $signed({2'b0, minx}) - vx[2] : $signed({2'b0, miny}) - vy[2]; end
                default: begin mul_a = t[0] ? ea[2] : eb[2]; mul_b = t[0] ? $signed({2'b0, minx}) - vx[0] : $signed({2'b0, miny}) - vy[0]; end
            endcase
        end else begin
            mul_a = wh == 2'd0 ? w0[ii] : wh == 2'd1 ? ea[ii] : eb[ii];
            mul_b = $signed({5'b0, vc[ii][ch]});
        end
    end

    assign in_ready = (state == IDLE);

    always_ff @(posedge clk) begin
        px_valid  <= 1'b0;
        tri_done  <= 1'b0;
        div_start <= 1'b0;

        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
            IDLE: if (in_valid) begin
                vx[0] <= x0; vy[0] <= y0;
                vx[1] <= x1; vy[1] <= y1;
                vx[2] <= x2; vy[2] <= y2;
                for (k = 0; k < 3; k++) begin
                    vc[0][k] <= rgb0[8*(2-k) +: 8];
                    vc[1][k] <= rgb1[8*(2-k) +: 8];
                    vc[2][k] <= rgb2[8*(2-k) +: 8];
                end
                state <= NORM;
            end

            // make the winding positive by swapping v1 and v2
            NORM: begin
                if (area_c == 0) begin
                    tri_done <= 1'b1;
                    state    <= IDLE;
                end else begin
                    if (area_c < 0) begin
                        vx[1] <= vx[2]; vy[1] <= vy[2];
                        vx[2] <= vx[1]; vy[2] <= vy[1];
                        for (k = 0; k < 3; k++) begin
                            vc[1][k] <= vc[2][k];
                            vc[2][k] <= vc[1][k];
                        end
                        area <= -area_c;
                    end else begin
                        area <= area_c;
                    end
                    state <= BBOX;
                end
            end

            BBOX: begin : bb
                logic signed [11:0] lx, hx, ly, hy;
                lx = vx[0] < vx[1] ? (vx[0] < vx[2] ? vx[0] : vx[2]) : (vx[1] < vx[2] ? vx[1] : vx[2]);
                hx = vx[0] > vx[1] ? (vx[0] > vx[2] ? vx[0] : vx[2]) : (vx[1] > vx[2] ? vx[1] : vx[2]);
                ly = vy[0] < vy[1] ? (vy[0] < vy[2] ? vy[0] : vy[2]) : (vy[1] < vy[2] ? vy[1] : vy[2]);
                hy = vy[0] > vy[1] ? (vy[0] > vy[2] ? vy[0] : vy[2]) : (vy[1] > vy[2] ? vy[1] : vy[2]);
                if (hx < 0 || hy < 0 || lx > SW - 1 || ly > SH - 1) begin
                    tri_done <= 1'b1;
                    state    <= IDLE;
                end else begin
                    minx <= lx < 0 ? 11'd0 : lx[10:0];
                    miny <= ly < 0 ? 11'd0 : ly[10:0];
                    maxx <= hx > SW - 1 ? SW - 1 : hx[10:0];
                    maxy <= hy > SH - 1 ? SH - 1 : hy[10:0];
                    state <= EDGE0;
                    ch <= 2'd0; ii <= 2'd0; wh <= 2'd0;
                end
            end

            // edge i is opposite vertex i
            EDGE0: begin : ed
                logic signed [11:0] ax [3];
                logic signed [11:0] ay [3];
                logic signed [11:0] bx [3];
                logic signed [11:0] by [3];
                logic signed [EW-1:0] a_, b_;
                ax[0] = vx[1]; ay[0] = vy[1]; bx[0] = vx[2]; by[0] = vy[2];
                ax[1] = vx[2]; ay[1] = vy[2]; bx[1] = vx[0]; by[1] = vy[0];
                ax[2] = vx[0]; ay[2] = vy[0]; bx[2] = vx[1]; by[2] = vy[1];
                for (int i = 0; i < 3; i++) begin
                    a_ = -(by[i] - ay[i]);
                    b_ =   bx[i] - ax[i];
                    ea[i]  <= a_;
                    eb[i]  <= b_;
                    etl[i] <= tl_edge(ax[i], ay[i], bx[i], by[i]);
                end
                state <= ORIGIN;
                t     <= 6'd0;
            end

            // one shared multiplier walks through the 6 + 27 products of the setup
            ORIGIN: begin
                w0[t[2:1]] <= (t[0] ? w0[t[2:1]] : '0) + prod;
                t <= t + 6'd1;
                if (t == 6'd5) begin
                    t     <= 6'd0;
                    state <= SUMS;
                end
            end

            SUMS: begin
                case (wh)
                    2'd0: nn[ch] <= (ii == 0 ? 48'sd0 : nn[ch]) + prod;
                    2'd1: sx[ch] <= (ii == 0 ? 48'sd0 : sx[ch]) + prod;
                    default: sy[ch] <= (ii == 0 ? 48'sd0 : sy[ch]) + prod;
                endcase
                if (wh == 2'd2) begin
                    wh <= 2'd0;
                    if (ii == 2'd2) begin
                        ii <= 2'd0;
                        if (ch == 2'd2) begin
                            div_den <= area[26:0];
                            phase   <= 2'd0;
                            state   <= DIV_N;
                        end
                        ch <= ch + 2'd1;
                    end else ii <= ii + 2'd1;
                end else wh <= wh + 2'd1;
            end

            // three rounds of three parallel divisions: origin value, d/dx, d/dy
            DIV_N, DIV_X, DIV_Y: begin
                if (phase == 2'd0) begin
                    for (int c = 0; c < 3; c++) begin
                        div_num[c] <= mag(state == DIV_N ? nn[c] : state == DIV_X ? sx[c] : sy[c]);
                        div_neg[c] <= (state == DIV_N ? nn[c] : state == DIV_X ? sx[c] : sy[c]) < 0;
                    end
                    div_start <= 1'b1;
                    phase     <= 2'd1;
                end else if (div_done[0]) begin
                    for (int c = 0; c < 3; c++) begin
                        case (state)
                            DIV_N: q0[c] <= sgn(div_quo[c], div_neg[c]);
                            DIV_X: gx[c] <= sgn(div_quo[c], div_neg[c]);
                            default: gy[c] <= sgn(div_quo[c], div_neg[c]);
                        endcase
                    end
                    phase <= 2'd0;
                    if (state == DIV_N) state <= DIV_X;
                    else if (state == DIV_X) state <= DIV_Y;
                    else begin
                        for (int i = 0; i < 3; i++) begin w[i] <= w0[i]; wrow[i] <= w0[i]; end
                        for (int c = 0; c < 3; c++) begin q[c] <= q0[c]; qrow[c] <= q0[c]; end
                        cx <= minx;
                        cy <= miny;
                        state <= SCAN;
                    end
                end
            end

            SCAN: begin
                if (covered == 3'b111) begin
                    px_valid <= 1'b1;
                    px_x     <= cx;
                    px_y     <= cy;
                    px_rgb   <= {clamp8(q[0]), clamp8(q[1]), clamp8(q[2])};
                end
                if (cx == maxx) begin
                    if (cy == maxy) begin
                        tri_done <= 1'b1;
                        state    <= IDLE;
                    end
                    cx <= minx;
                    cy <= cy + 11'd1;
                    for (int i = 0; i < 3; i++) begin
                        w[i]    <= wrow[i] + eb[i];
                        wrow[i] <= wrow[i] + eb[i];
                    end
                    for (int c = 0; c < 3; c++) begin
                        q[c]    <= qrow[c] + gy[c];
                        qrow[c] <= qrow[c] + gy[c];
                    end
                end else begin
                    cx <= cx + 11'd1;
                    for (int i = 0; i < 3; i++) w[i] <= w[i] + ea[i];
                    for (int c = 0; c < 3; c++) q[c] <= q[c] + gx[c];
                end
            end

            default: state <= IDLE;
            endcase
        end
    end
endmodule
