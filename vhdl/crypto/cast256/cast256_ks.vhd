-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_ks                                                       │
-- │                                                                  │
-- │ CAST-256 key schedule (RFC 2612).                                │
-- │ Processes 24 octaves (w_octave calls), each with 8 sequential    │
-- │ f-functions, followed by subkey extraction after every odd       │
-- │ octave (12 extractions total).                                   │
-- │                                                                  │
-- │ S-boxes are implemented as Block RAM (RAMB18, 256×32 each).      │
-- │ Each f-function takes 2 cycles: ADDR (drive address) then        │
-- │ COMPUTE (BRAM output valid, apply arithmetic).                   │
-- │                                                                  │
-- │ Latency: ~396 clock cycles (384 ADDR/COMPUTE + 12 SUBKEY)        │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cast256_pkg.all;

-- ┌─────────────────────────────────┐
-- │ Entity                          │
-- └─────────────────────────────────┘
entity cast256_ks is
    port (
        aclk    : in  std_ulogic;
        aresetn : in  std_ulogic;
        key     : in  std_ulogic_vector(255 downto 0);
        start   : in  std_ulogic;
        done    : out std_ulogic;
        kr_o    : out kr_array_t;
        km_o    : out km_array_t
    );
end entity cast256_ks;

-- ┌─────────────────────────────────┐
-- │ Architecture                    │
-- └─────────────────────────────────┘
architecture rtl of cast256_ks is

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ S-box BRAM signals                                              │
    -- │                                                                 │
    -- │ Same inference strategy as cast256_enc: 256×32 ROMs             │
    -- │ initialized from package constants, mapped to RAMB18.           │
    -- │ Combinatorial address inputs, registered output (1-cycle).      │
    -- └─────────────────────────────────────────────────────────────────┘
    signal SBOX1_r : sbox_t := SBOX1;
    signal SBOX2_r : sbox_t := SBOX2;
    signal SBOX3_r : sbox_t := SBOX3;
    signal SBOX4_r : sbox_t := SBOX4;

    attribute ram_style : string;
    attribute ram_style of SBOX1_r : signal is "block";
    attribute ram_style of SBOX2_r : signal is "block";
    attribute ram_style of SBOX3_r : signal is "block";
    attribute ram_style of SBOX4_r : signal is "block";

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ FSM                                                             │
    -- │                                                                 │
    -- │ IDLE            : wait for start, latch key into kappa_reg      │
    -- │ ADDR            : addr_comb drives BRAM addresses               │
    -- │ COMPUTE         : BRAM outputs valid; apply f-function          │
    -- │ SUBKEY_EXTRACT  : extract kr/km from kappa after each odd       │
    -- │                   octave (runs 12 times total)                  │
    -- │ ST_DONE         : assert done                                   │
    -- └─────────────────────────────────────────────────────────────────┘
    type ks_state_t is (IDLE, ADDR, COMPUTE, SUBKEY_EXTRACT, ST_DONE);
    signal state : ks_state_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Counters                                                        │
    -- └─────────────────────────────────────────────────────────────────┘
    signal ks_octave  : integer range 0 to 23;  -- current octave (0..23)
    signal f_ctr      : integer range 0 to 7;   -- f-function within octave (0..7)
    signal subkey_ctr : integer range 0 to 11;  -- subkey extraction index (0..11)

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ State registers                                                 │
    -- └─────────────────────────────────────────────────────────────────┘
    signal kappa_reg : kappa_t;
    signal kr_reg    : kr_array_t;
    signal km_reg    : km_array_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ BRAM interface                                                  │
    -- └─────────────────────────────────────────────────────────────────┘
    signal addr_a : integer range 0 to 255;
    signal addr_b : integer range 0 to 255;
    signal addr_c : integer range 0 to 255;
    signal addr_d : integer range 0 to 255;

    signal s1_out : word32_t;
    signal s2_out : word32_t;
    signal s3_out : word32_t;
    signal s4_out : word32_t;

