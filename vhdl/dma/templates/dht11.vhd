-- MAIN-ONLY: DO NOT MODIFY THIS FILE
--
-- Copyright © Telecom Paris
-- Copyright © Renaud Pacalet (renaud.pacalet@telecom-paris.fr)
-- 
-- This file must be used under the terms of the CeCILL. This source
-- file is licensed as described in the file COPYING, which you should
-- have received as part of this distribution. The terms are also
-- available at:
-- https://cecill.info/licences/Licence_CeCILL_V2.1-en.html
--

--
-- DHT11 emulator
--
-- Emulates the DHT11 sensor. Returns random values for the integer parts of temperature and relative humidity. Returns zero for fractional parts. Randomly emulates checksum errors for about 1/10 acquisitions by flipping one bit of the checksum.
--
-- Detects that low level of start phase and warm-up time are larger or equal start_us (warm_us) and strictly less 2*start_us (2*warm_us).
--
-- A simulation environment can monitor the dso output and check that the simulated controller reacts during the high states of dso.
--
--   Generic parameters:
--     start_us defines how long in micro-seconds the controller must force the data line low to trigger an acquisition. Its value is defined as 18000 (18 ms) by the data sheet but it is kept programmable to allow shorter values and thus speed-up simulations.
--     warm_us defines how long in micro-seconds the controller must wait after the reset before trigerring the first acquisition or between two successive acquisitions. Its value is defined as 1000000 (1 s) by the data sheet but it is kept programmable to allow shorter values and thus speed-up simulations.
--
--   Ports:
--     data: the data line, std_logic (resolved type) because it serves as input and output (inout mode) and is thus driven by the sensor, the controller and the pull-up resistor.
--     dso:  data strobe out. The emulator asserts dso high for 20 us at the end of an acquisition.
--     cerr: checksum error. The emulator asserts cerr high at the beginning of an acquisition when it emulates a checksum error. It deasserts cerr at the beginning of the next acquisition (unless it also emulates a checksum error).

library ieee;
use ieee.std_logic_1164.all;

entity dht11 is
    generic(
        start_us: natural; -- duration in micro-seconds of low state of data line during start command
        warm_us:  natural  -- minimum duration in micro-seconds of idle state after reset or between two acquisitions
    );
    port(
        data: inout std_logic;                     -- data line
        dso:  out   std_ulogic;                    -- data strobe out
        cerr: out   std_ulogic;                    -- checksum error
        val:  out   std_ulogic_vector(39 downto 0) -- acquired value
    );
end entity dht11;

use std.env.all;

library ieee;
use ieee.numeric_std_unsigned.all;

use work.rnd_pkg.all;
use work.utils_pkg.all;

architecture beh of dht11 is

    constant start_high_min:   natural := 20;       -- Minimum of start high phase
    constant start_high_max:   natural := 40;       -- Maximum of start high phase
    constant acknowledge_high: natural := 80;       -- Acknowledge high phases
    constant acknowledge_low:  natural := 80;       -- Acknowledge low phases
    constant bit_low:          natural := 50;       -- Bit low phase
    constant bit0_high_min:    natural := 26;       -- Minimum of bit 0 high phase
    constant bit0_high_max:    natural := 28;       -- Maximum of bit 0 high phase
    constant bit1_high:        natural := 70;       -- Bit 1 high phase

    signal data_in: x01;

