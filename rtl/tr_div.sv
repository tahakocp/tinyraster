// Restoring divider, one quotient bit per clock. Unsigned; the caller handles signs.
module tr_div #(
    parameter NW = 52,
    parameter DW = 27
) (
    input  logic          clk,
    input  logic          start,
    input  logic [NW-1:0] num,
    input  logic [DW-1:0] den,
    output logic          done,
    output logic [NW-1:0] quo
);
    logic [DW:0]   rem;
    logic [NW-1:0] q;
    logic [NW-1:0] n;
    logic [DW-1:0] d;
    logic [7:0]    cnt;
    logic          busy;

    wire [DW:0] shifted = {rem[DW-1:0], n[NW-1]};
    wire        ge      = shifted >= {1'b0, d};

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            rem  <= '0;
            q    <= '0;
            n    <= num;
            d    <= den;
            cnt  <= NW[7:0];
            busy <= 1'b1;
        end else if (busy) begin
            rem <= ge ? shifted - {1'b0, d} : shifted;
            q   <= {q[NW-2:0], ge};
            n   <= {n[NW-2:0], 1'b0};
            cnt <= cnt - 8'd1;
            if (cnt == 8'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    // q is final the cycle after the last shift, which is when done is high
    assign quo = q;
endmodule
