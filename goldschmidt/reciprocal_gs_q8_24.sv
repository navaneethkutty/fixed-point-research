// ============================================================================
// Goldschmidt Q8.24 reciprocal
//
// Same seed table, same fixed-point format (Q8.24), same port list as
// reciprocal_nr_q8_24 -- the only thing that changes is the iteration.
//
// Newton-Raphson (original module) maintains a single value y and repeats
//     y_{n+1} = y_n * (2 - x*y_n)
// Each iteration needs x*y_n, which is a fresh multiply against the
// (delayed) original input x every time -- so the four multiplies in the
// two-iteration NR pipeline (x*y0, y0*e1, x*y1, y1*e2) are fully serial:
// mult2a cannot start until mult1b (which produces y1) has finished.
//
// Goldschmidt keeps two values, N and D, both initialized so that N/D is
// already the answer (N0 = y0, D0 = x*y0, so N0/D0 = 1/x), and repeats
//     F_n   = 2 - D_n
//     D_{n+1} = D_n * F_n
//     N_{n+1} = N_n * F_n
// D_n converges to 1 and N_n converges to 1/x at the same quadratic rate
// as NR (in fact N_{n+1} here is bit-for-bit the same value as NR's
// y_{n+1}: D_n = x*N_n always, so F_n = 2 - x*N_n = NR's error term).
// The difference is structural: D_{n+1} = D_n*F_n uses two values that are
// *already sitting in the pipeline* -- it does not need a fresh multiply
// against a re-delayed copy of x. That means:
//   - the long x_align/y0_align/y1_align delay lines the NR version needs
//     to keep re-presenting x for mult2a go away;
//   - D_{n+1} and N_{n+1} depend on nothing but D_n/N_n and F_n, so they
//     can be computed by two independent multiplier instances running in
//     parallel, instead of NR's four-deep serial chain of multiplies.
//
// For two iterations this pipeline needs D0 (=x*y0), then {D1, N1} in
// parallel, then N2 -- three sequential multiply *stages* instead of NR's
// four, at the cost of one extra multiplier instance active at the same
// time (mult_d1 and mult_n1 run concurrently) and of D1 being computed
// even though only its role in producing F1 is needed (N/A for output).
//
// NOTE ON TIMING CLOSURE: the "2 - D" subtract below is split into two
// 16-bit half-subtracts with a registered borrow, in the same style the
// original file uses elsewhere (see its REV6/REV7 history) to keep any
// single combinational stage short. That split is a structural precaution
// copied from the existing pattern in this codebase, not a result derived
// from an actual Vivado timing report for this new pipeline -- run
// synthesis/timing analysis on your target part and clock period before
// trusting it at the same 2.580 ns period the NR module was closed at.
//
// REV8 timing fix: report_timing_summary on this pipeline showed
// WNS -0.167ns / TNS -0.329ns across 4 endpoints, all landing on
// n1_r_reg[*]_srl2_v_r1_reg_c/D -- i.e. Vivado had packed the SUB_LATENCY
// (=2) deep n1_align shift register (and, by the same reasoning,
// d0_align/n0_align2) into SRL16E primitives. A 2-deep chain gains
// negligible area from SRL packing, but the SRL16E's LUT-based
// address/config logic lands in series with the upstream CARRY4 chain
// that produces final_high_a_hi_r/final_high_b_hi_r out of u_mult_n1,
// pushing the data path to 2.664ns against a 2.580ns period. Fix: mark
// these shallow alignment arrays srl_style="register" / shreg_extract="no"
// so Vivado is forced to realize them as plain FDCE flip-flops instead.
// n0_align (depth N0_D0_DEPTH = L+1 = 15) is left untouched -- that one is
// a genuine long shift chain where SRL16E packing is the right call, same
// as cross_low_lo_r/cross_low_r/etc. in the multiplier below.
// ============================================================================
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

    // Total in_valid -> out_valid latency of this module, in clocks.
    // Recompute this by hand-walking every always_ff below if the pipeline
    // ever changes -- reciprocal_nr_q8_24's alignment shift registers are
    // derived from this constant and will silently corrupt the result if
    // it drifts out of sync again (see REV1/REV2/REV3/REV4/REV6/REV7
    // history below).
    //
    //   3 (dsp_mult17x17_signed: AREG/BREG->MREG->PREG)
    // + 1 (m0 stage)
    // + 1 (m0b stage: byte-sliced low-16 partial add, REV4/REV5)
    // + 1 (r0 stage, v_s1)
    // + 2 (alignment stage A+B, matches dsp_add18x18_signed's 2-cycle
    //      latency -- REV3)
    // + 1 (cross_sum_r / r2 stage, v_s2b)
    // + 1 (upper_sum s3a stage: low-32 partial add of upper_sum_c, REV6)
    // + 1 (upper_sum_r s3b stage: high-32 add + registered carry-in,
    //      v_s3 -- was the single "upper_sum_r stage" pre-REV6)
    // + 1 (final_low_r stage, v_s4)
    // + 1 (final_high s4b stage: low-16 partial add of final_high_c,
    //      registered carry-out -- REV7)
    // + 1 (p_r stage, v_s5 = out_valid: high-16 add + registered
    //      carry-in, forms final_high_c -- was combinational pre-REV7)
    // = 14
    localparam int MULT32_LATENCY = 14;

    localparam logic signed [47:0] ROUND_BIAS = 48'sd8388608;

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
    logic [25:0]         phl_up_m0b;
    logic [25:0]         plh_up_m0b;

    logic v_lo;

    always_comb begin
        cross_low_lo_sum = {1'b0, phl_m0[7:0]} + {1'b0, plh_m0[7:0]};
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
            {1'b0, phl_up_m0b[7:0]} + {1'b0, plh_up_m0b[7:0]} + cross_low_lo_carry_r;
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

    logic signed [33:0] phh_d1, pll_d1;
    (* srl_style = "register", shreg_extract = "no" *)
    logic [15:0] cross_low_d1;

    logic signed [33:0] phh_r1, pll_r1;
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

    // ------------------------------------------------------------------
    // REV6 timing fix: upper_sum_c was a single-cycle 64-bit ripple add
    // ((phh_ext<<32) + (cross_sum_ext<<16)), measuring 7 CARRY4 levels /
    // 2.410ns data path against a 2.580ns period -- WNS -0.046ns on
    // u_mult2a's phh_r2_reg[0] -> upper_sum_r_reg[55] path.
    //
    // Fix: split the SAME 64-bit add into two 32-bit adds across two
    // pipeline stages (s3a/s3b), the same technique already used for
    // final_low_sum_c/final_high_c further down this pipe and for
    // cross_low_sum in REV4. Stage s3a computes the low 32 bits and
    // registers the carry-out; stage s3b adds the high 32 bits plus that
    // registered carry-in. Binary addition associates this way, so
    //   {hi_sum, lo_sum} == term1 + term2
    // bit-for-bit -- upper_sum_r ends up numerically identical to before,
    // just arriving one cycle later. pll_ext is passed through the extra
    // stage (as pll_ext_s3a) so it stays aligned with upper_sum_r. Costs
    // 1 extra cycle, folded into MULT32_LATENCY (12 -> 13).
    // ------------------------------------------------------------------
    logic signed [63:0] phh_ext;
    logic signed [63:0] pll_ext;
    logic signed [63:0] cross_sum_ext_c;

    logic [63:0] term1_c;   // phh_ext <<< 32
    logic [63:0] term2_c;   // cross_sum_ext <<< 16

    logic [32:0] upper_sum_lo_sum_c;
    logic [31:0] upper_sum_lo_c;

    logic [31:0] upper_sum_lo_r;
    logic [31:0] term1_hi_r;
    logic [31:0] term2_hi_r;
    logic        upper_sum_carry_r;
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
        phh_ext = {{30{phh_r2[33]}}, phh_r2};
        pll_ext = {{30{pll_r2[33]}}, pll_r2};
        cross_sum_ext_c = $signed({{29{cross_sum_r[34]}}, cross_sum_r});

        term1_c = phh_ext <<< 32;
        term2_c = cross_sum_ext_c <<< 16;

        upper_sum_lo_sum_c = {1'b0, term1_c[31:0]} + {1'b0, term2_c[31:0]};
        upper_sum_lo_c = upper_sum_lo_sum_c[31:0];
    end

    // stage s3a: low 32 bits of the split add, plus carry-out
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
            {1'b0, term1_hi_r} + {1'b0, term2_hi_r} + upper_sum_carry_r;
        upper_sum_c = {upper_sum_hi_sum_c[31:0], upper_sum_lo_r};
    end

    // stage s3b (was the single "upper_sum_r stage" pre-REV6): high 32
    // bits, recombine into the full 64-bit upper_sum_r
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

        final_low_c = final_low_sum_c[31:0];
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

    // ------------------------------------------------------------------
    // REV7 timing fix: final_high_c was a single-cycle 32-bit ripple add
    // (final_high_a_r + final_high_b_r + final_carry_r), measuring 7
    // logic levels (LUT2 + 6x CARRY4) / 1.964ns data path against a
    // 2.580ns period -- WNS -0.004ns on
    // u_mult2b/final_carry_r_reg/C -> u_mult2b/p_r_reg[53]/D.
    //
    // Fix: same technique as the REV6 upper_sum_c split. Split the
    // 32-bit add into two 16-bit adds across two pipeline stages
    // (s4b/s5). Stage s4b computes the low 16 bits and registers the
    // carry-out; the final stage (s5, formerly combinational) adds the
    // high 16 bits plus that registered carry-in to form final_high_c.
    // final_low_r has to ride one extra register (final_low_r2) so it
    // stays aligned with final_high_c, which now arrives a cycle later.
    // Costs 1 extra cycle, folded into MULT32_LATENCY (13 -> 14).
    //
    // Gotcha, round 1: final_low_r2 <= final_low_r is a pure
    // register-to-register copy with no logic in between -- exactly the
    // pattern shreg_extract looks for. Left unmarked, Vivado folded it
    // into an SRL16E, erasing the intended stage boundary and causing a
    // *worse* violation (WNS -0.332ns, 56 endpoints) on an unrelated
    // upper_sum_r path.
    //
    // Gotcha, round 2: marking it srl_style/shreg_extract="no" stopped
    // the SRL16E, but the same passthrough shape (register a value, then
    // pass it unchanged into the next register with zero intervening
    // logic) is also exactly what register-retiming targets -- a
    // different optimizer pass that shreg_extract does NOT touch. This
    // time it hit final_high_lo_r (also introduced in REV7): its s4b
    // register got retimed forward and fused into p_r's FDRE, collapsing
    // the intended 2-cycle low/high split back into one overloaded cycle
    // (WNS -0.385ns). The fix that actually pins a register in place
    // against both SRL extraction AND retiming is dont_touch, not
    // shreg_extract. Every pure-passthrough register on this path --
    // final_high_lo_r, final_low_r2, and REV6's pll_ext_s3a/pll_ext_r --
    // now carries dont_touch. (cross_low_lo_r/cross_low_r/cross_low_d1/
    // cross_low_r2 above still use srl_style/shreg_extract only, since
    // those are genuine multi-tap shift chains and haven't shown this
    // retiming failure mode -- but they'd be the next place to look if a
    // future re-synth surfaces something similar there.)
    // ------------------------------------------------------------------
    logic [16:0] final_high_lo_sum_c;
    logic [15:0] final_high_lo_c;

    (* dont_touch = "true" *)
    logic [15:0] final_high_lo_r;
    logic [15:0] final_high_a_hi_r;
    logic [15:0] final_high_b_hi_r;
    logic        final_high_carry_r;
    (* dont_touch = "true" *)
    logic [31:0] final_low_r2;
    logic v_s4b;

    always_comb begin
        final_high_lo_sum_c =
            {1'b0, final_high_a_r[15:0]} +
            {1'b0, final_high_b_r[15:0]} +
            final_carry_r;
        final_high_lo_c = final_high_lo_sum_c[15:0];
    end

    // stage s4b: low 16 bits of the split add, plus carry-out
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

    // final stage: high 16 bits + registered carry-in, forms
    // final_high_c (was fully combinational pre-REV7)
    always_comb begin
        final_high_hi_c =
            final_high_a_hi_r +
            final_high_b_hi_r +
            final_high_carry_r;
        final_high_c = {final_high_hi_c, final_high_lo_r};
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


module q8_24_two_minus (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [31:0] d,
    output logic out_valid,
    output logic signed [31:0] f
);

    localparam logic signed [31:0] TWO = 32'sh0200_0000;

    // stage 1: low 16-bit half-subtract, plus registered borrow
    logic [15:0] low_r;
    logic [15:0] high_in_r;
    logic        borrow_r;
    logic        v_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            low_r     <= '0;
            high_in_r <= '0;
            borrow_r  <= 1'b0;
            v_s1      <= 1'b0;
        end else begin
            low_r     <= TWO[15:0] - d[15:0];
            high_in_r <= d[31:16];
            borrow_r  <= (TWO[15:0] < d[15:0]);
            v_s1      <= in_valid;
        end
    end

    // stage 2: high 16-bit half-subtract using the registered borrow,
    // recombine into the full 32-bit result
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f         <= '0;
            out_valid <= 1'b0;
        end else begin
            f         <= {TWO[31:16] - high_in_r - borrow_r, low_r};
            out_valid <= v_s1;
        end
    end

endmodule


module reciprocal_gs_q8_24 #(
    parameter int IDX_BITS = 8,
    parameter int SHIFT = 17
) (
    input logic clk,
    input logic rst_n,
    input logic valid_in,
    input logic [31:0] x_in,
    output logic valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO = 32'h0080_0000;
    localparam logic [31:0] X_HI = 32'h0280_0000;
    localparam int N = (1 << IDX_BITS);

    // Latency of pipelined_mult32x32_signed (in_valid -> out_valid).
    // Must always equal pipelined_mult32x32_signed::MULT32_LATENCY.
    localparam int L = 14;

    // Latency of q8_24_two_minus (in_valid -> out_valid).
    localparam int SUB_LATENCY = 2;

    // --------------------------------------------------------------------
    // Seed lookup pipeline -- identical to reciprocal_nr_q8_24: the seed
    // table doesn't depend on which iteration (NR or Goldschmidt) refines
    // it afterwards, so this stage is reused verbatim.
    //
    // REV9 timing fix: report_timing_summary showed WNS -0.024ns / TNS
    // -0.024ns, 1 failing endpoint, on x_r0_reg[23]/C -> above_r1_reg/D.
    // Logic Levels was only 3 (LUT2=1, LUT6=2) and logic delay was just
    // 0.828ns of the 2.559ns path -- route delay was 1.731ns (67.6% of
    // the path). This is NOT a wide-adder/CARRY4 problem like REV1-REV8;
    // it's a fanout/placement problem. x_r0 has fo=14: it simultaneously
    // feeds the x_r1 passthrough register, the offset_comb subtractor,
    // AND the above_r0/below_r0 comparators. That shared fanout forces
    // the placer to compromise x_r0's location between all three
    // consumers instead of letting the comparator's copy sit right next
    // to the above_r1_i_7/i_5/i_1 LUT cluster it feeds.
    //
    // Fix: give the comparators their own dedicated register (x_r0_cmp)
    // that is bit-identical to x_r0 but has no other fanout. This is a
    // pure duplication -- x_r0 still drives x_r1 and offset_comb exactly
    // as before -- so it costs zero extra latency and does not touch L,
    // SUB_LATENCY, or anything in the Goldschmidt core downstream.
    // max_fanout additionally stops Vivado's optimizer from merging
    // x_r0_cmp back into x_r0 during synthesis, which would silently
    // undo the fix.
    // --------------------------------------------------------------------
    logic [31:0] x_r0;
    (* max_fanout = 6 *) logic [31:0] x_r0_cmp;
    logic v_r0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r0     <= '0;
            x_r0_cmp <= '0;
            v_r0     <= 1'b0;
        end else begin
            x_r0     <= x_in;
            x_r0_cmp <= x_in;
            v_r0     <= valid_in;
        end
    end

    logic below_r0;
    logic above_r0;
    logic [25:0] offset_comb;

    always_comb begin
        below_r0    = (x_r0_cmp < X_LO);
        above_r0    = (x_r0_cmp > X_HI);
        offset_comb = below_r0 ? 26'd0 : (x_r0 - X_LO);
    end

    logic [25:0] offset_r1;
    logic above_r1;
    logic [31:0] x_r1;
    logic v_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset_r1 <= '0;
            above_r1 <= 1'b0;
            x_r1 <= '0;
            v_r1 <= 1'b0;
        end else begin
            offset_r1 <= offset_comb;
            above_r1 <= above_r0;
            x_r1 <= x_r0;
            v_r1 <= v_r0;
        end
    end

    logic [IDX_BITS-1:0] idx_comb;
    logic [IDX_BITS-1:0] idx_r2;
    logic [IDX_BITS+3:0] idx_full;
    logic [31:0] x_r2;
    logic v_r2;

    always_comb begin
        idx_full = offset_r1 >> SHIFT;

        idx_comb =
            (above_r1 || (idx_full > (N - 1)))
            ? (N - 1)
            : idx_full[IDX_BITS-1:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2 <= '0;
            x_r2 <= '0;
            v_r2 <= 1'b0;
        end else begin
            idx_r2 <= idx_comb;
            x_r2 <= x_r1;
            v_r2 <= v_r1;
        end
    end

    (* rom_style = "block" *)
    logic [31:0] seed_mem [0:N-1];

    initial begin
        $readmemh("nr_seed.mem", seed_mem);
        // synthesis translate_off
        if (^seed_mem[0] === 1'bx)
            $fatal(1, "ERROR: nr_seed.mem failed to load.");
        // synthesis translate_on
    end

    logic [31:0] seed_dout;

    always_ff @(posedge clk) begin
        seed_dout <= seed_mem[idx_r2];
    end

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
        y0_r4 <= seed_dout;
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

    // ======================================================================
    // Goldschmidt core.
    //
    //   D0 = round(x   * y0)                        [1 multiply]
    //   N0 = y0                                      [no multiply]
    //   F0 = 2 - D0
    //   D1 = round(D0  * F0)   N1 = round(N0 * F0)   [2 multiplies, parallel]
    //   F1 = 2 - D1
    //   N2 = round(N1  * F1)                         [1 multiply]  <- answer
    // ======================================================================

    // ---- D0 = round(x_r4 * y0_r4) --------------------------------------
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
            d0_r <= $signed(mult_d0_p[55:24]);
            v_d0 <= mult_d0_v;
        end
    end

    // N0 = y0_r4, delayed to arrive on the same cycle as d0_r (L cycles
    // for the multiply + 1 cycle for the d0_r rounding register). Depth
    // is 15 -- a genuine long shift chain, so SRL16E packing here is the
    // right call and this array is left alone.
    localparam int N0_D0_DEPTH = L + 1;
    logic [31:0] n0_align [0:N0_D0_DEPTH-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N0_D0_DEPTH; i++) n0_align[i] <= '0;
        end else begin
            n0_align[0] <= y0_r4;
            for (int i = 1; i < N0_D0_DEPTH; i++) n0_align[i] <= n0_align[i-1];
        end
    end

    logic [31:0] n0_at_d0;
    assign n0_at_d0 = n0_align[N0_D0_DEPTH-1];

    // ---- F0 = 2 - D0 -----------------------------------------------------
    logic signed [31:0] f0_r;
    logic v_f0;

    q8_24_two_minus u_two_minus_0 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_d0),
        .d(d0_r),
        .out_valid(v_f0),
        .f(f0_r)
    );

    // d0_r and n0_at_d0 both need to ride SUB_LATENCY (=2) more cycles to
    // line up with f0_r. REV8: forced to plain FFs -- a 2-deep chain
    // gains negligible area from SRL16E packing, but the SRL16E's
    // LUT-based address/config logic was landing in series with the
    // upstream CARRY4 chain and blowing setup on this path.
    (* srl_style = "register", shreg_extract = "no" *)
    logic signed [31:0] d0_align [0:SUB_LATENCY-1];
    (* srl_style = "register", shreg_extract = "no" *)
    logic        [31:0] n0_align2 [0:SUB_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SUB_LATENCY; i++) begin
                d0_align[i]  <= '0;
                n0_align2[i] <= '0;
            end
        end else begin
            d0_align[0]  <= d0_r;
            n0_align2[0] <= n0_at_d0;
            for (int i = 1; i < SUB_LATENCY; i++) begin
                d0_align[i]  <= d0_align[i-1];
                n0_align2[i] <= n0_align2[i-1];
            end
        end
    end

    logic signed [31:0] d0_at_f0;
    logic        [31:0] n0_at_f0;
    assign d0_at_f0 = d0_align[SUB_LATENCY-1];
    assign n0_at_f0 = n0_align2[SUB_LATENCY-1];

    // ---- D1 = round(D0*F0), N1 = round(N0*F0) -- independent, parallel --
    logic signed [63:0] mult_d1_p, mult_n1_p;
    logic mult_d1_v, mult_n1_v;

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

    logic signed [31:0] d1_r, n1_r;
    logic v_dn1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_r  <= '0;
            n1_r  <= '0;
            v_dn1 <= 1'b0;
        end else begin
            d1_r  <= $signed(mult_d1_p[55:24]);
            n1_r  <= $signed(mult_n1_p[55:24]);
            // mult_d1_v and mult_n1_v are the same signal delayed by the
            // same fixed latency L from the same v_f0 pulse, so they
            // always agree; either can drive the joint valid.
            v_dn1 <= mult_d1_v;
        end
    end

    // ---- F1 = 2 - D1 -------------------------------------------------
    logic signed [31:0] f1_r;
    logic v_f1;

    q8_24_two_minus u_two_minus_1 (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(v_dn1),
        .d(d1_r),
        .out_valid(v_f1),
        .f(f1_r)
    );

    // n1_r needs to ride SUB_LATENCY (=2) more cycles to line up with
    // f1_r. REV8: this was the array actually named in the failing
    // report_timing_summary path (n1_r_reg[31]_srl2_v_r1_reg_c/D, WNS
    // -0.167ns / TNS -0.329ns, 4 endpoints) -- forced to plain FFs for
    // the same reason as d0_align/n0_align2 above.
    (* srl_style = "register", shreg_extract = "no" *)
    logic signed [31:0] n1_align [0:SUB_LATENCY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SUB_LATENCY; i++) n1_align[i] <= '0;
        end else begin
            n1_align[0] <= n1_r;
            for (int i = 1; i < SUB_LATENCY; i++) n1_align[i] <= n1_align[i-1];
        end
    end

    logic signed [31:0] n1_at_f1;
    assign n1_at_f1 = n1_align[SUB_LATENCY-1];

    // ---- N2 = round(N1*F1) -- final answer ------------------------------
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
            n2_r  <= $signed(mult_n2_p[55:24]);
            v_out <= mult_n2_v;
        end
    end

    assign recip_out = n2_r;
    assign valid_out = v_out;

endmodule