begin

    data_in <= to_x01(data);

    process
        variable rg:        rnd_generator;
        variable t:         time;
        variable delta_min: natural;
        variable delta_max: natural;
        variable delta:     natural;
        variable value:     std_ulogic_vector(39 downto 0) := (others => '0');
        type delta_t is
            record
                minh0: natural; -- minimum duration of high level if transmitted bit is '0'
                maxh0: natural; -- maximum duration of high level if transmitted bit is '0'
                minh1: natural; -- minimum duration of high level if transmitted bit is '1'
                maxh1: natural; -- maximum duration of high level if transmitted bit is '1'
                l:     natural; -- duration of following low level
            end record delta_t;
        type delta_vector is array(natural range <>) of delta_t;
        constant deltas: delta_vector(0 to 83) := (
            0      => (start_high_min, start_high_max, start_high_min, start_high_max, acknowledge_low),
            1      => (acknowledge_high, acknowledge_high, acknowledge_high, acknowledge_high, bit_low),
            others => (bit0_high_min, bit0_high_max, bit1_high, bit1_high, bit_low));
        variable tmp : natural;
    begin
        data <= 'Z';
        cerr <= '0';
        dso  <= '0';
        val  <= (others => '0');
        loop
            t := now;
            wait until falling_edge(data_in) for warm_us * 2 us;
            t := now - t;
            check_ref(t < warm_us * 2 us, "", "  WRONG WARM DURATION: EXPECTED LESS THAN " & to_string(2 * warm_us) & " US, GOT " & to_string(t));
            t := now;
            wait until rising_edge(data_in) for start_us * 2 us;
            t := now - t;
            check_ref(t >= start_us * 1 us, "", "  WRONG DURATION OF START COMMAND: EXPECTED AT LEAST " & to_string(start_us) & " US, GOT " & to_string(t));
            check_ref(t < start_us * 2 us, "", "  WRONG DURATION OF START COMMAND: EXPECTED LESS THAN " & to_string(2 * start_us) & " US, GOT " & to_string(t));
            data <= 'Z';
            cerr <= '0';
            dso  <= '0';
            val  <= (others => '0');
            value(39 downto 32) := rg.get_std_ulogic_vector(8);
            value(23 downto 16) := rg.get_std_ulogic_vector(8);
            value(7 downto 0)   := value(39 downto 32) + value(23 downto 16);
            tmp := rg.get_integer(0, 79);
            if tmp < 8 then
                value(tmp) := not value(tmp);
                cerr <= '1';
            end if;
            print("DHT11: START SIGNAL RECEIVED - " & to_string(now));
            print("  SENDING DATA " & to_string(value));
            if tmp < 8 then
                print("  WITH CHECKSUM ERROR AT BIT #" & to_string(tmp));
            end if;
            val <= std_ulogic_vector(value);
            for i in 0 to 41 loop
                if i > 1 and value(41 - i) = '1' then
                    delta_min := deltas(i).minh1;
                    delta_max := deltas(i).maxh1;
                else
                    delta_min := deltas(i).minh0;
                    delta_max := deltas(i).maxh0;
                end if;
                delta := rg.get_integer(delta_min, delta_max);
                wait for delta * 1 us;
                data <= '0';
                delta_min := deltas(i).l;
                delta_max := deltas(i).l;
                delta := rg.get_integer(delta_min, delta_max);
                wait for delta * 1 us;
                data <= 'Z';
                if i = 41 then
                    dso <= '1', '0' after 20 us;
                end if;
            end loop;
        end loop;
    end process;

    process
        variable t: time;
    begin
        wait until data = '0';
        t := now;
        check_ref(t >= warm_us * 1 us, "", "  WRONG DURATION OF WARM-UP TIME: EXPECTED AT LEAST " & to_string(warm_us) & " US, GOT " & to_string(t));
        check_ref(t < warm_us * 2 us, "", "  WRONG DURATION OF WARM-UP TIME: EXPECTED LESS THAN " & to_string(2 * warm_us) & " US, GOT " & to_string(t));
        loop
            wait until dso = '1';
            t := now;
            wait until data = '0';
            t := now - t;
            check_ref(t >= warm_us * 1 us, "", "  WRONG DURATION OF WARM-UP TIME: EXPECTED AT LEAST " & to_string(warm_us) & " US, GOT " & to_string(t));
            check_ref(t < warm_us * 2 us, "", "  WRONG DURATION OF WARM-UP TIME: EXPECTED LESS THAN " & to_string(2 * warm_us) & " US, GOT " & to_string(t));
        end loop;
    end process;

end architecture beh;

-- vim: set tabstop=4 softtabstop=4 shiftwidth=4 expandtab textwidth=0:
