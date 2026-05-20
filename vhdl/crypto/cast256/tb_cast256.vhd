-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │ tb_cast256.vhd                                                           │
-- │                                                                          │
-- │ Simulation testbench for the cast256 top-level entity.                  │
-- │ Drives one key + plaintext pair through the full handshake, then         │
-- │ prints the ciphertext hex string to the simulator console.               │
-- │                                                                          │
-- │ KEY_HEX and PT_HEX are entity generics, so they can be overridden       │
-- │ from the command line without recompiling.                               │
-- │                                                                          │
-- │ Build (once):                                                             │
-- │   ghdl -a  --std=08 cast256_pkg.vhd                                      │
-- │   ghdl -a  --std=08 cast256_ks.vhd                                       │
-- │   ghdl -a  --std=08 cast256_enc.vhd                                      │
-- │   ghdl -a  --std=08 cast256.vhd                                          │
-- │   ghdl -a  --std=08 tb_cast256.vhd                                       │
-- │   ghdl -e  --std=08 tb_cast256                                            │
-- │                                                                          │
-- │ Run with the default RFC 2612 vector:                                    │
-- │   ghdl -r  --std=08 tb_cast256                                            │
-- │                                                                          │
-- │ Run with a custom vector:                                                 │
-- │   ghdl -r  --std=08 tb_cast256                                            │
-- │       -gKEY_HEX=<64 hex chars>                                           │
-- │       -gPT_HEX=<32 hex chars>                                            │
-- └──────────────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ┌──────────────────────────────────────────────────────────────────────────┐
-- │ Generics                                                                 │
-- │   KEY_HEX [string(1 to 64)] : 256-bit key as 64 lowercase hex chars     │
-- │   PT_HEX  [string(1 to 32)] : 128-bit plaintext as 32 lowercase hex     │
-- │                                                                          │
-- │ Defaults are the RFC 2612 Appendix A 256-bit test vector.                │
-- │ Expected ciphertext : 4f6a2038286897b9c9870136553317fa                  │
-- └──────────────────────────────────────────────────────────────────────────┘
entity tb_cast256 is
    generic (
        KEY_HEX : string(1 to 64) :=
            "2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604";
        PT_HEX  : string(1 to 32) := "00000000000000000000000000000000"
    );
end entity tb_cast256;

architecture sim of tb_cast256 is

    -- ┌──────────────────────────────────────┐
    -- │ Clock period                         │
    -- └──────────────────────────────────────┘
    constant CLK_PERIOD : time := 10 ns;

    -- ┌──────────────────────────────────────┐
    -- │ DUT signals                          │
    -- └──────────────────────────────────────┘
    signal aclk          : std_ulogic := '0';
    signal aresetn       : std_ulogic := '0';
    signal key           : std_ulogic_vector(255 downto 0) := (others => '0');
    signal key_valid     : std_ulogic := '0';
    signal key_ready     : std_ulogic;
    signal plaintext     : std_ulogic_vector(127 downto 0) := (others => '0');
    signal encrypt_start : std_ulogic := '0';
    signal ciphertext    : std_ulogic_vector(127 downto 0);
    signal enc_done      : std_ulogic;

    -- ┌──────────────────────────────────────┐
    -- │ Hex-string parsing                   │
    -- └──────────────────────────────────────┘

    -- Convert a single hex character to a 4-bit vector.
    function hex_char_to_nibble(c : character) return std_ulogic_vector is
        variable nibble : std_ulogic_vector(3 downto 0);
    begin
        case c is
            when '0' => nibble := "0000";
            when '1' => nibble := "0001";
            when '2' => nibble := "0010";
            when '3' => nibble := "0011";
            when '4' => nibble := "0100";
            when '5' => nibble := "0101";
            when '6' => nibble := "0110";
            when '7' => nibble := "0111";
            when '8' => nibble := "1000";
            when '9' => nibble := "1001";
            when 'a' | 'A' => nibble := "1010";
            when 'b' | 'B' => nibble := "1011";
            when 'c' | 'C' => nibble := "1100";
            when 'd' | 'D' => nibble := "1101";
            when 'e' | 'E' => nibble := "1110";
            when 'f' | 'F' => nibble := "1111";
            when others    => nibble := "0000";
        end case;
        return nibble;
    end function;

    -- Parse a 64-char hex string into a 256-bit vector.
    function hex_to_slv256(s : string) return std_ulogic_vector is
        variable result : std_ulogic_vector(255 downto 0);
    begin
        for i in 1 to 64 loop
            result(255 - (i-1)*4 downto 256 - i*4) :=
                hex_char_to_nibble(s(i));
        end loop;
        return result;
    end function;

    -- Parse a 32-char hex string into a 128-bit vector.
    function hex_to_slv128(s : string) return std_ulogic_vector is
        variable result : std_ulogic_vector(127 downto 0);
    begin
        for i in 1 to 32 loop
            result(127 - (i-1)*4 downto 128 - i*4) :=
                hex_char_to_nibble(s(i));
        end loop;
        return result;
    end function;

    -- Convert a 128-bit vector to a 32-char lowercase hex string for printing.
    function slv128_to_hex(v : std_ulogic_vector(127 downto 0)) return string is
        constant HEX_CHARS : string := "0123456789abcdef";
        variable result    : string(1 to 32);
        variable nibble    : integer;
    begin
        for i in 0 to 31 loop
            nibble := to_integer(
                unsigned(v(127 - i*4 downto 124 - i*4))
            );
            result(i + 1) := HEX_CHARS(nibble + 1);
        end loop;
        return result;
    end function;

begin

    -- ┌──────────────────────────────────────┐
    -- │ DUT instantiation                    │
    -- └──────────────────────────────────────┘
    u_dut : entity work.cast256
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            key           => key,
            key_valid     => key_valid,
            key_ready     => key_ready,
            plaintext     => plaintext,
            encrypt_start => encrypt_start,
            ciphertext    => ciphertext,
            enc_done      => enc_done
        );

    -- ┌──────────────────────────────────────┐
    -- │ Clock generation                     │
    -- └──────────────────────────────────────┘
    aclk <= not aclk after CLK_PERIOD / 2;

    -- ┌──────────────────────────────────────┐
    -- │ Stimulus                             │
    -- └──────────────────────────────────────┘
    stim : process is
    begin
        -- Load the test vector from generics
        key       <= hex_to_slv256(KEY_HEX);
        plaintext <= hex_to_slv128(PT_HEX);

        -- 1. Hold reset for 2 cycles
        aresetn <= '0';
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- 2. Pulse key_valid for 1 cycle to start the key schedule
        key_valid <= '1';
        wait until rising_edge(aclk);
        key_valid <= '0';

        -- 3. Wait for key_ready
        wait until rising_edge(aclk) and key_ready = '1';

        -- 4. Pulse encrypt_start for 1 cycle to start encryption
        encrypt_start <= '1';
        wait until rising_edge(aclk);
        encrypt_start <= '0';

        -- 5. Wait for enc_done
        wait until rising_edge(aclk) and enc_done = '1';

        -- 6. Print result — CIPHERTEXT line is parsed by run_kat.sh
        report "CIPHERTEXT:" & slv128_to_hex(ciphertext);

        -- 7. Stop simulation
        wait for CLK_PERIOD * 2;
        std.env.stop;
    end process;

end architecture sim;
