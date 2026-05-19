-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_enc                                                      │
-- │                                                                  │
-- │ CAST-256 encryption datapath (RFC 2612).                         │
-- │ 6 forward quad-rounds (Q) followed by 6 reverse quad-rounds     │
-- │ (QBAR), for a total of 12 rounds × 4 f-functions = 48 steps.    │
-- │                                                                  │
-- │ S-boxes are implemented as Block RAM (RAMB18, 256×32 each).     │
-- │ Each f-function takes 2 cycles: ADDR (drive address) then        │
-- │ COMPUTE (BRAM output valid, apply arithmetic).                   │
-- │                                                                  │
-- │ Latency: 96 clock cycles per 128-bit block                       │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cast256_pkg.all;

-- ┌─────────────────────────────────┐
-- │ Entity                          │
-- └─────────────────────────────────┘
entity cast256_enc is
    port (
        aclk       : in  std_ulogic;
        aresetn    : in  std_ulogic;
        plaintext  : in  std_ulogic_vector(127 downto 0);
        kr_i       : in  kr_array_t;
        km_i       : in  km_array_t;
        start      : in  std_ulogic;
        ciphertext : out std_ulogic_vector(127 downto 0);
        done       : out std_ulogic
    );
end entity cast256_enc;

-- ┌─────────────────────────────────┐
-- │ Architecture                    │
-- └─────────────────────────────────┘
architecture rtl of cast256_enc is

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ S-box BRAM signals                                              │
    -- │                                                                 │
    -- │ Each signal is a 256×32 ROM initialized from the package        │
    -- │ constant of the same name. Never written after power-on.        │
    -- │                                                                 │
    -- │ ram_style = "block" → Vivado maps each to one RAMB18            │
    -- │ (256×32 = 8 kbit, fits comfortably in 18 kbit primitive).       │
    -- │                                                                 │
    -- │ Addresses are driven combinatorially by addr_comb.              │
    -- │ Outputs are registered inside bram_read:                        │
    -- │   address presented in ADDR state → output valid in COMPUTE     │
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
    -- │ FSM                                                              │
    -- │                                                                 │
    -- │ IDLE    : wait for start, latch plaintext into beta_reg         │
    -- │ ADDR    : addr_comb drives BRAM addresses combinatorially;      │
    -- │           bram_read samples them on this rising edge            │
    -- │ COMPUTE : s1_out..s4_out valid; apply f-function, update beta   │
    -- │ ST_DONE : assert done; accept back-to-back start                │
    -- └─────────────────────────────────────────────────────────────────┘
    type enc_state_t is (IDLE, ADDR, COMPUTE, ST_DONE);
    signal state : enc_state_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Counters                                                         │
    -- └─────────────────────────────────────────────────────────────────┘
    signal counter : integer range 0 to 11;  -- quad-round index (0..11)
    signal f_step  : integer range 0 to 3;   -- f-function within round (0..3)

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Data register                                                    │
    -- └─────────────────────────────────────────────────────────────────┘
    signal beta_reg : beta_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ BRAM interface                                                   │
    -- └─────────────────────────────────────────────────────────────────┘
    -- Byte-indexed addresses into each S-box (4 bytes of I)
    signal addr_a : integer range 0 to 255;
    signal addr_b : integer range 0 to 255;
    signal addr_c : integer range 0 to 255;
    signal addr_d : integer range 0 to 255;

    -- Registered BRAM outputs; valid 1 cycle after addresses are presented
    signal s1_out : word32_t;
    signal s2_out : word32_t;
    signal s3_out : word32_t;
    signal s4_out : word32_t;

