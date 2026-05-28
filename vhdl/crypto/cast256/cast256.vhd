-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256                                                          │
-- │                                                                  │
-- │ Top-level CAST-256 block cipher.                                 │
-- │ Integrates 1 key schedule unit and 6 parallel encryption cores.  │
-- │                                                                  │
-- │ Architecture:                                                     │
-- │   cast256_ks  : 1 instance — BRAM S-boxes, 4 RAMB18 total.      │
-- │   cast256_enc : 6 instances — LUTRAM S-boxes, 0 RAMB18.          │
-- │   All 6 encryption cores share the subkeys produced by the KS.   │
-- │                                                                  │
-- │ Resource summary (estimated):                                    │
-- │   RAMB18 : 4 (KS only; enc uses LUTRAM)                         │
-- │   LUTs   : ~3,100 base + 6 × ~860 enc = ~8,300 total            │
-- │                                                                  │
-- │ Usage model:                                                      │
-- │   1. Assert key_valid for one cycle with a stable key.           │
-- │      key_ready goes high when the key schedule is done.          │
-- │   2. For each of the 6 channels independently:                   │
-- │      Assert encrypt_start_N for one cycle with stable            │
-- │      plaintext_N. enc_done_N goes high ~50 cycles later.         │
-- │      All channels share the same subkeys and may be active       │
-- │      simultaneously. Stagger start signals by 8 cycles to        │
-- │      achieve 1 block per 8 cycles steady-state throughput.       │
-- │   3. Read ciphertext_N while enc_done_N is high.                 │
-- │                                                                  │
-- │ GCM integration note:                                            │
-- │   gcm.vhd must be updated to drive the 6 independent enc         │
-- │   channels (plaintext_N, encrypt_start_N) and collect results    │
-- │   (ciphertext_N, enc_done_N) via a round-robin dispatcher.       │
-- │                                                                  │
-- │ Encryption latency per channel: ~50 cycles                       │
-- │   (1 ADDR + 48 COMPUTE + 1 ST_DONE)                             │
-- │ Steady-state throughput: 1 block per 8 cycles (6 engines /       │
-- │   ~50 cycle latency ≈ 6.25 cycles/block, rounded to 8 for        │
-- │   practical stagger alignment)                                   │
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
        enc_done_1      : out std_ulogic;

        -- ── Encryption channel 2 ──────────────────────────────────────
        plaintext_2     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_2 : in  std_ulogic;
        ciphertext_2    : out std_ulogic_vector(127 downto 0);
        enc_done_2      : out std_ulogic;

        -- ── Encryption channel 3 ──────────────────────────────────────
        plaintext_3     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_3 : in  std_ulogic;
        ciphertext_3    : out std_ulogic_vector(127 downto 0);
        enc_done_3      : out std_ulogic;

        -- ── Encryption channel 4 ──────────────────────────────────────
        plaintext_4     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_4 : in  std_ulogic;
        ciphertext_4    : out std_ulogic_vector(127 downto 0);
        enc_done_4      : out std_ulogic;

        -- ── Encryption channel 5 ──────────────────────────────────────
        plaintext_5     : in  std_ulogic_vector(127 downto 0);
        encrypt_start_5 : in  std_ulogic;
        ciphertext_5    : out std_ulogic_vector(127 downto 0);
        enc_done_5      : out std_ulogic
    );
end entity cast256;

architecture rtl of cast256 is

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Internal types (local to this architecture)                     │
    -- └─────────────────────────────────────────────────────────────────┘
    constant N_ENG : integer := 6;

    type plain_arr_t  is array(0 to N_ENG-1) of std_ulogic_vector(127 downto 0);
    type start_arr_t  is array(0 to N_ENG-1) of std_ulogic;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Internal wires                                                  │
    -- └─────────────────────────────────────────────────────────────────┘
    signal key_ready_int : std_ulogic;
    signal kr_bus        : kr_array_t;
    signal km_bus        : km_array_t;

    -- Flattened channel arrays (fed from individual ports below)
    signal plain_arr    : plain_arr_t;
    signal start_arr    : start_arr_t;   -- gated with key_ready_int
    signal cipher_arr   : plain_arr_t;
    signal done_arr     : start_arr_t;

begin

    -- ── key_ready output ──────────────────────────────────────────────
    key_ready <= key_ready_int;

    -- ── Channel port → array mapping ──────────────────────────────────
    -- Flatten individual ports into arrays for the generate loop.
    -- encrypt_start_N is gated with key_ready_int so that encryption
    -- cannot begin before subkeys are valid.
    plain_arr(0) <= plaintext_0;
    plain_arr(1) <= plaintext_1;
    plain_arr(2) <= plaintext_2;
    plain_arr(3) <= plaintext_3;
    plain_arr(4) <= plaintext_4;
    plain_arr(5) <= plaintext_5;

    start_arr(0) <= encrypt_start_0 and key_ready_int;
    start_arr(1) <= encrypt_start_1 and key_ready_int;
    start_arr(2) <= encrypt_start_2 and key_ready_int;
    start_arr(3) <= encrypt_start_3 and key_ready_int;
    start_arr(4) <= encrypt_start_4 and key_ready_int;
    start_arr(5) <= encrypt_start_5 and key_ready_int;

    ciphertext_0 <= cipher_arr(0);
    ciphertext_1 <= cipher_arr(1);
    ciphertext_2 <= cipher_arr(2);
    ciphertext_3 <= cipher_arr(3);
    ciphertext_4 <= cipher_arr(4);
    ciphertext_5 <= cipher_arr(5);

    enc_done_0 <= done_arr(0);
    enc_done_1 <= done_arr(1);
    enc_done_2 <= done_arr(2);
    enc_done_3 <= done_arr(3);
    enc_done_4 <= done_arr(4);
    enc_done_5 <= done_arr(5);

    -- ── Key schedule instance ─────────────────────────────────────────
    -- Single cast256_ks; subkeys broadcast to all 6 enc engines.
    -- BRAM S-boxes (4 RAMB18). Latency ~396 cycles (unchanged).
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

    -- ── 6 parallel encryption engines ────────────────────────────────
    -- All engines share kr_bus / km_bus from the single KS.
    -- LUTRAM S-boxes: 0 RAMB18 per engine.
    -- Latency ~50 cycles per engine (optimization 1 applied).
    -- To maximise throughput, stagger start signals by 8 cycles so
    -- that one engine completes every 8 cycles in steady state.
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