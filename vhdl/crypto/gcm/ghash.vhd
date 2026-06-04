-- ┌──────────────────────────────────────────────────────────────────┐
-- │ ghash                                                            │
-- │                                                                  │
-- │ Sequential GHASH function (NIST SP 800-38D Algorithm 2).        │
-- │                                                                  │
-- │ Maintains a 128-bit running accumulator Y, updated per block:   │
-- │                                                                  │
-- │   Y_0 = 0^128                                                   │
-- │   Y_i = (Y_{i-1} XOR X_i) · H                                  │
-- │                                                                  │
-- │ The accumulator is reset via clear_i. Blocks are fed via        │
-- │ blk_i / valid_i. A new block must not be presented before       │
-- │ done_o fires for the previous one.                              │
-- │                                                                  │
-- │ In the GCM pipeline, the 33-cycle latency per block fits inside │
-- │ the 96-cycle CAST-256 window, so this constraint is met by      │
-- │ construction when valid_i is gated by the GCM state machine.   │
-- │                                                                  │
-- │ Latency : 33 cycles from valid_i to done_o                     │
-- │   (1 cycle to latch into gf128_mul + 32 cycles for mul)        │
-- │                                                                  │
-- │ Interface :                                                      │
-- │   - H       : hash subkey = CAST256(K, 0^128); stable after    │
-- │               GCM_H_WAIT, before first valid_i                  │
-- │   - blk_i   : 128-bit block to absorb (Xi)                     │
-- │   - valid_i : single-cycle pulse to start processing blk_i     │
-- │   - clear_i : single-cycle pulse to reset Y to 0^128           │
-- │   - Y_o     : current accumulator value (combinatorial)        │
-- │   - done_o  : single-cycle pulse when Y_o has been updated     │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;

entity ghash is
    port (
        aclk     : in  std_ulogic;
        aresetn  : in  std_ulogic;
        H        : in  std_ulogic_vector(127 downto 0);
        blk_i    : in  std_ulogic_vector(127 downto 0);
        valid_i  : in  std_ulogic;
        clear_i  : in  std_ulogic;
        Y_o      : out std_ulogic_vector(127 downto 0);
        done_o   : out std_ulogic
    );
end entity ghash;

architecture rtl of ghash is

    -- ┌─────────────────────────────────┐
    -- │ Types                           │
    -- └─────────────────────────────────┘
    type state_t is (IDLE, MUL_WAIT);

    -- ┌─────────────────────────────────┐
    -- │ Registers                       │
    -- └─────────────────────────────────┘
    signal state_r : state_t;
    signal Y_r     : std_ulogic_vector(127 downto 0);

    -- ┌─────────────────────────────────┐
    -- │ gf128_mul wires                 │
    -- └─────────────────────────────────┘
    signal mul_X     : std_ulogic_vector(127 downto 0);
    signal mul_Y     : std_ulogic_vector(127 downto 0);
    signal mul_start : std_ulogic;
    signal mul_Z     : std_ulogic_vector(127 downto 0);
    signal mul_done  : std_ulogic;

begin

    Y_o <= Y_r;

    -- ── gf128_mul instance ────────────────────────────────────────────
    u_mul : entity work.gf128_mul
        port map (
            aclk    => aclk,
            aresetn => aresetn,
            X       => mul_X,
            Y       => mul_Y,
            start   => mul_start,
            Z       => mul_Z,
            done    => mul_done
        );

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ ghash_fsm                                                       ║
    -- ║                                                                 ║
    -- ║ IDLE     : accept clear_i (reset Y) or valid_i (start mul)     ║
    -- ║ MUL_WAIT : wait for gf128_mul to complete; latch result        ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    ghash_fsm : process (aclk) is
    begin
        if rising_edge(aclk) then
            done_o    <= '0';
            mul_start <= '0';
            if aresetn = '0' then
                state_r <= IDLE;
                Y_r     <= (others => '0');
                mul_X   <= (others => '0');
                mul_Y   <= (others => '0');
            else
                case state_r is

                    -- ── IDLE ──────────────────────────────────────────
                    -- clear_i takes priority over valid_i; both should
                    -- not be asserted in the same cycle.
                    when IDLE =>
                        if clear_i = '1' then
                            Y_r <= (others => '0');
                        elsif valid_i = '1' then
                            mul_X     <= Y_r xor blk_i;
                            mul_Y     <= H;
                            mul_start <= '1';
                            state_r   <= MUL_WAIT;
                        end if;

                    -- ── MUL_WAIT ──────────────────────────────────────
                    when MUL_WAIT =>
                        if mul_done = '1' then
                            Y_r     <= mul_Z;
                            done_o  <= '1';
                            state_r <= IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process ghash_fsm;

end architecture rtl;