-- ┌──────────────────────────────────────────────────────────────────┐
-- │ cast256_enc                                                      │
-- │                                                                  │
-- │ CAST-256 encryption datapath (RFC 2612).                         │
-- │ 6 forward quad-rounds (Q) followed by 6 reverse quad-rounds      │
-- │ (QBAR), for a total of 12 rounds × 4 f-functions = 48 steps.     │
-- │                                                                  │
-- │ Optimizations applied vs the BRAM baseline:                      │
-- │                                                                  │
-- │  1. Pipelined BRAM address (ADDR state eliminated from loop)     │
-- │     During COMPUTE for step N, addr_comb simultaneously drives   │
-- │     BRAM addresses for step N+1 using forwarded beta values      │
-- │     where needed (Q rounds only - see forwarding analysis).      │
-- │     The ADDR state is only entered once per encryption run, for  │
-- │     the very first step. All subsequent steps run COMPUTE →      │
-- │     COMPUTE, halving the per-block latency.                      │
-- │                                                                  │
-- │  2. Distributed RAM (LUTRAM) S-boxes                             │
-- │     ram_style = "distributed" replaces ram_style = "block".      │
-- │     Vivado maps each 256×32 S-box to ~128 LUT6 LUTRAM cells      │
-- │     (~512 LUTs for all 4). Read latency is identical (1 cycle).  │
-- │     This frees all 4 RAMB18 previously used by cast256_enc,      │
-- │     leaving the 4 RAMB18 in cast256_ks as the only block-RAM     │
-- │     consumers (down from 8 total).                               │
-- │     Enables multiple parallel instances without BRAM exhaustion. │
-- │                                                                  │
-- │ Forwarding analysis (Q vs QBAR):                                 │
-- │   Q (counter 0–5): each step reads the word updated by the       │
-- │   previous step. Forwarding (beta XOR f_result) is needed at     │
-- │   every step transition except the Q→QBAR boundary               │
-- │   (counter=5, f_step=3 → A is already registered from step 2).   │
-- │   QBAR (counter 6–11): dependencies are 2+ cycles apart;         │
-- │   all words are correctly registered before they are read.       │
-- │   No forwarding needed.                                          │
-- │                                                                  │
-- │ Latency: ~50 clock cycles per 128-bit block                      │
-- │   (1 ADDR + 48 COMPUTE + 1 ST_DONE, vs 97 in the BRAM baseline)  │
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
    -- │ S-box LUTRAM signals                                            │
    -- │                                                                 │
    -- │ Each signal is a 256×32 ROM initialized from the package        │
    -- │ constant of the same name.                                      │
    -- │                                                                 │
    -- │ ram_style = "distributed" → Vivado maps each to LUTRAM          │
    -- │ (~128 LUT6 cells per S-box, 1-cycle registered read latency).   │
    -- │ Read timing is identical to BRAM: address presented in one      │
    -- │ cycle, output valid the next.                                   │
    -- └─────────────────────────────────────────────────────────────────┘
    signal SBOX1_r : sbox_t := SBOX1;
    signal SBOX2_r : sbox_t := SBOX2;
    signal SBOX3_r : sbox_t := SBOX3;
    signal SBOX4_r : sbox_t := SBOX4;

    attribute ram_style : string;
    attribute ram_style of SBOX1_r : signal is "distributed";
    attribute ram_style of SBOX2_r : signal is "distributed";
    attribute ram_style of SBOX3_r : signal is "distributed";
    attribute ram_style of SBOX4_r : signal is "distributed";

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ FSM                                                             │
    -- │                                                                 │
    -- │ IDLE    : wait for start; latch plaintext into beta_reg         │
    -- │ ADDR    : addr_comb drives LUTRAM addresses for step 0 only;   │
    -- │           entered once per encryption run (from IDLE/ST_DONE)  │
    -- │ COMPUTE : LUTRAM output valid; apply f-function, update beta;  │
    -- │           addr_comb simultaneously drives addresses for step+1 │
    -- │           using forwarded beta values (Q rounds) or registered  │
    -- │           beta values (QBAR rounds). State loops to COMPUTE.   │
    -- │ ST_DONE : done is '1' via combinatorial concurrent stmt while   │
    -- │           here and start='0'; accept back-to-back start         │
    -- └─────────────────────────────────────────────────────────────────┘
    type enc_state_t is (IDLE, ADDR, COMPUTE, ST_DONE);
    signal state : enc_state_t;

    -- ┌─────────────────────────────────┐
    -- │ Counters                        │
    -- └─────────────────────────────────┘
    signal counter : integer range 0 to 11;  -- quad-round index (0..11)
    signal f_step  : integer range 0 to 3;   -- f-function within round (0..3)

    -- ┌─────────────────────────────────┐
    -- │ Data register                   │
    -- └─────────────────────────────────┘
    signal beta_reg : beta_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ LUTRAM interface                                                 │
    -- └─────────────────────────────────────────────────────────────────┘
    signal addr_a : integer range 0 to 255;
    signal addr_b : integer range 0 to 255;
    signal addr_c : integer range 0 to 255;
    signal addr_d : integer range 0 to 255;

    signal s1_out : word32_t;
    signal s2_out : word32_t;
    signal s3_out : word32_t;
    signal s4_out : word32_t;

    -- ┌─────────────────────────────────────────────────────────────────┐
    -- │ Combinatorial f_result (for address forwarding)                 │
    -- │                                                                 │
    -- │ Replicates the f_result arithmetic from main_fsm as a pure      │
    -- │ combinatorial signal. Used by addr_comb in COMPUTE state to     │
    -- │ forward the not-yet-registered updated beta word as the input   │
    -- │ for the NEXT f-function's I computation.                        │
    -- │                                                                 │
    -- │ Only meaningful when state = COMPUTE (s1_out..s4_out valid).    │
    -- └─────────────────────────────────────────────────────────────────┘
    signal f_result_comb : word32_t;

