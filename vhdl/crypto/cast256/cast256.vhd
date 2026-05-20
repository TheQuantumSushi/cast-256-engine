-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256                                                          │
-- │                                                                  │
-- │ Top-level CAST-256 block cipher, integrating the key schedule    │
-- │ and the encryption core.                                         │
-- │                                                                  │
-- │ Typical usage sequence :                                         │
-- │   1. Assert 'key_valid' for one cycle with a stable 'key'.       │
-- │      Key schedule runs for 12 cycles; 'key_ready' goes high      │
-- │      when done.                                                  │
-- │   2. Assert 'encrypt_start' for one cycle with stable            │
-- │      'plaintext'. Internally gated with 'key_ready', so it is    │
-- │      safe to present early and re-assert if needed.              │
-- │      Encryption core runs 12 cycles; 'enc_done' goes high.       │
-- │   3. Read 'ciphertext' while 'enc_done' is high.                 │
-- │   4. Return to step 2 for the next block.                        │
-- │                                                                  │
-- │ Latencies (after the triggering rising edge) :                   │
-- │   Key schedule : 12 cycles  (key_ready high on cycle 13)         │
-- │   Encryption   : 12 cycles  (enc_done  high on cycle 13)         │
-- │                                                                  │
-- │ Interface :                                                      │
-- │   - aclk          : system clock (rising-edge triggered)         │
-- │   - aresetn       : synchronous active-low reset                 │
-- │   - key           : 256-bit secret key                           │
-- │   - key_valid     : pulse to start key schedule                  │
-- │   - key_ready     : high when subkeys are valid                  │
-- │   - plaintext     : 128-bit input block                          │
-- │   - encrypt_start : pulse to start encryption                    │
-- │   - ciphertext    : 128-bit output block                         │
-- │   - enc_done      : high when ciphertext is valid                │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use work.cast256_pkg.all;

entity cast256 is
    port (
        aclk          : in  std_ulogic;
        aresetn       : in  std_ulogic;
        -- Key-schedule interface
        key           : in  std_ulogic_vector(255 downto 0);
        key_valid     : in  std_ulogic;
        key_ready     : out std_ulogic;
        -- Encryption interface
        plaintext     : in  std_ulogic_vector(127 downto 0);
        encrypt_start : in  std_ulogic;
        ciphertext    : out std_ulogic_vector(127 downto 0);
        enc_done      : out std_ulogic
    );
end entity cast256;

architecture rtl of cast256 is

    -- ┌─────────────────────────────────┐
    -- │ Internal wires                  │
    -- └─────────────────────────────────┘
    signal key_ready_int  : std_ulogic;
    signal enc_start_gate : std_ulogic;
    signal kr_bus         : kr_array_t;
    signal km_bus         : km_array_t;

    -- ┌─────────────────────────────────┐
    -- │ Component declarations          │
    -- └─────────────────────────────────┘
    component cast256_ks is
        port (
            aclk    : in  std_ulogic;
            aresetn : in  std_ulogic;
            key     : in  std_ulogic_vector(255 downto 0);
            start   : in  std_ulogic;
            done    : out std_ulogic;
            kr_o    : out kr_array_t;
            km_o    : out km_array_t
        );
    end component;

    component cast256_enc is
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
    end component;

begin

    -- ── Encrypt-start gate ────────────────────────────────────────────
    -- Encryption may only begin once the key schedule has completed
    -- and subkeys are valid.
    enc_start_gate <= encrypt_start and key_ready_int;
    key_ready      <= key_ready_int;

    -- ── Key schedule instance ─────────────────────────────────────────
    u_ks : cast256_ks
        port map (
            aclk    => aclk,
            aresetn => aresetn,
            key     => key,
            start   => key_valid,
            done    => key_ready_int,
            kr_o    => kr_bus,
            km_o    => km_bus
        );

    -- ── Encryption core instance ──────────────────────────────────────
    u_enc : cast256_enc
        port map (
            aclk       => aclk,
            aresetn    => aresetn,
            plaintext  => plaintext,
            kr_i       => kr_bus,
            km_i       => km_bus,
            start      => enc_start_gate,
            ciphertext => ciphertext,
            done       => enc_done
        );

end architecture rtl;