begin

    -- ── Output ────────────────────────────────────────────────────────
    ciphertext <= beta_reg.a & beta_reg.b & beta_reg.c & beta_reg.d;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ bram_read                                                       ║
    -- ║                                                                 ║
    -- ║ Registered read from the 4 S-box BRAMs. addr_a..d are driven   ║
    -- ║ combinatorially by addr_comb. The rising edge that closes ADDR  ║
    -- ║ state samples those addresses; s1_out..s4_out are stable        ║
    -- ║ throughout the following COMPUTE state.                         ║
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
    -- ║ Combinatorial BRAM address driver. Active only in ADDR state.  ║
    -- ║                                                                 ║
    -- ║ Computes intermediate value I for the current f-function and   ║
    -- ║ drives the 4 byte-index address signals.                        ║
    -- ║                                                                 ║
    -- ║ Q round (counter 0..5):                                         ║
    -- ║   step 0 : f1(D,  kr(c)(0), km(c)(0))  target = C             ║
    -- ║   step 1 : f2(C', kr(c)(1), km(c)(1))  target = B             ║
    -- ║   step 2 : f3(B', kr(c)(2), km(c)(2))  target = A             ║
    -- ║   step 3 : f1(A', kr(c)(3), km(c)(3))  target = D             ║
    -- ║                                                                 ║
    -- ║ QBAR round (counter 6..11):                                     ║
    -- ║   step 0 : f1(A,  kr(c)(3), km(c)(3))  target = D             ║
    -- ║   step 1 : f3(B,  kr(c)(2), km(c)(2))  target = A             ║
    -- ║   step 2 : f2(C,  kr(c)(1), km(c)(1))  target = B             ║
    -- ║   step 3 : f1(D', kr(c)(0), km(c)(0))  target = C             ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    addr_comb : process(state, counter, f_step, beta_reg, kr_i, km_i) is
        variable d_v   : word32_t;
        variable km_v  : word32_t;
        variable kr_v  : word5_t;
        variable i_val : word32_t;
        variable ki    : integer range 0 to 3;
    begin
        addr_a <= 0;
        addr_b <= 0;
        addr_c <= 0;
        addr_d <= 0;

        if state = ADDR then
            -- ── Select km/kr index and input data word ─────────────────
            if counter < 6 then
                -- Q round: subkey index = f_step; input words = D, C, B, A
                ki := f_step;
                case f_step is
                    when 0 => d_v := beta_reg.d;
                    when 1 => d_v := beta_reg.c;
                    when 2 => d_v := beta_reg.b;
                    when 3 => d_v := beta_reg.a;
                end case;
            else
                -- QBAR round: subkey index = 3 - f_step; input = A, B, C, D
                ki := 3 - f_step;
                case f_step is
                    when 0 => d_v := beta_reg.a;
                    when 1 => d_v := beta_reg.b;
                    when 2 => d_v := beta_reg.c;
                    when 3 => d_v := beta_reg.d;
                end case;
            end if;

            km_v := km_i(counter)(ki);
            kr_v := kr_i(counter)(ki);

            -- ── Compute I (f-type determined by round and step) ────────
            -- Q:    step 0,3 → f1   step 1 → f2   step 2 → f3
            -- QBAR: step 0,3 → f1   step 1 → f3   step 2 → f2
            if counter < 6 then
                case f_step is
                    when 0 | 3 =>  -- f1 : I = (km + d) <<< kr
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                    when 1 =>      -- f2 : I = (km ^ d) <<< kr
                        i_val := rotate_left32(km_v xor d_v, kr_v);
                    when 2 =>      -- f3 : I = (km - d) <<< kr
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                end case;
            else
                case f_step is
                    when 0 | 3 =>  -- f1
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                    when 1 =>      -- f3
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                    when 2 =>      -- f2
                        i_val := rotate_left32(km_v xor d_v, kr_v);
                end case;
            end if;

            -- ── Extract byte indices for the 4 S-boxes ─────────────────
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
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                state      <= IDLE;
                counter    <= 0;
                f_step     <= 0;
                done       <= '0';
                beta_reg.a <= (others => '0');
                beta_reg.b <= (others => '0');
                beta_reg.c <= (others => '0');
                beta_reg.d <= (others => '0');
            else
                case state is

                    -- ── IDLE ───────────────────────────────────────────
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            beta_reg.a <= plaintext(127 downto 96);
                            beta_reg.b <= plaintext( 95 downto 64);
                            beta_reg.c <= plaintext( 63 downto 32);
                            beta_reg.d <= plaintext( 31 downto  0);
                            counter    <= 0;
                            f_step     <= 0;
                            state      <= ADDR;
                        end if;

                    -- ── ADDR ───────────────────────────────────────────
                    -- addr_comb drives addr_a..d this cycle.
                    -- bram_read samples them at this rising edge.
                    -- s1_out..s4_out will be valid in COMPUTE.
                    when ADDR =>
                        state <= COMPUTE;

                    -- ── COMPUTE ────────────────────────────────────────
                    -- BRAM outputs are valid. Compute the f-function
                    -- output and XOR it into the target beta word.
                    when COMPUTE =>
                        s1v := unsigned(s1_out);
                        s2v := unsigned(s2_out);
                        s3v := unsigned(s3_out);
                        s4v := unsigned(s4_out);

                        -- f-function output formula
                        -- Q:    step 0,3 → f1   step 1 → f2   step 2 → f3
                        -- QBAR: step 0,3 → f1   step 1 → f3   step 2 → f2
                        if counter < 6 then
                            case f_step is
                                when 0 | 3 =>  -- f1 : ((S1^S2)-S3)+S4
                                    f_result := std_ulogic_vector(
                                        (s1v xor s2v) - s3v + s4v);
                                when 1 =>      -- f2 : ((S1-S2)+S3)^S4
                                    f_result := std_ulogic_vector(
                                        ((s1v - s2v) + s3v) xor s4v);
                                when 2 =>      -- f3 : ((S1+S2)^S3)-S4
                                    f_result := std_ulogic_vector(
                                        ((s1v + s2v) xor s3v) - s4v);
                            end case;
                        else
                            case f_step is
                                when 0 | 3 =>  -- f1
                                    f_result := std_ulogic_vector(
                                        (s1v xor s2v) - s3v + s4v);
                                when 1 =>      -- f3
                                    f_result := std_ulogic_vector(
                                        ((s1v + s2v) xor s3v) - s4v);
                                when 2 =>      -- f2
                                    f_result := std_ulogic_vector(
                                        ((s1v - s2v) + s3v) xor s4v);
                            end case;
                        end if;

                        -- XOR result into target beta word
                        -- Q:    step 0→C  step 1→B  step 2→A  step 3→D
                        -- QBAR: step 0→D  step 1→A  step 2→B  step 3→C
                        if counter < 6 then
                            case f_step is
                                when 0 => beta_reg.c <= beta_reg.c xor f_result;
                                when 1 => beta_reg.b <= beta_reg.b xor f_result;
                                when 2 => beta_reg.a <= beta_reg.a xor f_result;
                                when 3 => beta_reg.d <= beta_reg.d xor f_result;
                            end case;
                        else
                            case f_step is
                                when 0 => beta_reg.d <= beta_reg.d xor f_result;
                                when 1 => beta_reg.a <= beta_reg.a xor f_result;
                                when 2 => beta_reg.b <= beta_reg.b xor f_result;
                                when 3 => beta_reg.c <= beta_reg.c xor f_result;
                            end case;
                        end if;

                        -- Advance counters and state
                        if counter = 11 and f_step = 3 then
                            state <= ST_DONE;
                        elsif f_step = 3 then
                            f_step  <= 0;
                            counter <= counter + 1;
                            state   <= ADDR;
                        else
                            f_step <= f_step + 1;
                            state  <= ADDR;
                        end if;

                    -- ── ST_DONE ────────────────────────────────────────
                    when ST_DONE =>
                        done <= '1';
                        if start = '1' then
                            beta_reg.a <= plaintext(127 downto 96);
                            beta_reg.b <= plaintext( 95 downto 64);
                            beta_reg.c <= plaintext( 63 downto 32);
                            beta_reg.d <= plaintext( 31 downto  0);
                            counter    <= 0;
                            f_step     <= 0;
                            done       <= '0';
                            state      <= ADDR;
                        end if;

                end case;
            end if;
        end if;
    end process main_fsm;

end architecture rtl;