begin

    -- ── Outputs ───────────────────────────────────────────────────────
    kr_o <= kr_reg;
    km_o <= km_reg;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ bram_read                                                       ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    bram_read : process(aclk) is
    begin
        if rising_edge(aclk) then
            s1_out <= SBOX1_r(addr_a);
            s2_out <= SBOX2_r(addr_b);
            s3_out <= SBOX3_r(addr_c);
            s4_out <= SBOX4_r(addr_d);
        end if;
    end process bram_read;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ addr_comb                                                       ║
    -- ║                                                                 ║
    -- ║ Active in ADDR state. Computes I for the current f-function     ║
    -- ║ and drives the 4 BRAM address inputs.                           ║
    -- ║                                                                 ║
    -- ║ f-function sequence within each octave (f_ctr 0..7):            ║
    -- ║   f_ctr 0 : f1(kappa.h) → kappa.g                               ║
    -- ║   f_ctr 1 : f2(kappa.g) → kappa.f                               ║
    -- ║   f_ctr 2 : f3(kappa.f) → kappa.e                               ║
    -- ║   f_ctr 3 : f1(kappa.e) → kappa.d                               ║
    -- ║   f_ctr 4 : f2(kappa.d) → kappa.c                               ║
    -- ║   f_ctr 5 : f3(kappa.c) → kappa.b                               ║
    -- ║   f_ctr 6 : f1(kappa.b) → kappa.a                               ║
    -- ║   f_ctr 7 : f2(kappa.a) → kappa.h                               ║
    -- ║                                                                 ║
    -- ║ f-type: f_ctr rem 3 → 0=f1  1=f2  2=f3                          ║
    -- ║ km/kr : TM(ks_octave)(f_ctr) / TR(ks_octave)(f_ctr)             ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    addr_comb : process(state, ks_octave, f_ctr, kappa_reg) is
        variable d_v   : word32_t;
        variable km_v  : word32_t;
        variable kr_v  : word5_t;
        variable i_val : word32_t;
    begin
        addr_a <= 0;
        addr_b <= 0;
        addr_c <= 0;
        addr_d <= 0;

        if state = ADDR then
            -- ── Select input kappa word ─────────────────────────────────
            case f_ctr is
                when 0 => d_v := kappa_reg.h;
                when 1 => d_v := kappa_reg.g;
                when 2 => d_v := kappa_reg.f;
                when 3 => d_v := kappa_reg.e;
                when 4 => d_v := kappa_reg.d;
                when 5 => d_v := kappa_reg.c;
                when 6 => d_v := kappa_reg.b;
                when 7 => d_v := kappa_reg.a;
            end case;

            km_v := TM(ks_octave)(f_ctr);
            kr_v := TR(ks_octave)(f_ctr);

            -- ── Compute I (f_ctr rem 3: 0→f1  1→f2  2→f3) ─────────────
            case f_ctr rem 3 is
                when 0 =>  -- f1 : I = (km + d) <<< kr
                    i_val := rotate_left32(
                        std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                when 1 =>  -- f2 : I = (km ^ d) <<< kr
                    i_val := rotate_left32(km_v xor d_v, kr_v);
                when 2 =>  -- f3 : I = (km - d) <<< kr
                    i_val := rotate_left32(
                        std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                when others =>
                    i_val := (others => '0');
            end case;

            addr_a <= to_integer(unsigned(i_val(31 downto 24)));
            addr_b <= to_integer(unsigned(i_val(23 downto 16)));
            addr_c <= to_integer(unsigned(i_val(15 downto  8)));
            addr_d <= to_integer(unsigned(i_val( 7 downto  0)));
        end if;
    end process addr_comb;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ main_fsm                                                        ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    main_fsm : process(aclk) is
        variable s1v, s2v, s3v, s4v : unsigned(31 downto 0);
        variable f_result            : word32_t;
        variable i                   : integer;
        variable j                   : integer;
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state       <= IDLE;
                ks_octave   <= 0;
                f_ctr       <= 0;
                subkey_ctr  <= 0;
                done        <= '0';
                kappa_reg.a <= (others => '0');
                kappa_reg.b <= (others => '0');
                kappa_reg.c <= (others => '0');
                kappa_reg.d <= (others => '0');
                kappa_reg.e <= (others => '0');
                kappa_reg.f <= (others => '0');
                kappa_reg.g <= (others => '0');
                kappa_reg.h <= (others => '0');
                for i in 0 to 11 loop
                    for j in 0 to 3 loop
                        kr_reg(i)(j) <= (others => '0');
                        km_reg(i)(j) <= (others => '0');
                    end loop;
                end loop;
            else
                case state is

                    -- ── IDLE ───────────────────────────────────────────
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            kappa_reg.a <= key(255 downto 224);
                            kappa_reg.b <= key(223 downto 192);
                            kappa_reg.c <= key(191 downto 160);
                            kappa_reg.d <= key(159 downto 128);
                            kappa_reg.e <= key(127 downto  96);
                            kappa_reg.f <= key( 95 downto  64);
                            kappa_reg.g <= key( 63 downto  32);
                            kappa_reg.h <= key( 31 downto   0);
                            ks_octave   <= 0;
                            f_ctr       <= 0;
                            subkey_ctr  <= 0;
                            state       <= ADDR;
                        end if;

                    -- ── ADDR ───────────────────────────────────────────
                    -- addr_comb drives addr_a..d this cycle.
                    -- BRAM outputs will be valid in COMPUTE.
                    when ADDR =>
                        state <= COMPUTE;

                    -- ── COMPUTE ────────────────────────────────────────
                    -- BRAM outputs are valid. Compute the f-function
                    -- output and XOR it into the target kappa word.
                    when COMPUTE =>
                        s1v := unsigned(s1_out);
                        s2v := unsigned(s2_out);
                        s3v := unsigned(s3_out);
                        s4v := unsigned(s4_out);

                        -- f-function output formula (f_ctr rem 3)
                        case f_ctr rem 3 is
                            when 0 =>  -- f1 : ((S1^S2)-S3)+S4
                                f_result := std_ulogic_vector(
                                    (s1v xor s2v) - s3v + s4v);
                            when 1 =>  -- f2 : ((S1-S2)+S3)^S4
                                f_result := std_ulogic_vector(
                                    ((s1v - s2v) + s3v) xor s4v);
                            when 2 =>  -- f3 : ((S1+S2)^S3)-S4
                                f_result := std_ulogic_vector(
                                    ((s1v + s2v) xor s3v) - s4v);
                            when others =>
                                f_result := (others => '0');
                        end case;

                        -- XOR result into target kappa word
                        case f_ctr is
                            when 0 => kappa_reg.g <= kappa_reg.g xor f_result;
                            when 1 => kappa_reg.f <= kappa_reg.f xor f_result;
                            when 2 => kappa_reg.e <= kappa_reg.e xor f_result;
                            when 3 => kappa_reg.d <= kappa_reg.d xor f_result;
                            when 4 => kappa_reg.c <= kappa_reg.c xor f_result;
                            when 5 => kappa_reg.b <= kappa_reg.b xor f_result;
                            when 6 => kappa_reg.a <= kappa_reg.a xor f_result;
                            when 7 => kappa_reg.h <= kappa_reg.h xor f_result;
                        end case;

                        -- Advance within the octave or to next state
                        if f_ctr < 7 then
                            f_ctr <= f_ctr + 1;
                            state <= ADDR;
                        else
                            -- Completed last f-function of this octave
                            f_ctr <= 0;
                            if ks_octave rem 2 = 1 then
                                -- Odd octave: subkey extraction required
                                -- Only increment ks_octave when not at 23
                                -- (avoid range overflow; we are done after 23)
                                if ks_octave < 23 then
                                    ks_octave <= ks_octave + 1;
                                end if;
                                state <= SUBKEY_EXTRACT;
                            else
                                -- Even octave: proceed to the next octave directly
                                ks_octave <= ks_octave + 1;
                                state     <= ADDR;
                            end if;
                        end if;

                    -- ── SUBKEY_EXTRACT ─────────────────────────────────
                    -- kappa_reg has all 8 updates from the completed odd
                    -- octave applied (signal assignments from COMPUTE took
                    -- effect before this rising edge).
                    --
                    -- RFC 2612 Section 2.4:
                    --   Kr(i) = { A[4:0], C[4:0], E[4:0], G[4:0] }
                    --   Km(i) = { H,      F,      D,      B      }
                    when SUBKEY_EXTRACT =>
                        kr_reg(subkey_ctr)(0) <= kappa_reg.a(4 downto 0);
                        kr_reg(subkey_ctr)(1) <= kappa_reg.c(4 downto 0);
                        kr_reg(subkey_ctr)(2) <= kappa_reg.e(4 downto 0);
                        kr_reg(subkey_ctr)(3) <= kappa_reg.g(4 downto 0);
                        km_reg(subkey_ctr)(0) <= kappa_reg.h;
                        km_reg(subkey_ctr)(1) <= kappa_reg.f;
                        km_reg(subkey_ctr)(2) <= kappa_reg.d;
                        km_reg(subkey_ctr)(3) <= kappa_reg.b;

                        if subkey_ctr = 11 then
                            state <= ST_DONE;
                        else
                            subkey_ctr <= subkey_ctr + 1;
                            state      <= ADDR;
                        end if;

                    -- ── ST_DONE ────────────────────────────────────────
                    when ST_DONE =>
                        done <= '1';
                        if start = '1' then
                            kappa_reg.a <= key(255 downto 224);
                            kappa_reg.b <= key(223 downto 192);
                            kappa_reg.c <= key(191 downto 160);
                            kappa_reg.d <= key(159 downto 128);
                            kappa_reg.e <= key(127 downto  96);
                            kappa_reg.f <= key( 95 downto  64);
                            kappa_reg.g <= key( 63 downto  32);
                            kappa_reg.h <= key( 31 downto   0);
                            ks_octave   <= 0;
                            f_ctr       <= 0;
                            subkey_ctr  <= 0;
                            done        <= '0';
                            state       <= ADDR;
                        end if;

                end case;
            end if;
        end if;
    end process main_fsm;

end architecture rtl;
