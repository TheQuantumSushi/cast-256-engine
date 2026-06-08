-- ┌──────────────────────────────────────────────────────────────────┐
-- │ gf128_mul                                                        │
-- │                                                                  │
-- │ GF(2^128) block multiplier. Computes Z = X · Y over GF(2^128)    │
-- │ using the reduction polynomial from NIST SP 800-38D §6.3:        │
-- │                                                                  │
-- │   R = 11100001 || 0^120   (x^128 + x^7 + x^2 + x + 1)            │
-- │                                                                  │
-- │ Algorithm (SP 800-38D Algorithm 1), 8-bit unrolled per cycle:    │
-- │   Iterate over the 128 bits of X (x_0 = MSB, x_127 = LSB).       │
-- │   Each cycle processes 8 consecutive bits of X, applying the     │
-- │   conditional Z accumulation and right-shift of V.               │
-- │                                                                  │
-- │ Latency : 16 clock cycles (8 bits/cycle × 128 bits = 16 steps)   │
-- │           + 1 cycle for the DONE_ST pulse = 17 cycles total.     │
-- │                                                                  │
-- │ This keeps GF multiplication well inside the 50-cycle CAST-256   │
-- │ window, enabling GHASH / GCTR pipeline overlap.                  │
-- │                                                                  │
-- │ Interface :                                                      │
-- │   - X, Y   : 128-bit multiplicands, sampled when start fires     │
-- │   - start  : single-cycle pulse; must not fire while busy        │
-- │   - Z      : 128-bit product; stable from done until next start  │
-- │   - done   : single-cycle pulse when Z is valid                  │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.gcm_pkg.all;

entity gf128_mul is
    port (
        aclk    : in  std_ulogic;
        aresetn : in  std_ulogic;
        X       : in  std_ulogic_vector(127 downto 0);
        Y       : in  std_ulogic_vector(127 downto 0);
        start   : in  std_ulogic;
        Z       : out std_ulogic_vector(127 downto 0);
        done    : out std_ulogic
    );
end entity gf128_mul;

architecture rtl of gf128_mul is

    -- ┌─────────────────────────────────┐
    -- │ Types                           │
    -- └─────────────────────────────────┘
    type state_t is (IDLE, RUN, DONE_ST);

    -- ┌─────────────────────────────────┐
    -- │ Registers                       │
    -- └─────────────────────────────────┘
    signal state_r : state_t;
    signal Z_r     : std_ulogic_vector(127 downto 0);
    signal V_r     : std_ulogic_vector(127 downto 0);
    signal X_r     : std_ulogic_vector(127 downto 0);
    signal cnt_r   : unsigned(3 downto 0);  -- 0..15: which group of 8 bits

begin

    Z <= Z_r;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ mul_fsm                                                         ║
    -- ║                                                                 ║
    -- ║ Processes 8 bits of X per clock cycle. For group k (cnt_r=k), ║
    -- ║ the 8 bits are x_{8k}..x_{8k+7} where x_i = X_r(127-i).     ║
    -- ║                                                                 ║
    -- ║ Per iteration j in 0..7 (statically unrolled):                 ║
    -- ║   if x_{4k+j} = 1 : Z_v ^= V_v                                ║
    -- ║   if V_v[0]   = 1 : V_v = (V_v >> 1) ^ R                      ║
    -- ║   else              V_v = V_v >> 1                             ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    mul_fsm : process (aclk) is
        variable Z_v      : std_ulogic_vector(127 downto 0);
        variable V_v      : std_ulogic_vector(127 downto 0);
        variable bit_base : integer range 0 to 120;
    begin
        if rising_edge(aclk) then
            done <= '0';
            if aresetn = '0' then
                state_r <= IDLE;
                Z_r     <= (others => '0');
                V_r     <= (others => '0');
                X_r     <= (others => '0');
                cnt_r   <= (others => '0');
            else
                case state_r is

                    -- ── IDLE ──────────────────────────────────────────
                    when IDLE =>
                        if start = '1' then
                            Z_r     <= (others => '0');
                            V_r     <= Y;
                            X_r     <= X;
                            cnt_r   <= (others => '0');
                            state_r <= RUN;
                        end if;

                    -- ── RUN ───────────────────────────────────────────
                    -- Unroll 8 Algorithm-1 iterations per clock.
                    when RUN =>
                        Z_v      := Z_r;
                        V_v      := V_r;
                        bit_base := to_integer(cnt_r) * 8;
                        for j in 0 to 7 loop
                            -- Accumulate V into Z when x_{base+j} = 1
                            if X_r(127 - (bit_base + j)) = '1' then
                                Z_v := Z_v xor V_v;
                            end if;
                            -- Right-shift V with conditional GF reduction
                            if V_v(0) = '1' then
                                V_v := ('0' & V_v(127 downto 1)) xor GF_R;
                            else
                                V_v := '0' & V_v(127 downto 1);
                            end if;
                        end loop;
                        Z_r <= Z_v;
                        V_r <= V_v;
                        if cnt_r = 15 then
                            state_r <= DONE_ST;
                        else
                            cnt_r <= cnt_r + 1;
                        end if;

                    -- ── DONE_ST ───────────────────────────────────────
                    when DONE_ST =>
                        done    <= '1';
                        state_r <= IDLE;

                end case;
            end if;
        end if;
    end process mul_fsm;

end architecture rtl;