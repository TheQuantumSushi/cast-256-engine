-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_ks                                                       │
-- │                                                                  │
-- │ CAST-256 key schedule (RFC 2612 Section 2.4).                    │
-- │ Derives 12 sets of subkeys from a 256-bit secret key.            │
-- │ Each set contains 4 x 5-bit rotation keys (Kr) and 4 x 32-bit    │
-- │ masking keys (Km).                                               │
-- │                                                                  │
-- │ The schedule runs 24 W-octaves (2 per clock cycle), producing    │
-- │ one subkey set per cycle — total latency of 12 cycles after      │
-- │ 'start' is asserted.                                             │
-- │                                                                  │
-- │ Interface :                                                      │
-- │   - aclk    : system clock (rising-edge triggered)               │
-- │   - aresetn : synchronous active-low reset                       │
-- │   - key     : 256-bit secret key, sampled on rising edge of      │
-- │               'start'                                            │
-- │   - start   : pulse high for one cycle to begin a new schedule   │
-- │   - done    : high when subkeys are valid; falls on re-trigger   │
-- │   - kr_o    : 12 x {Kr0..Kr3} rotation-key output                │
-- │   - km_o    : 12 x {Km0..Km3} masking-key output                 │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.cast256_pkg.all;

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

architecture rtl of cast256_ks is

    -- ┌─────────────────────────────────┐
    -- │ State machine                   │
    -- └─────────────────────────────────┘
    type ks_state_t is (IDLE, RUNNING, DONE);
    signal state : ks_state_t;

    -- ┌─────────────────────────────────┐
    -- │ Internal registers              │
    -- └─────────────────────────────────┘
    signal kappa_reg : kappa_t;
    signal kr_reg    : kr_array_t;
    signal km_reg    : km_array_t;
    signal counter   : integer range 0 to 11;

begin

    -- ── Drive outputs from registers ─────────────────────────────────
    kr_o <= kr_reg;
    km_o <= km_reg;

    -- ── Clocked FSM ───────────────────────────────────────────────────
    process(aclk) is
        variable k : kappa_t;   -- local working copy of kappa
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then

                -- ── Synchronous reset ─────────────────────────────────
                state       <= IDLE;
                counter     <= 0;
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

                    -- ── IDLE ──────────────────────────────────────────
                    -- Wait for a start pulse, then latch the key.
                    when IDLE =>
                        done <= '0';
                        if start = '1' then
                            -- Initialise KAPPA from the 256-bit key (A = MSW)
                            kappa_reg.a <= key(255 downto 224);
                            kappa_reg.b <= key(223 downto 192);
                            kappa_reg.c <= key(191 downto 160);
                            kappa_reg.d <= key(159 downto 128);
                            kappa_reg.e <= key(127 downto  96);
                            kappa_reg.f <= key( 95 downto  64);
                            kappa_reg.g <= key( 63 downto  32);
                            kappa_reg.h <= key( 31 downto   0);
                            counter     <= 0;
                            state       <= RUNNING;
                        end if;

                    -- ── RUNNING ───────────────────────────────────────
                    -- Execute one pair of W-octaves per cycle.
                    -- counter runs 0..11 → octave pairs W(0,1)..W(22,23).
                    -- Subkeys for round 'counter' extracted after each pair.
                    when RUNNING =>
                        -- Copy signal into variable so updates are immediate
                        k := kappa_reg;

                        k := w_octave(k, 2 * counter);
                        k := w_octave(k, 2 * counter + 1);

                        -- Kr(i) = { 5LSB(A), 5LSB(C), 5LSB(E), 5LSB(G) }
                        -- Km(i) = { H,       F,       D,       B       }
                        kr_reg(counter)(0) <= k.a(4 downto 0);
                        kr_reg(counter)(1) <= k.c(4 downto 0);
                        kr_reg(counter)(2) <= k.e(4 downto 0);
                        kr_reg(counter)(3) <= k.g(4 downto 0);
                        km_reg(counter)(0) <= k.h;
                        km_reg(counter)(1) <= k.f;
                        km_reg(counter)(2) <= k.d;
                        km_reg(counter)(3) <= k.b;

                        kappa_reg <= k;

                        if counter = 11 then
                            state <= DONE;
                        else
                            counter <= counter + 1;
                        end if;

                    -- ── DONE ──────────────────────────────────────────
                    -- Subkeys are valid; hold done until re-triggered.
                    when DONE =>
                        done <= '1';
                        if start = '1' then
                            -- New key : latch immediately and restart
                            kappa_reg.a <= key(255 downto 224);
                            kappa_reg.b <= key(223 downto 192);
                            kappa_reg.c <= key(191 downto 160);
                            kappa_reg.d <= key(159 downto 128);
                            kappa_reg.e <= key(127 downto  96);
                            kappa_reg.f <= key( 95 downto  64);
                            kappa_reg.g <= key( 63 downto  32);
                            kappa_reg.h <= key( 31 downto   0);
                            counter     <= 0;
                            done        <= '0';
                            state       <= RUNNING;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
