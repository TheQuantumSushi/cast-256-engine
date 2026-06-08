-- Testbench for axi_slave (Milestone 3)
-- Register map: Key(0x000-0x01C), IV(0x020-0x028), AAD addr/len(0x030-0x034),
--               PT addr/len(0x038-0x03C), CT addr/len(0x040-0x044),
--               Tag(0x048-0x054), CSR(0x058), Debug(0x05C).
-- Tests: reset state, key/iv/config writes, key_loaded_pulse, CSR status
--        readback, ct_len/debug reads, DECERR on reserved/unmapped addresses,
--        write-while-busy protection, tag R/W, tag capture on enc done,
--        soft reset, AW-first and W-first channel ordering, write-only
--        registers read back zero.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_slave is
end entity tb_axi_slave;

architecture sim of tb_axi_slave is

    component axi_slave is
        port (
            aclk : in std_ulogic;
            aresetn : in std_ulogic;
            s0_axi_awaddr : in std_ulogic_vector(11 downto 0);
            s0_axi_awvalid : in std_ulogic;
            s0_axi_awready : out std_ulogic;
            s0_axi_wdata : in std_ulogic_vector(31 downto 0);
            s0_axi_wstrb : in std_ulogic_vector(3 downto 0);
            s0_axi_wvalid : in std_ulogic;
            s0_axi_wready : out std_ulogic;
            s0_axi_bresp : out std_ulogic_vector(1 downto 0);
            s0_axi_bvalid : out std_ulogic;
            s0_axi_bready : in std_ulogic;
            s0_axi_araddr : in std_ulogic_vector(11 downto 0);
            s0_axi_arvalid : in std_ulogic;
            s0_axi_arready : out std_ulogic;
            s0_axi_rdata : out std_ulogic_vector(31 downto 0);
            s0_axi_rresp : out std_ulogic_vector(1 downto 0);
            s0_axi_rvalid : out std_ulogic;
            s0_axi_rready : in std_ulogic;
            key_reg : out std_ulogic_vector(255 downto 0);
            iv_reg : out std_ulogic_vector(95 downto 0);
            aad_addr_reg : out std_ulogic_vector(31 downto 0);
            aad_len_reg : out std_ulogic_vector(31 downto 0);
            pt_addr_reg : out std_ulogic_vector(31 downto 0);
            pt_len_reg : out std_ulogic_vector(31 downto 0);
            ct_addr_reg : out std_ulogic_vector(31 downto 0);
            tag_reg_out : out std_ulogic_vector(127 downto 0);
            csr_start : out std_ulogic;
            csr_soft_reset : out std_ulogic;
            csr_mode : out std_ulogic;
            ct_len_in : in std_ulogic_vector(31 downto 0);
            tag_computed_in : in std_ulogic_vector(127 downto 0);
            csr_busy : in std_ulogic;
            csr_done : in std_ulogic;
            csr_tag_valid : in std_ulogic;
            csr_error : in std_ulogic;
            fsm_state_in : in std_ulogic_vector(3 downto 0);
            key_loaded_pulse : out std_ulogic
        );
    end component;

    constant CLK_PERIOD : time := 10 ns;
    constant TIMEOUT : time := 200 * CLK_PERIOD;

    signal aclk : std_ulogic := '0';
    signal aresetn : std_ulogic := '0';

    -- AXI write channels
    signal awaddr : std_ulogic_vector(11 downto 0) := (others => '0');
    signal awvalid : std_ulogic := '0';
    signal awready : std_ulogic;
    signal wdata : std_ulogic_vector(31 downto 0) := (others => '0');
    signal wstrb : std_ulogic_vector(3 downto 0) := "1111";
    signal wvalid : std_ulogic := '0';
    signal wready : std_ulogic;
    signal bresp : std_ulogic_vector(1 downto 0);
    signal bvalid : std_ulogic;
    signal bready : std_ulogic := '0';

    -- AXI read channels
    signal araddr : std_ulogic_vector(11 downto 0) := (others => '0');
    signal arvalid : std_ulogic := '0';
    signal arready : std_ulogic;
    signal rdata : std_ulogic_vector(31 downto 0);
    signal rresp : std_ulogic_vector(1 downto 0);
    signal rvalid : std_ulogic;
    signal rready : std_ulogic := '0';

    -- Register outputs
    signal key_reg : std_ulogic_vector(255 downto 0);
    signal iv_reg : std_ulogic_vector(95 downto 0);
    signal aad_addr_reg : std_ulogic_vector(31 downto 0);
    signal aad_len_reg : std_ulogic_vector(31 downto 0);
    signal pt_addr_reg : std_ulogic_vector(31 downto 0);
    signal pt_len_reg : std_ulogic_vector(31 downto 0);
    signal ct_addr_reg : std_ulogic_vector(31 downto 0);
    signal tag_reg_out : std_ulogic_vector(127 downto 0);
    signal csr_start : std_ulogic;
    signal csr_soft_reset : std_ulogic;
    signal csr_mode : std_ulogic;
    signal key_loaded_pulse : std_ulogic;

    -- Datapath inputs (driven by stimulus)
    signal ct_len_in : std_ulogic_vector(31 downto 0) := (others => '0');
    signal tag_computed_in : std_ulogic_vector(127 downto 0) := (others => '0');
    signal csr_busy : std_ulogic := '0';
    signal csr_done : std_ulogic := '0';
    signal csr_tag_valid : std_ulogic := '0';
    signal csr_error : std_ulogic := '0';
    signal fsm_state_in : std_ulogic_vector(3 downto 0) := (others => '0');

    -- One-cycle pulse capture flags
    signal key_loaded_seen : std_ulogic := '0';
    signal start_seen : std_ulogic := '0';

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    u_dut : axi_slave
        port map (
            aclk => aclk,
            aresetn => aresetn,
            s0_axi_awaddr => awaddr,
            s0_axi_awvalid => awvalid,
            s0_axi_awready => awready,
            s0_axi_wdata => wdata,
            s0_axi_wstrb => wstrb,
            s0_axi_wvalid => wvalid,
            s0_axi_wready => wready,
            s0_axi_bresp => bresp,
            s0_axi_bvalid => bvalid,
            s0_axi_bready => bready,
            s0_axi_araddr => araddr,
            s0_axi_arvalid => arvalid,
            s0_axi_arready => arready,
            s0_axi_rdata => rdata,
            s0_axi_rresp => rresp,
            s0_axi_rvalid => rvalid,
            s0_axi_rready => rready,
            key_reg => key_reg,
            iv_reg => iv_reg,
            aad_addr_reg => aad_addr_reg,
            aad_len_reg => aad_len_reg,
            pt_addr_reg => pt_addr_reg,
            pt_len_reg => pt_len_reg,
            ct_addr_reg => ct_addr_reg,
            tag_reg_out => tag_reg_out,
            csr_start => csr_start,
            csr_soft_reset => csr_soft_reset,
            csr_mode => csr_mode,
            ct_len_in => ct_len_in,
            tag_computed_in => tag_computed_in,
            csr_busy => csr_busy,
            csr_done => csr_done,
            csr_tag_valid => csr_tag_valid,
            csr_error => csr_error,
            fsm_state_in => fsm_state_in,
            key_loaded_pulse => key_loaded_pulse
        );

    ---------------------------------------------------------------------------
    -- One-cycle pulse monitors
    ---------------------------------------------------------------------------
    p_mon_key : process(aclk)
    begin
        if rising_edge(aclk) then
            if key_loaded_pulse = '1' then
                key_loaded_seen <= '1';
            end if;
        end if;
    end process p_mon_key;

    p_mon_start : process(aclk)
    begin
        if rising_edge(aclk) then
            if csr_start = '1' then
                start_seen <= '1';
            end if;
        end if;
    end process p_mon_start;

    ---------------------------------------------------------------------------
    -- Stimulus + checker
    ---------------------------------------------------------------------------
    p_stim : process
        variable rd_val : std_ulogic_vector(31 downto 0);
        variable rd_resp : std_ulogic_vector(1 downto 0);

        -- AXI4-Lite write: simultaneous AW + W (WR_IDLE -> WR_BOTH)
        procedure axi_write(
            addr : in std_ulogic_vector(11 downto 0);
            data : in std_ulogic_vector(31 downto 0);
            strb : in std_ulogic_vector(3 downto 0) := "1111"
        ) is
        begin
            awaddr <= addr;
            awvalid <= '1';
            wdata <= data;
            wstrb <= strb;
            wvalid <= '1';
            wait until rising_edge(aclk) and awready = '1' and wready = '1'
                for TIMEOUT;
            assert awready = '1' and wready = '1'
                report "axi_write: timeout waiting for awready/wready addr=" &
                       integer'image(to_integer(unsigned(addr))) severity failure;
            awvalid <= '0';
            wvalid <= '0';
            bready <= '1';
            wait until rising_edge(aclk) and bvalid = '1' for TIMEOUT;
            assert bvalid = '1'
                report "axi_write: timeout waiting for bvalid" severity failure;
            bready <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- AXI4-Lite write: AW first, W arrives later (WR_IDLE -> WR_HAVE_ADDR -> WR_BOTH)
        procedure axi_write_aw_first(
            addr : in std_ulogic_vector(11 downto 0);
            data : in std_ulogic_vector(31 downto 0)
        ) is
        begin
            awaddr <= addr;
            awvalid <= '1';
            wait until rising_edge(aclk) and awready = '1' for TIMEOUT;
            assert awready = '1'
                report "axi_write_aw_first: timeout waiting for awready" severity failure;
            awvalid <= '0';
            wait for 2 * CLK_PERIOD;
            wdata <= data;
            wstrb <= "1111";
            wvalid <= '1';
            wait until rising_edge(aclk) and wready = '1' for TIMEOUT;
            assert wready = '1'
                report "axi_write_aw_first: timeout waiting for wready" severity failure;
            wvalid <= '0';
            bready <= '1';
            wait until rising_edge(aclk) and bvalid = '1' for TIMEOUT;
            assert bvalid = '1'
                report "axi_write_aw_first: timeout waiting for bvalid" severity failure;
            bready <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- AXI4-Lite write: W first, AW arrives later (WR_IDLE -> WR_HAVE_DATA -> WR_BOTH)
        procedure axi_write_w_first(
            addr : in std_ulogic_vector(11 downto 0);
            data : in std_ulogic_vector(31 downto 0)
        ) is
        begin
            wdata <= data;
            wstrb <= "1111";
            wvalid <= '1';
            wait until rising_edge(aclk) and wready = '1' for TIMEOUT;
            assert wready = '1'
                report "axi_write_w_first: timeout waiting for wready" severity failure;
            wvalid <= '0';
            wait for 2 * CLK_PERIOD;
            awaddr <= addr;
            awvalid <= '1';
            wait until rising_edge(aclk) and awready = '1' for TIMEOUT;
            assert awready = '1'
                report "axi_write_w_first: timeout waiting for awready" severity failure;
            awvalid <= '0';
            bready <= '1';
            wait until rising_edge(aclk) and bvalid = '1' for TIMEOUT;
            assert bvalid = '1'
                report "axi_write_w_first: timeout waiting for bvalid" severity failure;
            bready <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- AXI4-Lite read
        procedure axi_read(
            addr : in std_ulogic_vector(11 downto 0);
            result : out std_ulogic_vector(31 downto 0);
            resp : out std_ulogic_vector(1 downto 0)
        ) is
        begin
            araddr <= addr;
            arvalid <= '1';
            wait until rising_edge(aclk) and arready = '1' for TIMEOUT;
            assert arready = '1'
                report "axi_read: timeout waiting for arready" severity failure;
            arvalid <= '0';
            rready <= '1';
            wait until rising_edge(aclk) and rvalid = '1' for TIMEOUT;
            assert rvalid = '1'
                report "axi_read: timeout waiting for rvalid" severity failure;
            result := rdata;
            resp := rresp;
            rready <= '0';
            wait for CLK_PERIOD;
        end procedure;

    begin
        aresetn <= '0';
        wait for 4 * CLK_PERIOD;
        aresetn <= '1';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 1: After reset, register outputs are zero
        -----------------------------------------------------------------------
        assert key_reg = (255 downto 0 => '0') report "TEST1: key_reg not zero after reset" severity failure;
        assert iv_reg = (95 downto 0 => '0') report "TEST1: iv_reg not zero after reset" severity failure;
        assert aad_addr_reg = (31 downto 0 => '0') report "TEST1: aad_addr_reg not zero after reset" severity failure;
        assert csr_mode = '0' report "TEST1: csr_mode not zero after reset" severity failure;

        -----------------------------------------------------------------------
        -- Test 2: Write all 8 key words; verify key_reg and key_loaded_pulse
        -----------------------------------------------------------------------
        for w in 0 to 7 loop
            axi_write(
                std_ulogic_vector(to_unsigned(w * 4, 12)),
                std_ulogic_vector(to_unsigned(w, 32))
            );
        end loop;

        assert key_reg(255 downto 224) = x"00000000"
            report "TEST2: key word 0 mismatch" severity failure;
        assert key_reg( 31 downto   0) = x"00000007"
            report "TEST2: key word 7 mismatch" severity failure;

        wait for CLK_PERIOD;
        assert key_loaded_seen = '1'
            report "TEST2: key_loaded_pulse never asserted" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 3: Write IV words 0-2; verify iv_reg
        -----------------------------------------------------------------------
        axi_write(x"020", x"11223344");
        axi_write(x"024", x"55667788");
        axi_write(x"028", x"99AABBCC");

        assert iv_reg(95 downto 64) = x"11223344" report "TEST3: iv word 0 mismatch" severity failure;
        assert iv_reg(63 downto 32) = x"55667788" report "TEST3: iv word 1 mismatch" severity failure;
        assert iv_reg(31 downto  0) = x"99AABBCC" report "TEST3: iv word 2 mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 4: Write config registers; verify datapath outputs
        -----------------------------------------------------------------------
        axi_write(x"030", x"10000000");
        axi_write(x"034", x"00000040");
        axi_write(x"038", x"20000000");
        axi_write(x"03C", x"00000080");
        axi_write(x"040", x"30000000");

        assert aad_addr_reg = x"10000000" report "TEST4: aad_addr_reg mismatch" severity failure;
        assert aad_len_reg = x"00000040" report "TEST4: aad_len_reg mismatch" severity failure;
        assert pt_addr_reg = x"20000000" report "TEST4: pt_addr_reg mismatch" severity failure;
        assert pt_len_reg = x"00000080" report "TEST4: pt_len_reg mismatch" severity failure;
        assert ct_addr_reg = x"30000000" report "TEST4: ct_addr_reg mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 5: CSR mode field (bit 2)
        -----------------------------------------------------------------------
        axi_write(x"058", x"00000000");
        assert csr_mode = '0' report "TEST5: csr_mode should be 0 (enc)" severity failure;

        axi_write(x"058", x"00000004");
        assert csr_mode = '1' report "TEST5: csr_mode should be 1 (dec)" severity failure;

        -- Restore enc mode for later tests
        axi_write(x"058", x"00000000");

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 6: CSR start pulse (not busy); captured by monitor
        -----------------------------------------------------------------------
        axi_write(x"058", x"00000001");
        wait for CLK_PERIOD;
        assert start_seen = '1' report "TEST6: csr_start pulse never asserted" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 7: Read CSR status bits
        -----------------------------------------------------------------------
        csr_busy <= '1';
        csr_done <= '0';
        csr_tag_valid <= '1';
        csr_error <= '0';
        wait for CLK_PERIOD;

        axi_read(x"058", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST7: CSR RRESP should be OKAY" severity failure;
        assert rd_val(8) = '1' report "TEST7: CSR BUSY bit not set" severity failure;
        assert rd_val(9) = '0' report "TEST7: CSR DONE bit should be 0" severity failure;
        assert rd_val(10) = '1' report "TEST7: CSR TAG_VALID bit not set" severity failure;
        assert rd_val(11) = '0' report "TEST7: CSR ERROR bit should be 0" severity failure;
        assert rd_val(2) = '0' report "TEST7: CSR MODE should be 0 (enc)" severity failure;

        csr_busy <= '0';
        csr_done <= '1';
        csr_error <= '1';
        wait for CLK_PERIOD;

        axi_read(x"058", rd_val, rd_resp);
        assert rd_val(8) = '0' report "TEST7b: BUSY should be 0" severity failure;
        assert rd_val(9) = '1' report "TEST7b: DONE should be 1" severity failure;
        assert rd_val(11) = '1' report "TEST7b: ERROR should be 1" severity failure;

        csr_done <= '0';
        csr_error <= '0';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 8: Read CT length from datapath
        -----------------------------------------------------------------------
        ct_len_in <= x"000000C0";
        wait for CLK_PERIOD;

        axi_read(x"044", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST8: CT_LEN RRESP not OKAY" severity failure;
        assert rd_val = x"000000C0" report "TEST8: CT_LEN value mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 9: Read debug register (fsm_state in bits 3:0)
        -----------------------------------------------------------------------
        fsm_state_in <= "1010";
        wait for CLK_PERIOD;

        axi_read(x"05C", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST9: debug RRESP not OKAY" severity failure;
        assert rd_val(3 downto 0) = "1010" report "TEST9: fsm_state mismatch" severity failure;
        assert rd_val(31 downto 4) = (27 downto 0 => '0')
            report "TEST9: debug upper bits not zero" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 10: DECERR on reserved gap 0x02C
        -----------------------------------------------------------------------
        axi_write(x"02C", x"DEADBEEF");
        assert bresp = "11" report "TEST10: BRESP should be DECERR for addr 0x02C" severity failure;

        axi_read(x"02C", rd_val, rd_resp);
        assert rd_resp = "11" report "TEST10: RRESP should be DECERR for addr 0x02C" severity failure;
        assert rd_val = x"DEADBEEF" report "TEST10: DECERR read data should be 0xDEADBEEF" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 11: DECERR on unmapped address (0x100)
        -----------------------------------------------------------------------
        axi_write(x"100", x"12345678");
        assert bresp = "11" report "TEST11: BRESP should be DECERR for addr 0x100" severity failure;

        axi_read(x"100", rd_val, rd_resp);
        assert rd_resp = "11" report "TEST11: RRESP should be DECERR for addr 0x100" severity failure;
        assert rd_val = x"DEADBEEF" report "TEST11: DECERR read data should be 0xDEADBEEF" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 12: Write-while-busy -- config registers must be unchanged
        -----------------------------------------------------------------------
        csr_busy <= '1';
        wait for CLK_PERIOD;

        axi_write(x"03C", x"FFFFFFFF");
        assert pt_len_reg = x"00000080"
            report "TEST12: pt_len_reg should be unchanged while BUSY" severity failure;

        axi_write(x"000", x"DEADBEEF");
        assert key_reg(255 downto 224) = x"00000000"
            report "TEST12: key word 0 should be unchanged while BUSY" severity failure;

        axi_write(x"020", x"FFFFFFFF");
        assert iv_reg(95 downto 64) = x"11223344"
            report "TEST12: iv word 0 should be unchanged while BUSY" severity failure;

        -- Start bit must also be gated by BUSY
        axi_write(x"058", x"00000001");
        -- csr_start should NOT pulse; start_seen was already '1' from Test 6 so
        -- we verify that csr_start does not pulse again by observing it is '0'
        -- in the cycle after the write returns (registered default clears it).
        wait for CLK_PERIOD;
        assert csr_start = '0'
            report "TEST12: csr_start should not fire when BUSY" severity failure;

        csr_busy <= '0';
        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 13: Tag register R/W (decrypt mode)
        -----------------------------------------------------------------------
        axi_write(x"048", x"AABBCCDD");
        axi_write(x"04C", x"11223344");
        axi_write(x"050", x"55667788");
        axi_write(x"054", x"99AABBCC");

        assert tag_reg_out(127 downto 96) = x"AABBCCDD" report "TEST13: tag word 0 mismatch" severity failure;
        assert tag_reg_out(95 downto 64) = x"11223344" report "TEST13: tag word 1 mismatch" severity failure;
        assert tag_reg_out(63 downto 32) = x"55667788" report "TEST13: tag word 2 mismatch" severity failure;
        assert tag_reg_out(31 downto 0) = x"99AABBCC" report "TEST13: tag word 3 mismatch" severity failure;

        -- Verify via AXI reads
        axi_read(x"048", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST13: tag[127:96] RRESP not OKAY" severity failure;
        assert rd_val = x"AABBCCDD" report "TEST13: tag[127:96] readback mismatch" severity failure;

        axi_read(x"04C", rd_val, rd_resp);
        assert rd_val = x"11223344" report "TEST13: tag[95:64] readback mismatch" severity failure;

        axi_read(x"050", rd_val, rd_resp);
        assert rd_val = x"55667788" report "TEST13: tag[63:32] readback mismatch" severity failure;

        axi_read(x"054", rd_val, rd_resp);
        assert rd_val = x"99AABBCC" report "TEST13: tag[31:0] readback mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 14: Tag captured from datapath after enc done (mode=0)
        -----------------------------------------------------------------------
        -- Confirm enc mode (was set back to 0 in Test 5)
        assert csr_mode = '0' report "TEST14: mode should be enc(0)" severity failure;

        tag_computed_in <= x"CAFEBABE0011223344556677DEADBEEF";
        csr_done <= '1';
        wait for CLK_PERIOD;
        csr_done <= '0';
        wait for CLK_PERIOD;

        assert tag_reg_out = x"CAFEBABE0011223344556677DEADBEEF"
            report "TEST14: tag_reg_out should match tag_computed_in after enc done"
            severity failure;

        axi_read(x"048", rd_val, rd_resp);
        assert rd_val = x"CAFEBABE" report "TEST14: tag[127:96] AXI readback mismatch" severity failure;

        axi_read(x"054", rd_val, rd_resp);
        assert rd_val = x"DEADBEEF" report "TEST14: tag[31:0] AXI readback mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 15: Soft reset clears all registers
        -----------------------------------------------------------------------
        assert key_reg /= (255 downto 0 => '0')
            report "TEST15: pre-condition: key_reg should be non-zero" severity failure;

        axi_write(x"058", x"00000002");   -- SOFT_RESET bit[1]
        wait for 2 * CLK_PERIOD;

        assert key_reg = (255 downto 0 => '0') report "TEST15: key_reg not cleared by soft reset" severity failure;
        assert iv_reg = (95 downto 0 => '0') report "TEST15: iv_reg not cleared by soft reset" severity failure;
        assert aad_addr_reg = (31 downto 0 => '0') report "TEST15: aad_addr_reg not cleared by soft reset" severity failure;
        assert aad_len_reg = (31 downto 0 => '0') report "TEST15: aad_len_reg not cleared by soft reset" severity failure;
        assert pt_addr_reg = (31 downto 0 => '0') report "TEST15: pt_addr_reg not cleared by soft reset" severity failure;
        assert pt_len_reg = (31 downto 0 => '0') report "TEST15: pt_len_reg not cleared by soft reset" severity failure;
        assert ct_addr_reg = (31 downto 0 => '0') report "TEST15: ct_addr_reg not cleared by soft reset" severity failure;
        assert tag_reg_out = (127 downto 0 => '0') report "TEST15: tag_reg_out not cleared by soft reset" severity failure;
        assert csr_mode = '0' report "TEST15: csr_mode not cleared by soft reset" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 16: AW-first channel ordering (WR_IDLE -> WR_HAVE_ADDR -> WR_BOTH)
        -----------------------------------------------------------------------
        axi_write_aw_first(x"028", x"DEADC0DE");
        assert iv_reg(31 downto 0) = x"DEADC0DE"
            report "TEST16: iv word 2 (AW-first) mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 17: W-first channel ordering (WR_IDLE -> WR_HAVE_DATA -> WR_BOTH)
        -----------------------------------------------------------------------
        axi_write_w_first(x"024", x"C0FFEE00");
        assert iv_reg(63 downto 32) = x"C0FFEE00"
            report "TEST17: iv word 1 (W-first) mismatch" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 18: Write-only registers read back zero
        -----------------------------------------------------------------------
        -- Write a non-zero value, then confirm the read returns 0
        axi_write(x"020", x"12345678");

        axi_read(x"020", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST18: iv[0] read RRESP not OKAY" severity failure;
        assert rd_val = x"00000000" report "TEST18: iv[0] should read as 0 (WO)" severity failure;

        axi_read(x"000", rd_val, rd_resp);
        assert rd_resp = "00" report "TEST18: key[0] read RRESP not OKAY" severity failure;
        assert rd_val = x"00000000" report "TEST18: key[0] should read as 0 (WO)" severity failure;

        axi_read(x"030", rd_val, rd_resp);
        assert rd_val = x"00000000" report "TEST18: aad_addr should read as 0 (WO)" severity failure;

        axi_read(x"038", rd_val, rd_resp);
        assert rd_val = x"00000000" report "TEST18: pt_addr should read as 0 (WO)" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        -- Test 19: Write to CT_LEN (0x044, read-only) is silently ignored -- OKAY resp
        -----------------------------------------------------------------------
        axi_write(x"044", x"FFFFFFFF");
        assert bresp = "00" report "TEST19: BRESP for CT_LEN write should be OKAY (not DECERR)" severity failure;

        axi_read(x"044", rd_val, rd_resp);
        assert rd_val = x"000000C0" report "TEST19: CT_LEN should be unchanged after write" severity failure;

        -- Same for debug register (0x05C)
        axi_write(x"05C", x"FFFFFFFF");
        assert bresp = "00" report "TEST19: BRESP for debug write should be OKAY" severity failure;

        wait for 2 * CLK_PERIOD;

        -----------------------------------------------------------------------
        report "AXI SLAVE: ALL TESTS PASSED" severity note;
        std.env.stop;
    end process p_stim;

end architecture sim;
