-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256                                                          │
-- │                                                                  │
-- │ Top-level CAST-256 block cipher.                                 │
-- │ Integrates 1 key schedule unit and 2 parallel encryption cores.  │
-- │                                                                  │
-- │ Architecture:                                                     │
-- │   cast256_ks  : 1 instance — BRAM S-boxes, 4 RAMB18 total.      │
-- │   cast256_enc : 2 instances — LUTRAM S-boxes, 0 RAMB18.          │
-- │   Both encryption cores share the subkeys from the KS.          │
-- │                                                                  │
-- │ Resource summary (estimated from synthesis):                     │
-- │   RAMB18 : 4  (KS only)                                         │
-- │   LUTs   : ~5,400 enc + ~6,000 KS = ~11,400 total (~65% of     │
-- │            the xc7z010's 17,600 LUTs — fits with margin)        │
-- │                                                                  │
-- │ Usage model:                                                      │
-- │   1. Assert key_valid for one cycle with a stable key.           │
-- │      key_ready goes high when the key schedule is done.          │
-- │   2. For each of the 2 channels independently:                   │
-- │      Assert encrypt_start_N for one cycle with stable            │
-- │      plaintext_N. enc_done_N goes high ~50 cycles later.         │
-- │      Both channels share subkeys and may be active               │
-- │      simultaneously.                                             │
-- │   3. Read ciphertext_N while enc_done_N is high.                 │
-- │                                                                  │
-- │ GCM integration note:                                            │
-- │   gcm.vhd must be updated to drive the 2 enc channels with a    │
-- │   round-robin dispatcher staggered by ~25 cycles.                │
-- │                                                                  │
-- │ Encryption latency per channel : ~50 cycles                      │
-- │ Steady-state throughput        : 1 block / ~25 cycles            │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use work.cast256_pkg.all;

entity cast256 is
    port (
        aclk            : in  std_ulogic;
        aresetn         : in  std_ulogic;

        -- ── Key schedule interface ─────────────────────────────────────
        key             : in  std_ulogic_vector(255 downto 0);
        key_valid       : in  std_ulogic;
        key_ready       : out std_ulogic;

        -- ── Encryption channel 0 ──────────────────────────────────────
        plaintext_0     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_0 : in  std_ulogic;
        ciphertext_0    : out std_ulogic_vector(127 downto 0);
        enc_done_0      : out std_ulogic;

        -- ── Encryption channel 1 ──────────────────────────────────────
        plaintext_1     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_1 : in  std_ulogic;
        ciphertext_1    : out std_ulogic_vector(127 downto 0);
        enc_done_1      : out std_ulogic
    );
end entity cast256;

architecture rtl of cast256 is

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Internal types                                                  │
    -- └─────────────────────────────────────────────────────────────────┘
    constant N_ENG : integer := 2;

    type plain_arr_t is array(0 to N_ENG-1) of std_ulogic_vector(127 downto 0);
    type start_arr_t is array(0 to N_ENG-1) of std_ulogic;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Internal wires                                                  │
    -- └─────────────────────────────────────────────────────────────────┘
    signal key_ready_int : std_ulogic;
    signal kr_bus        : kr_array_t;
    signal km_bus        : km_array_t;

    signal plain_arr  : plain_arr_t;
    signal start_arr  : start_arr_t;
    signal cipher_arr : plain_arr_t;
    signal done_arr   : start_arr_t;

begin

    -- ── key_ready output ──────────────────────────────────────────────
    key_ready <= key_ready_int;

    -- ── Channel port → array mapping ──────────────────────────────────
    plain_arr(0) <= plaintext_0;
    plain_arr(1) <= plaintext_1;

    -- encrypt_start_N gated with key_ready_int: encryption cannot begin
    -- before the key schedule has produced valid subkeys.
    start_arr(0) <= encrypt_start_0 and key_ready_int;
    start_arr(1) <= encrypt_start_1 and key_ready_int;

    ciphertext_0 <= cipher_arr(0);
    ciphertext_1 <= cipher_arr(1);

    enc_done_0 <= done_arr(0);
    enc_done_1 <= done_arr(1);

    -- ── Key schedule instance ─────────────────────────────────────────
    u_ks : entity work.cast256_ks
        port map (
            aclk    => aclk,
            aresetn => aresetn,
            key     => key,
            start   => key_valid,
            done    => key_ready_int,
            kr_o    => kr_bus,
            km_o    => km_bus
        );

    -- ── 2 parallel encryption engines ────────────────────────────────
    -- Both engines share kr_bus / km_bus from the single KS.
    -- Stagger start signals by ~25 cycles for 1 block / 25 cycles
    -- steady-state throughput.
    gen_enc : for i in 0 to N_ENG-1 generate
        u_enc : entity work.cast256_enc
            port map (
                aclk       => aclk,
                aresetn    => aresetn,
                plaintext  => plain_arr(i),
                kr_i       => kr_bus,
                km_i       => km_bus,
                start      => start_arr(i),
                ciphertext => cipher_arr(i),
                done       => done_arr(i)
            );
    end generate gen_enc;

end architecture rtl;