begin

    -- ── Outputs ───────────────────────────────────────────────────────
    -- done is combinatorial: '1' iff state=ST_DONE and start='0'.
    -- Dropping done immediately when start is asserted (same cycle) lets
    -- callers skip the 1-cycle ARM hold-off that was required to avoid
    -- sampling a stale registered '1' on the start pulse cycle.
    done       <= '1' when (state = ST_DONE) and (start = '0') else '0';
    ciphertext <= beta_reg.a & beta_reg.b & beta_reg.c & beta_reg.d;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ lutram_read                                                     ║
    -- ║                                                                 ║
    -- ║ Registered read from the 4 S-box LUTRAMs. addr_a..d are        ║
    -- ║ driven combinatorially by addr_comb. The rising edge that       ║
    -- ║ closes ADDR or COMPUTE samples those addresses; s1_out..s4_out  ║
    -- ║ are stable throughout the following COMPUTE cycle.             ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    lutram_read : process(aclk) is
    begin
        if rising_edge(aclk) then
            s1_out <= SBOX1_r(addr_a);
            s2_out <= SBOX2_r(addr_b);
            s3_out <= SBOX3_r(addr_c);
            s4_out <= SBOX4_r(addr_d);
        end if;
    end process lutram_read;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ f_result_comb_proc                                              ║
    -- ║                                                                 ║
    -- ║ Pure combinatorial replica of the f_result computation. This    ║
    -- ║ is the only additional logic on the critical path vs the BRAM   ║
    -- ║ baseline: the forwarding chain is                               ║
    -- ║   s1..s4 → f_result_comb (adder tree) →                        ║
    -- ║   beta XOR f_result (1 XOR) → I (adder/XOR + barrel rotate) → ║
    -- ║   byte extract → LUTRAM address.                                ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    f_result_comb_proc : process(counter, f_step, s1_out, s2_out, s3_out, s4_out) is
        variable s1v, s2v, s3v, s4v : unsigned(31 downto 0);
    begin
        s1v := unsigned(s1_out);
        s2v := unsigned(s2_out);
        s3v := unsigned(s3_out);
        s4v := unsigned(s4_out);

        -- ── Q rounds (counter 0..5) ────────────────────────────────────
        -- step 0,3 → f1   step 1 → f2   step 2 → f3
        -- ── QBAR rounds (counter 6..11) ───────────────────────────────
        -- step 0,3 → f1   step 1 → f3   step 2 → f2
        if counter < 6 then
            case f_step is
                when 0 | 3 =>  -- f1: ((S1^S2)-S3)+S4
                    f_result_comb <= std_ulogic_vector((s1v xor s2v) - s3v + s4v);
                when 1 =>      -- f2: ((S1-S2)+S3)^S4
                    f_result_comb <= std_ulogic_vector(((s1v - s2v) + s3v) xor s4v);
                when 2 =>      -- f3: ((S1+S2)^S3)-S4
                    f_result_comb <= std_ulogic_vector(((s1v + s2v) xor s3v) - s4v);
            end case;
        else
            case f_step is
                when 0 | 3 =>  -- f1
                    f_result_comb <= std_ulogic_vector((s1v xor s2v) - s3v + s4v);
                when 1 =>      -- f3
                    f_result_comb <= std_ulogic_vector(((s1v + s2v) xor s3v) - s4v);
                when 2 =>      -- f2
                    f_result_comb <= std_ulogic_vector(((s1v - s2v) + s3v) xor s4v);
            end case;
        end if;
    end process f_result_comb_proc;

    -- ╔═════════════════════════════════════════════════════════════════╗
    -- ║ addr_comb                                                       ║
    -- ║                                                                 ║
    -- ║ Combinatorial LUTRAM address driver.                            ║
    -- ║                                                                 ║
    -- ║ ADDR state (first step only):                                   ║
    -- ║   Computes addresses for the CURRENT f-function (step 0) using  ║
    -- ║ the freshly latched beta_reg. Same logic as the BRAM baseline.  ║
    -- ║                                                                 ║
    -- ║ COMPUTE state (all subsequent steps):                           ║
    -- ║   Computes addresses for the NEXT f-function (step N+1) while   ║
    -- ║   the current step N is being processed. Uses forwarded beta    ║
    -- ║   values in Q rounds (where the next step reads the word just   ║
    -- ║   updated) and registered beta values in QBAR rounds (where all ║
    -- ║   dependencies are satisfied by registered values).             ║
    -- ║                                                                 ║
    -- ║ Forwarding table:                                               ║
    -- ║   Q step 0→1 : forward C' = beta.c XOR f_result_comb           ║
    -- ║   Q step 1→2 : forward B' = beta.b XOR f_result_comb           ║
    -- ║   Q step 2→3 : forward A' = beta.a XOR f_result_comb           ║
    -- ║   Q step 3→0 (counter<5): forward D' = beta.d XOR f_result     ║
    -- ║   Q step 3→0 (counter=5, next is QBAR): no forward (A reg ok)  ║
    -- ║   QBAR all transitions: no forward                              ║
    -- ╚═════════════════════════════════════════════════════════════════╝
    addr_comb : process(state, counter, f_step, beta_reg, kr_i, km_i, f_result_comb) is
        variable d_v         : word32_t;
        variable km_v        : word32_t;
        variable kr_v        : word5_t;
        variable i_val       : word32_t;
        variable ki          : integer range 0 to 3;
        variable nxt_f_step  : integer range 0 to 3;
        variable nxt_counter : integer range 0 to 11;
        variable fwd_word    : word32_t;
        variable use_fwd     : boolean;
    begin
        addr_a <= 0;
        addr_b <= 0;
        addr_c <= 0;
        addr_d <= 0;

        -- ── ADDR state: addresses for CURRENT step (step 0 only) ──────
        if state = ADDR then
            -- Input data word for step 0: always D in Q (counter=0, f_step=0)
            if counter < 6 then
                case f_step is
                    when 0 => d_v := beta_reg.d;
                    when 1 => d_v := beta_reg.c;
                    when 2 => d_v := beta_reg.b;
                    when 3 => d_v := beta_reg.a;
                end case;
                ki := f_step;
            else
                case f_step is
                    when 0 => d_v := beta_reg.a;
                    when 1 => d_v := beta_reg.b;
                    when 2 => d_v := beta_reg.c;
                    when 3 => d_v := beta_reg.d;
                end case;
                ki := 3 - f_step;
            end if;

            km_v := km_i(counter)(ki);
            kr_v := kr_i(counter)(ki);

            if counter < 6 then
                case f_step is
                    when 0 | 3 =>
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                    when 1 =>
                        i_val := rotate_left32(km_v xor d_v, kr_v);
                    when 2 =>
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                end case;
            else
                case f_step is
                    when 0 | 3 =>
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                    when 1 =>
                        i_val := rotate_left32(
                            std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                    when 2 =>
                        i_val := rotate_left32(km_v xor d_v, kr_v);
                end case;
            end if;

            addr_a <= to_integer(unsigned(i_val(31 downto 24)));
            addr_b <= to_integer(unsigned(i_val(23 downto 16)));
            addr_c <= to_integer(unsigned(i_val(15 downto  8)));
            addr_d <= to_integer(unsigned(i_val( 7 downto  0)));

        -- ── COMPUTE state: addresses for NEXT step ─────────────────────
        elsif state = COMPUTE then

            -- Skip address generation on the very last step (goes to ST_DONE)
            if not (counter = 11 and f_step = 3) then

                -- ── Next step indices ──────────────────────────────────────
                if f_step < 3 then
                    nxt_f_step  := f_step + 1;
                    nxt_counter := counter;
                else
                    nxt_f_step  := 0;
                    nxt_counter := counter + 1;  -- safe: only here when counter < 11
                end if;

                -- ── Forwarding: which beta word to use ─────────────────────
                --
                -- Forwarding is needed when the next step's input word is the
                -- same word that the CURRENT step is about to update. Since the
                -- update is a registered signal assignment (takes effect on the
                -- NEXT clock edge), addr_comb must use the not-yet-registered
                -- forwarded value: beta_reg.x XOR f_result_comb.
                --
                -- Q rounds: forwarding needed at every step transition except
                --   counter=5, f_step=3 → QBAR (next reads A, already registered).
                -- QBAR rounds: no forwarding needed (all deps 2+ cycles old).
                use_fwd  := false;
                fwd_word := (others => '0');

                if counter < 6 then
                    case f_step is
                        when 0 =>  -- updates C; next step 1 reads C'
                            use_fwd  := true;
                            fwd_word := beta_reg.c xor f_result_comb;
                        when 1 =>  -- updates B; next step 2 reads B'
                            use_fwd  := true;
                            fwd_word := beta_reg.b xor f_result_comb;
                        when 2 =>  -- updates A; next step 3 reads A'
                            use_fwd  := true;
                            fwd_word := beta_reg.a xor f_result_comb;
                        when 3 =>  -- updates D; next step reads D' only if still in Q
                            if counter < 5 then
                                use_fwd  := true;
                                fwd_word := beta_reg.d xor f_result_comb;
                            end if;
                            -- counter=5: next is QBAR step 0, reads A which is
                            -- already correctly registered from step 2 (2 cycles ago)
                    end case;
                end if;
                -- QBAR rounds: use_fwd stays false; registered values are correct

                -- ── Select input data word for next step ───────────────────
                if use_fwd then
                    d_v := fwd_word;
                else
                    if nxt_counter < 6 then
                        case nxt_f_step is
                            when 0 => d_v := beta_reg.d;
                            when 1 => d_v := beta_reg.c;
                            when 2 => d_v := beta_reg.b;
                            when 3 => d_v := beta_reg.a;
                        end case;
                    else
                        case nxt_f_step is
                            when 0 => d_v := beta_reg.a;
                            when 1 => d_v := beta_reg.b;
                            when 2 => d_v := beta_reg.c;
                            when 3 => d_v := beta_reg.d;
                        end case;
                    end if;
                end if;

                -- ── Subkey index for next step ─────────────────────────────
                if nxt_counter < 6 then
                    ki := nxt_f_step;
                else
                    ki := 3 - nxt_f_step;
                end if;

                km_v := km_i(nxt_counter)(ki);
                kr_v := kr_i(nxt_counter)(ki);

                -- ── Compute I for next step ────────────────────────────────
                if nxt_counter < 6 then
                    case nxt_f_step is
                        when 0 | 3 =>
                            i_val := rotate_left32(
                                std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                        when 1 =>
                            i_val := rotate_left32(km_v xor d_v, kr_v);
                        when 2 =>
                            i_val := rotate_left32(
                                std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                    end case;
                else
                    case nxt_f_step is
                        when 0 | 3 =>
                            i_val := rotate_left32(
                                std_ulogic_vector(unsigned(km_v) + unsigned(d_v)), kr_v);
                        when 1 =>
                            i_val := rotate_left32(
                                std_ulogic_vector(unsigned(km_v) - unsigned(d_v)), kr_v);
                        when 2 =>
                            i_val := rotate_left32(km_v xor d_v, kr_v);
                    end case;
                end if;

                addr_a <= to_integer(unsigned(i_val(31 downto 24)));
                addr_b <= to_integer(unsigned(i_val(23 downto 16)));
                addr_c <= to_integer(unsigned(i_val(15 downto  8)));
                addr_d <= to_integer(unsigned(i_val( 7 downto  0)));

            end if;  -- not last step
        end if;  -- state
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
                beta_reg.a <= (others => '0');
                beta_reg.b <= (others => '0');
                beta_reg.c <= (others => '0');
                beta_reg.d <= (others => '0');
            else
                case state is

                    -- ── IDLE ───────────────────────────────────────────
                    when IDLE =>
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
                    -- addr_comb drives LUTRAM addresses for step 0 this cycle.
                    -- lutram_read samples them at this rising edge.
                    -- s1_out..s4_out will be valid in the first COMPUTE.
                    -- Only entered once per encryption run.
                    when ADDR =>
                        state <= COMPUTE;

                    -- ── COMPUTE ────────────────────────────────────────
                    -- LUTRAM outputs are valid for the CURRENT step.
                    -- Compute f-function output and XOR into target beta word.
                    -- addr_comb simultaneously drives LUTRAM addresses for
                    -- the NEXT step (pipelined). State loops to COMPUTE
                    -- (not ADDR) for all steps except the last.
                    when COMPUTE =>
                        s1v := unsigned(s1_out);
                        s2v := unsigned(s2_out);
                        s3v := unsigned(s3_out);
                        s4v := unsigned(s4_out);

                        -- ── f-function output ──────────────────────────────
                        -- Q:    step 0,3 → f1   step 1 → f2   step 2 → f3
                        -- QBAR: step 0,3 → f1   step 1 → f3   step 2 → f2
                        if counter < 6 then
                            case f_step is
                                when 0 | 3 =>
                                    f_result := std_ulogic_vector(
                                        (s1v xor s2v) - s3v + s4v);
                                when 1 =>
                                    f_result := std_ulogic_vector(
                                        ((s1v - s2v) + s3v) xor s4v);
                                when 2 =>
                                    f_result := std_ulogic_vector(
                                        ((s1v + s2v) xor s3v) - s4v);
                            end case;
                        else
                            case f_step is
                                when 0 | 3 =>
                                    f_result := std_ulogic_vector(
                                        (s1v xor s2v) - s3v + s4v);
                                when 1 =>
                                    f_result := std_ulogic_vector(
                                        ((s1v + s2v) xor s3v) - s4v);
                                when 2 =>
                                    f_result := std_ulogic_vector(
                                        ((s1v - s2v) + s3v) xor s4v);
                            end case;
                        end if;

                        -- ── XOR result into target beta word ───────────────
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

                        -- ── Advance counters ───────────────────────────────
                        -- Transition: COMPUTE → COMPUTE (pipelined) for all
                        -- steps except the last, which goes to ST_DONE.
                        if counter = 11 and f_step = 3 then
                            state <= ST_DONE;
                        elsif f_step = 3 then
                            f_step  <= 0;
                            counter <= counter + 1;
                            state   <= COMPUTE;
                        else
                            f_step <= f_step + 1;
                            state  <= COMPUTE;
                        end if;

                    -- ── ST_DONE ────────────────────────────────────────
                    when ST_DONE =>
                        if start = '1' then
                            beta_reg.a <= plaintext(127 downto 96);
                            beta_reg.b <= plaintext( 95 downto 64);
                            beta_reg.c <= plaintext( 63 downto 32);
                            beta_reg.d <= plaintext( 31 downto  0);
                            counter    <= 0;
                            f_step     <= 0;
                            state      <= ADDR;  -- fresh ADDR needed for new block
                        end if;

                end case;
            end if;
        end if;
    end process main_fsm;

end architecture rtl;