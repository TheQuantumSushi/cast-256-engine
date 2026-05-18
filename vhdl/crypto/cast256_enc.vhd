-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_enc                                                      │
-- │                                                                  │
-- │ CAST-256 encryption core (RFC 2612 Section 2.5).                 │
-- │ Encrypts a single 128-bit plaintext block using the 12 subkey    │
-- │ sets produced by cast256_ks.                                     │
-- │                                                                  │
-- │ The core applies 6 forward quad-rounds (Q) followed by 6 reverse │
-- │ quad-rounds (QBAR), one round per clock cycle — total latency of │
-- │ 12 cycles after 'start' is asserted.                             │
-- │                                                                  │
-- │ Interface :                                                      │
-- │   - aclk       : system clock (rising-edge triggered)            │
-- │   - aresetn    : synchronous active-low reset                    │
-- │   - plaintext  : 128-bit input block, sampled on rising 'start'  │
-- │   - kr_i       : rotation subkeys from cast256_ks                │
-- │   - km_i       : masking subkeys from cast256_ks                 │
-- │   - start      : pulse high for one cycle to begin encryption    │
-- │   - ciphertext : 128-bit result, valid when done='1'             │
-- │   - done       : high when ciphertext is valid                   │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cast256_pkg.all;

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

architecture rtl of cast256_enc is

    -- ┌─────────────────────────────────┐
    -- │ State machine                   │
    -- └─────────────────────────────────┘
    type enc_state_t is (IDLE, RUNNING, DONE);
    signal state : enc_state_t;

    -- ┌─────────────────────────────────┐
    -- │ Internal registers              │
    -- └─────────────────────────────────┘
    signal beta_reg : beta_t;
    signal counter  : integer range 0 to 11;

begin

    -- ── Ciphertext output ─────────────────────────────────────────────
    -- Reassemble words A..D as one vector (A = MSW).
    ciphertext <= beta_reg.a & beta_reg.b & beta_reg.c & beta_reg.d;

    -- ── Clocked FSM ───────────────────────────────────────────────────
    process(aclk) is
        variable bv : beta_t;   -- local working copy of the data state
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then

                -- ── Synchronous reset ─────────────────────────────────
                state      <= IDLE;
                counter    <= 0;
                done       <= '0';
                beta_reg.a <= (others => '0');
                beta_reg.b <= (others => '0');
                beta_reg.c <= (others => '0');
                beta_reg.d <= (others => '0');

            else
                case state is

                    -- ── IDLE ──────────────────────────────────────────
                    -- Wait for start pulse, then latch plaintext into BETA.
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            -- Split 128-bit block into four 32-bit words (A = MSW)
                            beta_reg.a <= plaintext(127 downto  96);
                            beta_reg.b <= plaintext( 95 downto  64);
                            beta_reg.c <= plaintext( 63 downto  32);
                            beta_reg.d <= plaintext( 31 downto   0);
                            counter    <= 0;
                            state      <= RUNNING;
                        end if;

                    -- ── RUNNING ───────────────────────────────────────
                    -- One quad-round per cycle :
                    --   counter 0..5  → forward Q rounds   (q_round)
                    --   counter 6..11 → reverse QBAR rounds (qbar_round)
                    when RUNNING =>
                        bv := beta_reg;

                        if counter < 6 then
                            bv := q_round(bv, counter, kr_i, km_i);
                        else
                            bv := qbar_round(bv, counter, kr_i, km_i);
                        end if;

                        beta_reg <= bv;

                        if counter = 11 then
                            state <= DONE;
                        else
                            counter <= counter + 1;
                        end if;

                    -- ── DONE ──────────────────────────────────────────
                    -- Ciphertext valid; hold until re-triggered.
                    when DONE =>
                        done <= '1';
                        if start = '1' then
                            beta_reg.a <= plaintext(127 downto  96);
                            beta_reg.b <= plaintext( 95 downto  64);
                            beta_reg.c <= plaintext( 63 downto  32);
                            beta_reg.d <= plaintext( 31 downto   0);
                            counter    <= 0;
                            done       <= '0';
                            state      <= RUNNING;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
