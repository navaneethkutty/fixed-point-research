module dsp_mult17x17_signed #(
    parameter logic signed [47:0] ROUND_BIAS = 48'sd0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [16:0] a,
    input  logic signed [16:0] b,
    output logic out_valid,
    output logic signed [33:0] p
);

    logic [29:0] dsp_a;
    logic [17:0] dsp_b;
    logic [47:0] dsp_p;

    logic v0;
    logic v1;
    logic v2;

    assign dsp_a = {{13{a[16]}}, a};
    assign dsp_b = {b[16], b};

    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"),
        .USE_MULT("MULTIPLY"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h3FFFFFFFFFFF),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(1),
        .ADREG(0),
        .ALUMODEREG(0),
        .AREG(1),
        .BCASCREG(1),
        .BREG(1),
        .CARRYINREG(0),
        .CARRYINSELREG(0),
        .CREG(0),
        .DREG(0),
        .INMODEREG(0),
        .MREG(1),
        .OPMODEREG(0),
        .PREG(1)
    ) u_dsp (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(dsp_p),

        .ACIN(30'b0),
        .BCIN(18'b0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(48'b0),

        .ALUMODE(4'b0000),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b00000),

        .OPMODE(7'b0110101),

        .A(dsp_a),
        .B(dsp_b),
        .C(ROUND_BIAS),
        .CARRYIN(1'b0),
        .D(25'b0),

        .CEA1(1'b0),
        .CEA2(1'b1),
        .CEAD(1'b0),
        .CEALUMODE(1'b0),
        .CEB1(1'b0),
        .CEB2(1'b1),
        .CEC(1'b0),
        .CECARRYIN(1'b0),
        .CECTRL(1'b0),
        .CED(1'b0),
        .CEINMODE(1'b0),
        .CEM(1'b1),
        .CEP(1'b1),

        .RSTA(~rst_n),
        .RSTALLCARRYIN(1'b0),
        .RSTALUMODE(1'b0),
        .RSTB(~rst_n),
        .RSTC(1'b0),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(~rst_n),
        .RSTP(~rst_n)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0;
            v1 <= 1'b0;
            v2 <= 1'b0;
        end else begin
            v0 <= in_valid;
            v1 <= v0;
            v2 <= v1;
        end
    end

    assign p = dsp_p[33:0];
    assign out_valid = v2;

endmodule


module dsp_add18x18_signed (
    input logic clk,
    input logic rst_n,
    input logic in_valid,
    input logic signed [17:0] a,
    input logic signed [17:0] b,
    input logic carry_in,
    output logic out_valid,
    output logic signed [18:0] p
);

    logic [47:0] dsp_p;
    logic v0;
    logic v1;

    DSP48E1 #(
        .A_INPUT("DIRECT"),
        .B_INPUT("DIRECT"),
        .USE_DPORT("FALSE"),
        .USE_MULT("NONE"),
        .USE_SIMD("ONE48"),
        .AUTORESET_PATDET("NO_RESET"),
        .MASK(48'h3FFFFFFFFFFF),
        .PATTERN(48'h000000000000),
        .SEL_MASK("MASK"),
        .SEL_PATTERN("PATTERN"),
        .USE_PATTERN_DETECT("NO_PATDET"),
        .ACASCREG(1),
        .ADREG(0),
        .ALUMODEREG(0),
        .AREG(1),
        .BCASCREG(1),
        .BREG(1),
        .CARRYINREG(1),
        .CARRYINSELREG(0),
        .CREG(1),
        .DREG(0),
        .INMODEREG(0),
        .MREG(0),
        .OPMODEREG(0),
        .PREG(1)
    ) u_add (
        .ACOUT(),
        .BCOUT(),
        .CARRYCASCOUT(),
        .MULTSIGNOUT(),
        .PCOUT(),
        .OVERFLOW(),
        .PATTERNBDETECT(),
        .PATTERNDETECT(),
        .UNDERFLOW(),
        .CARRYOUT(),
        .P(dsp_p),

        .ACIN(30'b0),
        .BCIN(18'b0),
        .CARRYCASCIN(1'b0),
        .MULTSIGNIN(1'b0),
        .PCIN(48'b0),

        .ALUMODE(4'b0000),
        .CARRYINSEL(3'b000),
        .CLK(clk),
        .INMODE(5'b00000),

        .OPMODE(7'b0110011),

        .A({30{a[17]}}),
        .B(a),
        .C({{30{b[17]}}, b}),
        .CARRYIN(carry_in),
        .D(25'b0),

        .CEA1(1'b0),
        .CEA2(1'b1),
        .CEAD(1'b0),
        .CEALUMODE(1'b0),
        .CEB1(1'b0),
        .CEB2(1'b1),
        .CEC(1'b1),
        .CECARRYIN(1'b1),
        .CECTRL(1'b0),
        .CED(1'b0),
        .CEINMODE(1'b0),
        .CEM(1'b0),
        .CEP(1'b1),

        .RSTA(~rst_n),
        .RSTALLCARRYIN(~rst_n),
        .RSTALUMODE(1'b0),
        .RSTB(~rst_n),
        .RSTC(~rst_n),
        .RSTCTRL(1'b0),
        .RSTD(1'b0),
        .RSTINMODE(1'b0),
        .RSTM(1'b0),
        .RSTP(~rst_n)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0;
            v1 <= 1'b0;
        end else begin
            v0 <= in_valid;
            v1 <= v0;
        end
    end

    assign p = dsp_p[18:0];
    assign out_valid = v1;

endmodule


module pipelined_mult32x32_signed (
    input logic clk,
    input logic rst_n,
    input logic in_valid,
    input logic signed [31:0] a,
    input logic signed [31:0] b,
    output logic out_valid,
    output logic signed [63:0] p
);

    localparam int MULT32_LATENCY = 14;

    localparam logic signed [47:0] ROUND_BIAS = 48'sd32768;

    logic signed [16:0] a_h;
    logic signed [16:0] b_h;
    logic signed [16:0] a_l;
    logic signed [16:0] b_l;

    assign a_h = {a[31], a[31:16]};
    assign b_h = {b[31], b[31:16]};
    assign a_l = {1'b0, a[15:0]};
    assign b_l = {1'b0, b[15:0]};

    logic signed [33:0] phh;
    logic signed [33:0] phl;
    logic signed [33:0] plh;
    logic signed [33:0] pll;

    logic v_hh;
    logic v_hl;
    logic v_lh;
    logic v_ll;

    dsp_mult17x17_signed #(
        .ROUND_BIAS(48'sd0)
    ) u_phh (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .a(a_h),
        .b(b_h),
        .out_valid(v_hh),
        .p(phh)
    );

    dsp_mult17x17_signed #(
        .ROUND_BIAS(48'sd0)
    ) u_phl (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .a(a_h),
        .b(b_l),
        .out_valid(v_hl),
        .p(phl)
    );

    dsp_mult17x17_signed #(
        .ROUND_BIAS(48'sd0)
    ) u_plh (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .a(a_l),
        .b(b_h),
        .out_valid(v_lh),
        .p(plh)
    );

    dsp_mult17x17_signed #(
        .ROUND_BIAS(ROUND_BIAS)
    ) u_pll (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .a(a_l),
        .b(b_l),
        .out_valid(v_ll),
        .p(pll)
    );

    logic signed [33:0] phh_m0;
    logic signed [33:0] phl_m0;
    logic signed [33:0] plh_m0;
    logic signed [33:0] pll_m0;
    logic v_m0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phh_m0 <= '0;
            phl_m0 <= '0;
            plh_m0 <= '0;
            pll_m0 <= '0;
            v_m0 <= 1'b0;
        end else begin
            phh_m0 <= phh;
            phl_m0 <= phl;
            plh_m0 <= plh;
            pll_m0 <= pll;
            v_m0 <= v_hh;
        end
    end

    logic [8:0] cross_low_lo_sum;

    (* srl_style = "register", shreg_extract = "no" *)
    logic [7:0] cross_low_lo_r;
    logic       cross_low_lo_carry_r;

    logic signed [33:0] phh_m0b;
    logic signed [33:0] pll_m0b;
    logic [25:0]        phl_up_m0b;
    logic [25:0]        plh_up_m0b;

    logic v_lo;

    always_comb begin
        cross_low_lo_sum =
            {1'b0, phl_m0[7:0]} +
            {1'b0, plh_m0[7:0]};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross_low_lo_r <= '0;
            cross_low_lo_carry_r <= 1'b0;
            phh_m0b <= '0;
            pll_m0b <= '0;
            phl_up_m0b <= '0;
            plh_up_m0b <= '0;
            v_lo <= 1'b0;
        end else begin
            cross_low_lo_r <= cross_low_lo_sum[7:0];
            cross_low_lo_carry_r <= cross_low_lo_sum[8];
            phh_m0b <= phh_m0;
            pll_m0b <= pll_m0;
            phl_up_m0b <= phl_m0[33:8];
            plh_up_m0b <= plh_m0[33:8];
            v_lo <= v_m0;
        end
    end

    logic [8:0] cross_low_hi_sum;

    (* srl_style = "register", shreg_extract = "no" *)
    logic [15:0] cross_low_r;
    logic cross_carry_r;

    logic signed [33:0] phh_r0;
    logic signed [33:0] pll_r0;

    logic signed [17:0] phl_high_r0;
    logic signed [17:0] plh_high_r0;

    logic v_s1;

    always_comb begin
        cross_low_hi_sum =
            {1'b0, phl_up_m0b[7:0]} +
            {1'b0, plh_up_m0b[7:0]} +
            cross_low_lo_carry_r;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross_low_r <= '0;
            cross_carry_r <= 1'b0;
            phh_r0 <= '0;
            pll_r0 <= '0;
            phl_high_r0 <= '0;
            plh_high_r0 <= '0;
            v_s1 <= 1'b0;
        end else begin
            cross_low_r <= {cross_low_hi_sum[7:0], cross_low_lo_r};
            cross_carry_r <= cross_low_hi_sum[8];
            phh_r0 <= phh_m0b;
            pll_r0 <= pll_m0b;
            phl_high_r0 <= phl_up_m0b[25:8];
            plh_high_r0 <= plh_up_m0b[25:8];
            v_s1 <= v_lo;
        end
    end

    logic signed [18:0] cross_high_dsp;
    logic cross_high_v;

    dsp_add18x18_signed u_cross_add (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_s1),
        .a(phl_high_r0),
        .b(plh_high_r0),
        .carry_in(cross_carry_r),
        .out_valid(cross_high_v),
        .p(cross_high_dsp)
    );

    logic signed [33:0] phh_d1;
    logic signed [33:0] pll_d1;

    (* srl_style = "register", shreg_extract = "no" *)
    logic [15:0] cross_low_d1;

    logic signed [33:0] phh_r1;
    logic signed [33:0] pll_r1;

    (* srl_style = "register", shreg_extract = "no" *)
    logic [15:0] cross_low_r2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phh_d1 <= '0;
            pll_d1 <= '0;
            cross_low_d1 <= '0;
        end else begin
            phh_d1 <= phh_r0;
            pll_d1 <= pll_r0;
            cross_low_d1 <= cross_low_r;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phh_r1 <= '0;
            pll_r1 <= '0;
            cross_low_r2 <= '0;
        end else begin
            phh_r1 <= phh_d1;
            pll_r1 <= pll_d1;
            cross_low_r2 <= cross_low_d1;
        end
    end

    logic v_s2;
    assign v_s2 = cross_high_v;

    logic signed [34:0] cross_sum_r;
    logic signed [33:0] phh_r2;
    logic signed [33:0] pll_r2;
    logic v_s2b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cross_sum_r <= '0;
            phh_r2 <= '0;
            pll_r2 <= '0;
            v_s2b <= 1'b0;
        end else begin
            cross_sum_r <= $signed({cross_high_dsp, cross_low_r2});
            phh_r2 <= phh_r1;
            pll_r2 <= pll_r1;
            v_s2b <= v_s2;
        end
    end

    logic signed [63:0] phh_ext;
    logic signed [63:0] pll_ext;
    logic signed [63:0] cross_sum_ext_c;

    logic [63:0] term1_c;
    logic [63:0] term2_c;

    logic [32:0] upper_sum_lo_sum_c;
    logic [31:0] upper_sum_lo_c;

    logic [31:0] upper_sum_lo_r;
    logic [31:0] term1_hi_r;
    logic [31:0] term2_hi_r;
    logic upper_sum_carry_r;

    (* dont_touch = "true" *)
    logic signed [63:0] pll_ext_s3a;

    logic v_s3a;

    logic [32:0] upper_sum_hi_sum_c;

    logic signed [63:0] upper_sum_c;
    logic signed [63:0] upper_sum_r;

    (* dont_touch = "true" *)
    logic signed [63:0] pll_ext_r;

    logic v_s3;

    always_comb begin
        phh_ext =
            {{30{phh_r2[33]}}, phh_r2};

        pll_ext =
            {{30{pll_r2[33]}}, pll_r2};

        cross_sum_ext_c =
            $signed({
                {29{cross_sum_r[34]}},
                cross_sum_r
            });

        term1_c =
            phh_ext <<< 32;

        term2_c =
            cross_sum_ext_c <<< 16;

        upper_sum_lo_sum_c =
            {1'b0, term1_c[31:0]} +
            {1'b0, term2_c[31:0]};

        upper_sum_lo_c =
            upper_sum_lo_sum_c[31:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upper_sum_lo_r    <= '0;
            term1_hi_r        <= '0;
            term2_hi_r        <= '0;
            upper_sum_carry_r <= 1'b0;
            pll_ext_s3a       <= '0;
            v_s3a             <= 1'b0;
        end else begin
            upper_sum_lo_r    <= upper_sum_lo_c;
            term1_hi_r        <= term1_c[63:32];
            term2_hi_r        <= term2_c[63:32];
            upper_sum_carry_r <= upper_sum_lo_sum_c[32];
            pll_ext_s3a       <= pll_ext;
            v_s3a             <= v_s2b;
        end
    end

    always_comb begin
        upper_sum_hi_sum_c =
            {1'b0, term1_hi_r} +
            {1'b0, term2_hi_r} +
            upper_sum_carry_r;

        upper_sum_c =
            {upper_sum_hi_sum_c[31:0], upper_sum_lo_r};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upper_sum_r <= '0;
            pll_ext_r <= '0;
            v_s3 <= 1'b0;
        end else begin
            upper_sum_r <= upper_sum_c;
            pll_ext_r <= pll_ext_s3a;
            v_s3 <= v_s3a;
        end
    end

    logic [32:0] final_low_sum_c;
    logic [31:0] final_low_c;
    logic [31:0] final_low_r;

    logic [31:0] final_high_a_r;
    logic [31:0] final_high_b_r;
    logic final_carry_r;

    logic v_s4;

    always_comb begin
        final_low_sum_c =
            {1'b0, upper_sum_r[31:0]} +
            {1'b0, pll_ext_r[31:0]};

        final_low_c =
            final_low_sum_c[31:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_low_r <= '0;
            final_high_a_r <= '0;
            final_high_b_r <= '0;
            final_carry_r <= 1'b0;
            v_s4 <= 1'b0;
        end else begin
            final_low_r <= final_low_c;
            final_high_a_r <= upper_sum_r[63:32];
            final_high_b_r <= pll_ext_r[63:32];
            final_carry_r <= final_low_sum_c[32];
            v_s4 <= v_s3;
        end
    end

    logic [16:0] final_high_lo_sum_c;
    logic [15:0] final_high_lo_c;

    (* dont_touch = "true" *)
    logic [15:0] final_high_lo_r;

    logic [15:0] final_high_a_hi_r;
    logic [15:0] final_high_b_hi_r;
    logic final_high_carry_r;

    (* dont_touch = "true" *)
    logic [31:0] final_low_r2;

    logic v_s4b;

    always_comb begin
        final_high_lo_sum_c =
            {1'b0, final_high_a_r[15:0]} +
            {1'b0, final_high_b_r[15:0]} +
            final_carry_r;

        final_high_lo_c =
            final_high_lo_sum_c[15:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_high_lo_r    <= '0;
            final_high_a_hi_r  <= '0;
            final_high_b_hi_r  <= '0;
            final_high_carry_r <= 1'b0;
            final_low_r2       <= '0;
            v_s4b              <= 1'b0;
        end else begin
            final_high_lo_r    <= final_high_lo_c;
            final_high_a_hi_r  <= final_high_a_r[31:16];
            final_high_b_hi_r  <= final_high_b_r[31:16];
            final_high_carry_r <= final_high_lo_sum_c[16];
            final_low_r2       <= final_low_r;
            v_s4b              <= v_s4;
        end
    end

    logic [15:0] final_high_hi_c;
    logic [31:0] final_high_c;

    logic signed [63:0] p_r;
    logic v_s5;

    always_comb begin
        final_high_hi_c =
            final_high_a_hi_r +
            final_high_b_hi_r +
            final_high_carry_r;

        final_high_c =
            {final_high_hi_c, final_high_lo_r};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_r <= '0;
            v_s5 <= 1'b0;
        end else begin
            p_r <= {final_high_c, final_low_r2};
            v_s5 <= v_s4b;
        end
    end

    assign p = p_r;
    assign out_valid = v_s5;

endmodule


module q16_16_two_minus (
    input logic clk,
    input logic rst_n,
    input logic in_valid,
    input logic signed [31:0] d,
    output logic out_valid,
    output logic signed [31:0] f
);

    localparam logic signed [31:0] TWO = 32'sh0002_0000;

    logic [15:0] low_r;
    logic [15:0] high_in_r;
    logic borrow_r;
    logic v_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            low_r     <= '0;
            high_in_r <= '0;
            borrow_r  <= 1'b0;
            v_s1      <= 1'b0;
        end else begin
            low_r <=
                TWO[15:0] -
                d[15:0];

            high_in_r <=
                d[31:16];

            borrow_r <=
                (TWO[15:0] < d[15:0]);

            v_s1 <=
                in_valid;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f <= '0;
            out_valid <= 1'b0;
        end else begin
            f <= {
                TWO[31:16] -
                high_in_r -
                borrow_r,
                low_r
            };

            out_valid <=
                v_s1;
        end
    end

endmodule


module reciprocal_gs_q16_16 #(
    parameter int IDX_BITS = 9,
    parameter int SHIFT = 8
) (
    input logic clk,
    input logic rst_n,
    input logic valid_in,
    input logic [31:0] x_in,
    output logic valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO =
        32'h0000_8000;

    localparam logic [31:0] X_HI =
        32'h0002_8000;

    localparam int N =
        (1 << IDX_BITS);

    localparam int L = 14;

    localparam int SUB_LATENCY = 2;

    // ------------------------------------------------------------
    // Input/front-end registers
    // ------------------------------------------------------------

    logic [31:0] x_r0;

    // Dedicated copy used ONLY for offset calculation.
    // Prevent Vivado from merging it back into the comparator copy.
    (* dont_touch = "true" *)
    logic [31:0] x_r0_offset;

    // Dedicated copy used ONLY for range comparisons.
    (* max_fanout = 6 *)
    logic [31:0] x_r0_cmp;

    logic v_r0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r0        <= '0;
            x_r0_offset <= '0;
            x_r0_cmp    <= '0;
            v_r0        <= 1'b0;
        end else begin
            x_r0        <= x_in;
            x_r0_offset <= x_in;
            x_r0_cmp    <= x_in;
            v_r0        <= valid_in;
        end
    end

    // ------------------------------------------------------------
    // Range detection
    // ------------------------------------------------------------

    logic below_r0;
    logic above_r0;
    logic [25:0] offset_comb;

    always_comb begin

        below_r0 =
            (x_r0_cmp < X_LO);

        above_r0 =
            (x_r0_cmp > X_HI);

        // IMPORTANT:
        // This path is now completely independent of the range
        // comparators. It is simply x - 0.5.
        offset_comb =
            x_r0_offset - X_LO;

    end

    // ------------------------------------------------------------
    // Stage R1
    // ------------------------------------------------------------

    logic [25:0] offset_r1;
    logic below_r1;
    logic above_r1;
    logic [31:0] x_r1;
    logic v_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset_r1 <= '0;
            below_r1  <= 1'b0;
            above_r1  <= 1'b0;
            x_r1      <= '0;
            v_r1      <= 1'b0;
        end else begin
            offset_r1 <= offset_comb;
            below_r1  <= below_r0;
            above_r1  <= above_r0;
            x_r1      <= x_r0;
            v_r1      <= v_r0;
        end
    end

    // ------------------------------------------------------------
    // LUT index
    // Q16.16:
    //   0.5 = 0x00008000
    //   2.5 = 0x00028000
    //
    // 512 entries => address = (x - 0.5) >> 8
    // ------------------------------------------------------------

    logic [IDX_BITS-1:0] idx_comb;
    logic [IDX_BITS-1:0] idx_r2;
    logic [IDX_BITS+3:0] idx_full;
    logic [31:0] x_r2;
    logic v_r2;

    always_comb begin

        idx_full =
            offset_r1 >> SHIFT;

        if (below_r1)
            idx_comb = '0;

        else if (
            above_r1 ||
            (idx_full > (N - 1))
        )
            idx_comb = N - 1;

        else
            idx_comb =
                idx_full[IDX_BITS-1:0];

    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2 <= '0;
            x_r2   <= '0;
            v_r2   <= 1'b0;
        end else begin
            idx_r2 <= idx_comb;
            x_r2   <= x_r1;
            v_r2   <= v_r1;
        end
    end

    // ------------------------------------------------------------
    // Seed ROM
    // ------------------------------------------------------------

    (* rom_style = "block" *)
    logic [31:0] seed_mem [0:N-1];

    initial begin

        $readmemh(
            "nr_seed.mem",
            seed_mem
        );

        // synthesis translate_off
        if (^seed_mem[0] === 1'bx)
            $fatal(
                1,
                "ERROR: nr_seed.mem failed to load."
            );
        // synthesis translate_on

    end

    logic [31:0] seed_dout;

    always_ff @(posedge clk) begin
        seed_dout <=
            seed_mem[idx_r2];
    end

    // ------------------------------------------------------------
    // Pipeline alignment for x and seed
    // ------------------------------------------------------------

    logic [31:0] x_r3;
    logic v_r3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r3 <= '0;
            v_r3 <= 1'b0;
        end else begin
            x_r3 <= x_r2;
            v_r3 <= v_r2;
        end
    end

    logic [31:0] y0_r4;

    always_ff @(posedge clk) begin
        y0_r4 <=
            seed_dout;
    end

    logic [31:0] x_r4;
    logic v_r4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r4 <= '0;
            v_r4 <= 1'b0;
        end else begin
            x_r4 <= x_r3;
            v_r4 <= v_r3;
        end
    end

    // ============================================================
    // Goldschmidt core
    //
    // D0 = x * y0
    // F0 = 2 - D0
    //
    // D1 = D0 * F0
    // N1 = N0 * F0
    //
    // F1 = 2 - D1
    //
    // N2 = N1 * F1
    //
    // N2 = final reciprocal
    // ============================================================

    // ------------------------------------------------------------
    // D0 = round(x * y0)
    // ------------------------------------------------------------

    logic signed [63:0] mult_d0_p;
    logic mult_d0_v;

    pipelined_mult32x32_signed u_mult_d0 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_r4),
        .a($signed(x_r4)),
        .b($signed(y0_r4)),
        .out_valid(mult_d0_v),
        .p(mult_d0_p)
    );

    logic signed [31:0] d0_r;
    logic v_d0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d0_r <= '0;
            v_d0 <= 1'b0;
        end else begin

            // Q16.16:
            // 64-bit product >> 16
            d0_r <=
                $signed(mult_d0_p[47:16]);

            v_d0 <=
                mult_d0_v;

        end
    end

    // ------------------------------------------------------------
    // N0 alignment
    // ------------------------------------------------------------

    localparam int N0_D0_DEPTH =
        L + 1;

    logic [31:0] n0_align
        [0:N0_D0_DEPTH-1];

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            for (
                int i = 0;
                i < N0_D0_DEPTH;
                i++
            )
                n0_align[i] <= '0;

        end else begin

            n0_align[0] <=
                y0_r4;

            for (
                int i = 1;
                i < N0_D0_DEPTH;
                i++
            )
                n0_align[i] <=
                    n0_align[i-1];

        end

    end

    logic [31:0] n0_at_d0;

    assign n0_at_d0 =
        n0_align[N0_D0_DEPTH-1];

    // ------------------------------------------------------------
    // F0 = 2 - D0
    // ------------------------------------------------------------

    logic signed [31:0] f0_r;
    logic v_f0;

    q16_16_two_minus u_two_minus_0 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_d0),
        .d(d0_r),
        .out_valid(v_f0),
        .f(f0_r)
    );

    // ------------------------------------------------------------
    // Align D0 and N0 with F0
    // ------------------------------------------------------------

    (* srl_style = "register", shreg_extract = "no" *)
    logic signed [31:0] d0_align
        [0:SUB_LATENCY-1];

    (* srl_style = "register", shreg_extract = "no" *)
    logic [31:0] n0_align2
        [0:SUB_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            for (
                int i = 0;
                i < SUB_LATENCY;
                i++
            ) begin
                d0_align[i]  <= '0;
                n0_align2[i] <= '0;
            end

        end else begin

            d0_align[0] <=
                d0_r;

            n0_align2[0] <=
                n0_at_d0;

            for (
                int i = 1;
                i < SUB_LATENCY;
                i++
            ) begin
                d0_align[i] <=
                    d0_align[i-1];

                n0_align2[i] <=
                    n0_align2[i-1];
            end

        end

    end

    logic signed [31:0] d0_at_f0;
    logic [31:0] n0_at_f0;

    assign d0_at_f0 =
        d0_align[SUB_LATENCY-1];

    assign n0_at_f0 =
        n0_align2[SUB_LATENCY-1];

    // ------------------------------------------------------------
    // D1 = D0 * F0
    // N1 = N0 * F0
    //
    // These two multiplications are parallel.
    // ------------------------------------------------------------

    logic signed [63:0] mult_d1_p;
    logic signed [63:0] mult_n1_p;

    logic mult_d1_v;
    logic mult_n1_v;

    pipelined_mult32x32_signed u_mult_d1 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_f0),
        .a(d0_at_f0),
        .b(f0_r),
        .out_valid(mult_d1_v),
        .p(mult_d1_p)
    );

    pipelined_mult32x32_signed u_mult_n1 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_f0),
        .a($signed(n0_at_f0)),
        .b(f0_r),
        .out_valid(mult_n1_v),
        .p(mult_n1_p)
    );

    logic signed [31:0] d1_r;
    logic signed [31:0] n1_r;
    logic v_dn1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_r  <= '0;
            n1_r  <= '0;
            v_dn1 <= 1'b0;
        end else begin

            d1_r <=
                $signed(mult_d1_p[47:16]);

            n1_r <=
                $signed(mult_n1_p[47:16]);

            v_dn1 <=
                mult_d1_v;

        end
    end

    // ------------------------------------------------------------
    // F1 = 2 - D1
    // ------------------------------------------------------------

    logic signed [31:0] f1_r;
    logic v_f1;

    q16_16_two_minus u_two_minus_1 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_dn1),
        .d(d1_r),
        .out_valid(v_f1),
        .f(f1_r)
    );

    // ------------------------------------------------------------
    // Align N1 with F1
    // ------------------------------------------------------------

    (* srl_style = "register", shreg_extract = "no" *)
    logic signed [31:0] n1_align
        [0:SUB_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            for (
                int i = 0;
                i < SUB_LATENCY;
                i++
            )
                n1_align[i] <= '0;

        end else begin

            n1_align[0] <=
                n1_r;

            for (
                int i = 1;
                i < SUB_LATENCY;
                i++
            )
                n1_align[i] <=
                    n1_align[i-1];

        end

    end

    logic signed [31:0] n1_at_f1;

    assign n1_at_f1 =
        n1_align[SUB_LATENCY-1];

    // ------------------------------------------------------------
    // N2 = N1 * F1
    // ------------------------------------------------------------

    logic signed [63:0] mult_n2_p;
    logic mult_n2_v;

    pipelined_mult32x32_signed u_mult_n2 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_f1),
        .a(n1_at_f1),
        .b(f1_r),
        .out_valid(mult_n2_v),
        .p(mult_n2_p)
    );

    logic signed [31:0] n2_r;
    logic v_out;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            n2_r  <= '0;
            v_out <= 1'b0;
        end else begin

            n2_r <=
                $signed(mult_n2_p[47:16]);

            v_out <=
                mult_n2_v;

        end

    end

    assign recip_out =
        n2_r;

    assign valid_out =
        v_out;

endmodule