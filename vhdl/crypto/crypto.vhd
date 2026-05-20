-- Top-level crypto entity — Milestone 5
-- Wires together: axi_slave (M3), dma_engine (M4), and the pre-existing
-- GCM datapath (cast256 cipher + GHASH + CTR + FSM) from Milestones 1-2.
-- Entity declaration is fixed per README — do NOT modify the port list.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity crypto is
    port (
        aclk             : in  std_ulogic;
        aresetn          : in  std_ulogic;

        -- AXI4-Lite slave (control plane, from PS M_AXI_GP0)
        s0_axi_awaddr    : in  std_ulogic_vector(11 downto 0);
        s0_axi_awvalid   : in  std_ulogic;
        s0_axi_awready   : out std_ulogic;
        s0_axi_wdata     : in  std_ulogic_vector(31 downto 0);
        s0_axi_wstrb     : in  std_ulogic_vector( 3 downto 0);
        s0_axi_wvalid    : in  std_ulogic;
        s0_axi_wready    : out std_ulogic;
        s0_axi_bresp     : out std_ulogic_vector( 1 downto 0);
        s0_axi_bvalid    : out std_ulogic;
        s0_axi_bready    : in  std_ulogic;
        s0_axi_araddr    : in  std_ulogic_vector(11 downto 0);
        s0_axi_arvalid   : in  std_ulogic;
        s0_axi_arready   : out std_ulogic;
        s0_axi_rdata     : out std_ulogic_vector(31 downto 0);
        s0_axi_rresp     : out std_ulogic_vector( 1 downto 0);
        s0_axi_rvalid    : out std_ulogic;
        s0_axi_rready    : in  std_ulogic;

        -- AXI4-Lite master (DMA, to PS S_AXI_HP0)
        m0_axi_araddr    : out std_ulogic_vector(29 downto 0);
        m0_axi_arvalid   : out std_ulogic;
        m0_axi_arready   : in  std_ulogic;
        m0_axi_rdata     : in  std_ulogic_vector(31 downto 0);
        m0_axi_rresp     : in  std_ulogic_vector( 1 downto 0);
        m0_axi_rvalid    : in  std_ulogic;
        m0_axi_rready    : out std_ulogic;
        m0_axi_awaddr    : out std_ulogic_vector(29 downto 0);
        m0_axi_awvalid   : out std_ulogic;
        m0_axi_awready   : in  std_ulogic;
        m0_axi_wdata     : out std_ulogic_vector(31 downto 0);
        m0_axi_wstrb     : out std_ulogic_vector( 3 downto 0);
        m0_axi_wvalid    : out std_ulogic;
        m0_axi_wready    : in  std_ulogic;
        m0_axi_bresp     : in  std_ulogic_vector( 1 downto 0);
        m0_axi_bvalid    : in  std_ulogic;
        m0_axi_bready    : out std_ulogic;

        -- Debug/IO
        sw               : in  std_ulogic_vector( 3 downto 0);
        btn              : in  std_ulogic_vector( 3 downto 0);
        led              : out std_ulogic_vector( 3 downto 0);
        irq              : out std_ulogic
    );
end entity crypto;

architecture rtl of crypto is

    ---------------------------------------------------------------------------
    -- Component declarations (implemented in Milestones 1-2 and 3-4)
    ---------------------------------------------------------------------------

    component cast256 is
        port (
            aclk          : in  std_ulogic;
            aresetn       : in  std_ulogic;
            key           : in  std_ulogic_vector(255 downto 0);
            key_valid     : in  std_ulogic;
            key_ready     : out std_ulogic;
            plaintext     : in  std_ulogic_vector(127 downto 0);
            encrypt_start : in  std_ulogic;
            ciphertext    : out std_ulogic_vector(127 downto 0);
            enc_done      : out std_ulogic
        );
    end component cast256;

    component ghash_engine is
        port (
            aclk         : in  std_ulogic;
            aresetn      : in  std_ulogic;
            H_in         : in  std_ulogic_vector(127 downto 0);
            block_in     : in  std_ulogic_vector(127 downto 0);
            block_valid  : in  std_ulogic;
            flush_len    : in  std_ulogic;
            aad_len_bits : in  std_ulogic_vector(63 downto 0);
            ct_len_bits  : in  std_ulogic_vector(63 downto 0);
            accum_out    : out std_ulogic_vector(127 downto 0);
            done         : out std_ulogic;
            reset_accum  : in  std_ulogic
        );
    end component ghash_engine;

    component axi_slave is
        port (
            aclk             : in  std_ulogic;
            aresetn          : in  std_ulogic;
            s0_axi_awaddr    : in  std_ulogic_vector(11 downto 0);
            s0_axi_awvalid   : in  std_ulogic;
            s0_axi_awready   : out std_ulogic;
            s0_axi_wdata     : in  std_ulogic_vector(31 downto 0);
            s0_axi_wstrb     : in  std_ulogic_vector( 3 downto 0);
            s0_axi_wvalid    : in  std_ulogic;
            s0_axi_wready    : out std_ulogic;
            s0_axi_bresp     : out std_ulogic_vector( 1 downto 0);
            s0_axi_bvalid    : out std_ulogic;
            s0_axi_bready    : in  std_ulogic;
            s0_axi_araddr    : in  std_ulogic_vector(11 downto 0);
            s0_axi_arvalid   : in  std_ulogic;
            s0_axi_arready   : out std_ulogic;
            s0_axi_rdata     : out std_ulogic_vector(31 downto 0);
            s0_axi_rresp     : out std_ulogic_vector( 1 downto 0);
            s0_axi_rvalid    : out std_ulogic;
            s0_axi_rready    : in  std_ulogic;
            key_reg          : out std_ulogic_vector(255 downto 0);
            iv_reg           : out std_ulogic_vector( 95 downto 0);
            aad_addr_reg     : out std_ulogic_vector(31 downto 0);
            aad_len_reg      : out std_ulogic_vector(31 downto 0);
            pt_addr_reg      : out std_ulogic_vector(31 downto 0);
            pt_len_reg       : out std_ulogic_vector(31 downto 0);
            ct_addr_reg      : out std_ulogic_vector(31 downto 0);
            tag_reg_out      : out std_ulogic_vector(127 downto 0);
            csr_start        : out std_ulogic;
            csr_soft_reset   : out std_ulogic;
            csr_mode         : out std_ulogic;
            ct_len_in        : in  std_ulogic_vector(31 downto 0);
            tag_computed_in  : in  std_ulogic_vector(127 downto 0);
            csr_busy         : in  std_ulogic;
            csr_done         : in  std_ulogic;
            csr_tag_valid    : in  std_ulogic;
            csr_error        : in  std_ulogic;
            fsm_state_in     : in  std_ulogic_vector( 3 downto 0);
            key_loaded_pulse : out std_ulogic
        );
    end component axi_slave;

    component dma_engine is
        port (
            aclk               : in  std_ulogic;
            aresetn            : in  std_ulogic;
            m0_axi_araddr      : out std_ulogic_vector(29 downto 0);
            m0_axi_arvalid     : out std_ulogic;
            m0_axi_arready     : in  std_ulogic;
            m0_axi_rdata       : in  std_ulogic_vector(31 downto 0);
            m0_axi_rresp       : in  std_ulogic_vector( 1 downto 0);
            m0_axi_rvalid      : in  std_ulogic;
            m0_axi_rready      : out std_ulogic;
            m0_axi_awaddr      : out std_ulogic_vector(29 downto 0);
            m0_axi_awvalid     : out std_ulogic;
            m0_axi_awready     : in  std_ulogic;
            m0_axi_wdata       : out std_ulogic_vector(31 downto 0);
            m0_axi_wstrb       : out std_ulogic_vector( 3 downto 0);
            m0_axi_wvalid      : out std_ulogic;
            m0_axi_wready      : in  std_ulogic;
            m0_axi_bresp       : in  std_ulogic_vector( 1 downto 0);
            m0_axi_bvalid      : in  std_ulogic;
            m0_axi_bready      : out std_ulogic;
            rd_start           : in  std_ulogic;
            rd_base_addr       : in  std_ulogic_vector(31 downto 0);
            rd_block_count     : in  std_ulogic_vector(23 downto 0);
            wr_start           : in  std_ulogic;
            wr_base_addr       : in  std_ulogic_vector(31 downto 0);
            wr_block_count     : in  std_ulogic_vector(23 downto 0);
            rd_block_data      : out std_ulogic_vector(127 downto 0);
            rd_block_valid     : out std_ulogic;
            rd_block_consumed  : in  std_ulogic;
            wr_block_data      : in  std_ulogic_vector(127 downto 0);
            wr_block_valid     : in  std_ulogic;
            wr_block_accepted  : out std_ulogic;
            rd_done            : out std_ulogic;
            wr_done            : out std_ulogic;
            dma_error          : out std_ulogic
        );
    end component dma_engine;

    ---------------------------------------------------------------------------
    -- Internal signals — register bank from AXI slave
    ---------------------------------------------------------------------------
    signal key_reg        : std_ulogic_vector(255 downto 0);
    signal iv_reg         : std_ulogic_vector( 95 downto 0);
    signal aad_addr_reg   : std_ulogic_vector(31 downto 0);
    signal aad_len_reg    : std_ulogic_vector(31 downto 0);
    signal pt_addr_reg    : std_ulogic_vector(31 downto 0);
    signal pt_len_reg     : std_ulogic_vector(31 downto 0);
    signal ct_addr_reg    : std_ulogic_vector(31 downto 0);
    signal tag_expected   : std_ulogic_vector(127 downto 0);  -- from SW (decrypt)
    signal csr_start      : std_ulogic;
    signal csr_soft_reset : std_ulogic;
    signal csr_mode       : std_ulogic;
    signal key_loaded     : std_ulogic;

    -- Status back to AXI slave
    signal ct_len_out     : std_ulogic_vector(31 downto 0)  := (others => '0');
    signal tag_computed   : std_ulogic_vector(127 downto 0) := (others => '0');
    signal csr_busy       : std_ulogic := '0';
    signal csr_done       : std_ulogic := '0';
    signal csr_tag_valid  : std_ulogic := '0';
    signal csr_error      : std_ulogic := '0';

    ---------------------------------------------------------------------------
    -- GCM top-level FSM
    ---------------------------------------------------------------------------
    type gcm_state_t is (
        GCM_IDLE,
        GCM_KEY_SCHED,    -- key_valid pulsed; waiting for key_ready
        GCM_COMPUTE_H,    -- BC(K, 0) for hash subkey: encrypt_start → enc_done
        GCM_PROCESS_AAD,  -- DMA read AAD, feed to GHASH
        GCM_ENCRYPT,      -- DMA read PT, CTR encrypt, GHASH CT, DMA write CT
        GCM_GEN_TAG,      -- BC(K, J0) XOR GHASH output → tag
        GCM_DONE,
        GCM_ERROR,
        GCM_SOFT_RESET
    );
    signal gcm_state  : gcm_state_t := GCM_IDLE;
    signal fsm_state  : std_ulogic_vector(3 downto 0);

    -- J0 = IV || 0x00000001  (combinatorial)
    signal J0_reg     : std_ulogic_vector(127 downto 0);

    -- H register (stored after BC(K,0) completes)
    signal H_reg      : std_ulogic_vector(127 downto 0) := (others => '0');

    -- CTR counter: starts at inc32(J0) = IV || 0x00000002
    signal ctr_block  : std_ulogic_vector(127 downto 0) := (others => '0');

    -- Block cipher mux
    type mux_sel_t is (MUX_H_COMPUTE, MUX_CTR, MUX_TAG_GEN);
    signal cipher_mux       : mux_sel_t := MUX_H_COMPUTE;
    signal cipher_din       : std_ulogic_vector(127 downto 0);
    signal cipher_dout      : std_ulogic_vector(127 downto 0);
    signal cipher_valid     : std_ulogic;
    signal cipher_start     : std_ulogic := '0';  -- encrypt_start
    signal cipher_key_valid : std_ulogic := '0';  -- key_valid (triggers key schedule)
    signal cipher_key_ready : std_ulogic;          -- key_ready (key schedule done)
    signal cipher_busy      : std_ulogic := '0';  -- set between encrypt_start and enc_done

    -- DMA control
    signal rd_start        : std_ulogic := '0';
    signal rd_base         : std_ulogic_vector(31 downto 0) := (others => '0');
    signal rd_block_count  : std_ulogic_vector(23 downto 0) := (others => '0');
    signal wr_start        : std_ulogic := '0';
    signal wr_base         : std_ulogic_vector(31 downto 0) := (others => '0');
    signal wr_block_count  : std_ulogic_vector(23 downto 0) := (others => '0');
    signal rd_block_data   : std_ulogic_vector(127 downto 0);
    signal rd_block_valid  : std_ulogic;
    signal rd_block_consumed : std_ulogic := '0';
    signal wr_block_data   : std_ulogic_vector(127 downto 0) := (others => '0');
    signal wr_block_valid  : std_ulogic := '0';
    signal wr_block_accepted : std_ulogic;
    signal rd_done         : std_ulogic;
    signal wr_done         : std_ulogic;
    signal dma_error       : std_ulogic;

    -- GHASH control
    signal ghash_block_in    : std_ulogic_vector(127 downto 0) := (others => '0');
    signal ghash_block_valid : std_ulogic := '0';
    signal ghash_flush_len   : std_ulogic := '0';
    signal ghash_accum       : std_ulogic_vector(127 downto 0);
    signal ghash_done        : std_ulogic;
    signal ghash_reset       : std_ulogic := '0';

    -- Length tracking for GHASH length block
    signal aad_len_bits : std_ulogic_vector(63 downto 0) := (others => '0');
    signal ct_len_bits  : std_ulogic_vector(63 downto 0) := (others => '0');

    -- Ciphertext block from CTR: DIN XOR BC(K, counter)
    signal pt_block_buf   : std_ulogic_vector(127 downto 0) := (others => '0');
    signal ct_block_out   : std_ulogic_vector(127 downto 0);

    -- IRQ
    signal irq_i        : std_ulogic := '0';
    signal prev_done    : std_ulogic := '0';
    signal prev_error   : std_ulogic := '0';

begin

    ---------------------------------------------------------------------------
    -- J0 combinatorial: IV || 0x00000001
    ---------------------------------------------------------------------------
    J0_reg <= iv_reg & x"00000001";

    ---------------------------------------------------------------------------
    -- Block cipher input mux
    ---------------------------------------------------------------------------
    with cipher_mux select cipher_din <=
        (others => '0') when MUX_H_COMPUTE,
        ctr_block       when MUX_CTR,
        J0_reg          when MUX_TAG_GEN,
        (others => '0') when others;

    ---------------------------------------------------------------------------
    -- Ciphertext block: PT XOR keystream
    ---------------------------------------------------------------------------
    ct_block_out <= pt_block_buf xor cipher_dout;

    ---------------------------------------------------------------------------
    -- FSM state encoding for debug register
    ---------------------------------------------------------------------------
    with gcm_state select fsm_state <=
        "0000" when GCM_IDLE,
        "0001" when GCM_KEY_SCHED,
        "0010" when GCM_COMPUTE_H,
        "0011" when GCM_PROCESS_AAD,
        "0100" when GCM_ENCRYPT,
        "0101" when GCM_GEN_TAG,
        "0110" when GCM_DONE,
        "0111" when GCM_ERROR,
        "1000" when GCM_SOFT_RESET,
        "1111" when others;

    ---------------------------------------------------------------------------
    -- CSR status bits
    ---------------------------------------------------------------------------
    csr_busy <= '1' when gcm_state /= GCM_IDLE and gcm_state /= GCM_DONE
                         and gcm_state /= GCM_ERROR else '0';

    ---------------------------------------------------------------------------
    -- LED mapping (§5.4)
    ---------------------------------------------------------------------------
    led(0) <= csr_busy;
    led(1) <= csr_done;
    led(2) <= csr_error;
    led(3) <= csr_tag_valid;

    ---------------------------------------------------------------------------
    -- IRQ: pulse for 1 cycle on DONE or ERROR rising edge (§3.6)
    -- sw(0) gates IRQ for polling-vs-interrupt testing
    ---------------------------------------------------------------------------
    irq <= irq_i and not sw(0);

    ---------------------------------------------------------------------------
    -- AXI slave instantiation
    ---------------------------------------------------------------------------
    u_slave : axi_slave
        port map (
            aclk             => aclk,
            aresetn          => aresetn,
            s0_axi_awaddr    => s0_axi_awaddr,
            s0_axi_awvalid   => s0_axi_awvalid,
            s0_axi_awready   => s0_axi_awready,
            s0_axi_wdata     => s0_axi_wdata,
            s0_axi_wstrb     => s0_axi_wstrb,
            s0_axi_wvalid    => s0_axi_wvalid,
            s0_axi_wready    => s0_axi_wready,
            s0_axi_bresp     => s0_axi_bresp,
            s0_axi_bvalid    => s0_axi_bvalid,
            s0_axi_bready    => s0_axi_bready,
            s0_axi_araddr    => s0_axi_araddr,
            s0_axi_arvalid   => s0_axi_arvalid,
            s0_axi_arready   => s0_axi_arready,
            s0_axi_rdata     => s0_axi_rdata,
            s0_axi_rresp     => s0_axi_rresp,
            s0_axi_rvalid    => s0_axi_rvalid,
            s0_axi_rready    => s0_axi_rready,
            key_reg          => key_reg,
            iv_reg           => iv_reg,
            aad_addr_reg     => aad_addr_reg,
            aad_len_reg      => aad_len_reg,
            pt_addr_reg      => pt_addr_reg,
            pt_len_reg       => pt_len_reg,
            ct_addr_reg      => ct_addr_reg,
            tag_reg_out      => tag_expected,
            csr_start        => csr_start,
            csr_soft_reset   => csr_soft_reset,
            csr_mode         => csr_mode,
            ct_len_in        => ct_len_out,
            tag_computed_in  => tag_computed,
            csr_busy         => csr_busy,
            csr_done         => csr_done,
            csr_tag_valid    => csr_tag_valid,
            csr_error        => csr_error,
            fsm_state_in     => fsm_state,
            key_loaded_pulse => key_loaded
        );

    ---------------------------------------------------------------------------
    -- DMA engine instantiation
    ---------------------------------------------------------------------------
    u_dma : dma_engine
        port map (
            aclk              => aclk,
            aresetn           => aresetn,
            m0_axi_araddr     => m0_axi_araddr,
            m0_axi_arvalid    => m0_axi_arvalid,
            m0_axi_arready    => m0_axi_arready,
            m0_axi_rdata      => m0_axi_rdata,
            m0_axi_rresp      => m0_axi_rresp,
            m0_axi_rvalid     => m0_axi_rvalid,
            m0_axi_rready     => m0_axi_rready,
            m0_axi_awaddr     => m0_axi_awaddr,
            m0_axi_awvalid    => m0_axi_awvalid,
            m0_axi_awready    => m0_axi_awready,
            m0_axi_wdata      => m0_axi_wdata,
            m0_axi_wstrb      => m0_axi_wstrb,
            m0_axi_wvalid     => m0_axi_wvalid,
            m0_axi_wready     => m0_axi_wready,
            m0_axi_bresp      => m0_axi_bresp,
            m0_axi_bvalid     => m0_axi_bvalid,
            m0_axi_bready     => m0_axi_bready,
            rd_start          => rd_start,
            rd_base_addr      => rd_base,
            rd_block_count    => rd_block_count,
            wr_start          => wr_start,
            wr_base_addr      => wr_base,
            wr_block_count    => wr_block_count,
            rd_block_data     => rd_block_data,
            rd_block_valid    => rd_block_valid,
            rd_block_consumed => rd_block_consumed,
            wr_block_data     => wr_block_data,
            wr_block_valid    => wr_block_valid,
            wr_block_accepted => wr_block_accepted,
            rd_done           => rd_done,
            wr_done           => wr_done,
            dma_error         => dma_error
        );

    ---------------------------------------------------------------------------
    -- Block cipher instantiation (CAST-256, from Milestone 1)
    ---------------------------------------------------------------------------
    u_cipher : cast256
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            key           => key_reg,
            key_valid     => cipher_key_valid,
            key_ready     => cipher_key_ready,
            plaintext     => cipher_din,
            encrypt_start => cipher_start,
            ciphertext    => cipher_dout,
            enc_done      => cipher_valid
        );

    ---------------------------------------------------------------------------
    -- GHASH engine instantiation (from Milestone 2)
    ---------------------------------------------------------------------------
    u_ghash : ghash_engine
        port map (
            aclk         => aclk,
            aresetn      => aresetn,
            H_in         => H_reg,
            block_in     => ghash_block_in,
            block_valid  => ghash_block_valid,
            flush_len    => ghash_flush_len,
            aad_len_bits => aad_len_bits,
            ct_len_bits  => ct_len_bits,
            accum_out    => ghash_accum,
            done         => ghash_done,
            reset_accum  => ghash_reset
        );

    ---------------------------------------------------------------------------
    -- GCM top-level FSM
    ---------------------------------------------------------------------------
    p_gcm_fsm : process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                gcm_state        <= GCM_IDLE;
                csr_done         <= '0';
                csr_tag_valid    <= '0';
                csr_error        <= '0';
                H_reg            <= (others => '0');
                ctr_block        <= (others => '0');
                cipher_start     <= '0';
                cipher_key_valid <= '0';
                cipher_busy      <= '0';
                cipher_mux       <= MUX_H_COMPUTE;
                rd_start         <= '0';
                wr_start         <= '0';
                rd_block_consumed <= '0';
                wr_block_valid   <= '0';
                ghash_block_valid <= '0';
                ghash_flush_len  <= '0';
                ghash_reset      <= '0';
                irq_i            <= '0';
                prev_done        <= '0';
                prev_error       <= '0';
                ct_len_out       <= (others => '0');
                tag_computed     <= (others => '0');
                aad_len_bits     <= (others => '0');
                ct_len_bits      <= (others => '0');
            else
                -- Default pulse signals
                cipher_start      <= '0';
                cipher_key_valid  <= '0';
                rd_start          <= '0';
                wr_start          <= '0';
                rd_block_consumed <= '0';
                wr_block_valid    <= '0';
                ghash_block_valid <= '0';
                ghash_flush_len   <= '0';
                ghash_reset       <= '0';
                irq_i             <= '0';

                -- Track cipher busy
                if cipher_start = '1' then
                    cipher_busy <= '1';
                elsif cipher_valid = '1' then
                    cipher_busy <= '0';
                end if;

                -- IRQ: pulse on DONE or ERROR transition
                prev_done  <= csr_done;
                prev_error <= csr_error;
                if (csr_done = '1' and prev_done = '0') or
                   (csr_error = '1' and prev_error = '0') then
                    irq_i <= '1';
                end if;

                case gcm_state is

                    when GCM_IDLE =>
                        -- key_loaded pulse: run key schedule then compute H = BC(K, 0)
                        if key_loaded = '1' then
                            cipher_key_valid <= '1';
                            gcm_state        <= GCM_KEY_SCHED;
                        end if;

                        if csr_start = '1' then
                            csr_done      <= '0';
                            csr_tag_valid <= '0';
                            csr_error     <= '0';
                            ghash_reset   <= '1';
                            aad_len_bits  <= std_ulogic_vector(
                                unsigned(aad_len_reg) & "000");  -- bytes→bits
                            ct_len_bits   <= std_ulogic_vector(
                                unsigned(pt_len_reg)  & "000");
                            ct_len_out    <= pt_len_reg;

                            -- Start AAD DMA phase
                            rd_base        <= aad_addr_reg;
                            rd_block_count <= aad_len_reg(27 downto 4);  -- byte_len / 16
                            rd_start       <= '1';
                            -- Init CTR at inc32(J0) = IV || 0x00000002
                            ctr_block     <= iv_reg & x"00000002";
                            gcm_state     <= GCM_PROCESS_AAD;
                        end if;

                        if csr_soft_reset = '1' then
                            csr_done      <= '0';
                            csr_tag_valid <= '0';
                            csr_error     <= '0';
                            gcm_state     <= GCM_IDLE;
                        end if;

                    when GCM_KEY_SCHED =>
                        -- Wait for the key schedule to complete (~396 cycles)
                        if cipher_key_ready = '1' then
                            cipher_mux   <= MUX_H_COMPUTE;
                            cipher_start <= '1';
                            gcm_state    <= GCM_COMPUTE_H;
                        end if;

                    when GCM_COMPUTE_H =>
                        if cipher_valid = '1' then
                            H_reg     <= cipher_dout;
                            gcm_state <= GCM_IDLE;
                        end if;

                    when GCM_PROCESS_AAD =>
                        if dma_error = '1' then
                            csr_error <= '1';
                            gcm_state <= GCM_ERROR;
                        elsif rd_block_valid = '1' then
                            -- Feed AAD block to GHASH
                            ghash_block_in    <= rd_block_data;
                            ghash_block_valid <= '1';
                            rd_block_consumed <= '1';
                            -- Stay until rd_done
                        elsif rd_done = '1' then
                            -- All AAD processed; start encrypt phase
                            rd_base        <= pt_addr_reg;
                            rd_block_count <= pt_len_reg(27 downto 4);   -- byte_len / 16
                            rd_start       <= '1';
                            wr_base        <= ct_addr_reg;
                            wr_block_count <= pt_len_reg(27 downto 4);   -- byte_len / 16
                            wr_start       <= '1';
                            gcm_state      <= GCM_ENCRYPT;
                        end if;
                        if csr_soft_reset = '1' then
                            gcm_state <= GCM_SOFT_RESET;
                        end if;

                    when GCM_ENCRYPT =>
                        if dma_error = '1' then
                            csr_error <= '1';
                            gcm_state <= GCM_ERROR;

                        elsif rd_block_valid = '1' and cipher_busy = '0' then
                            -- Latch plaintext block and launch CTR keystream
                            pt_block_buf      <= rd_block_data;
                            rd_block_consumed <= '1';
                            cipher_mux        <= MUX_CTR;
                            cipher_start      <= '1';

                        elsif cipher_valid = '1' then
                            -- Ciphertext ready: feed to GHASH and write engine
                            ghash_block_in    <= ct_block_out;
                            ghash_block_valid <= '1';
                            wr_block_data     <= ct_block_out;
                            wr_block_valid    <= '1';
                            -- Increment counter (inc32)
                            ctr_block(31 downto 0) <= std_ulogic_vector(
                                unsigned(ctr_block(31 downto 0)) + 1);
                        end if;

                        if wr_done = '1' then
                            -- All blocks written; compute tag
                            -- First flush length block to GHASH
                            ghash_flush_len <= '1';
                            gcm_state       <= GCM_GEN_TAG;
                        end if;
                        if csr_soft_reset = '1' then
                            gcm_state <= GCM_SOFT_RESET;
                        end if;

                    when GCM_GEN_TAG =>
                        -- Wait for GHASH to finish the length block, then compute T = BC(K, J0) XOR S
                        if ghash_done = '1' and cipher_busy = '0' then
                            cipher_mux   <= MUX_TAG_GEN;
                            cipher_start <= '1';
                        elsif cipher_valid = '1' then
                            -- T = BC(K, J0) XOR GHASH_accum
                            tag_computed <= cipher_dout xor ghash_accum;
                            if csr_mode = '1' then
                                -- Decrypt: compare computed tag with expected
                                if (cipher_dout xor ghash_accum) = tag_expected then
                                    csr_tag_valid <= '1';
                                else
                                    csr_error <= '1';
                                end if;
                            end if;
                            csr_done  <= '1';
                            gcm_state <= GCM_DONE;
                        end if;
                        if csr_soft_reset = '1' then
                            gcm_state <= GCM_SOFT_RESET;
                        end if;

                    when GCM_DONE =>
                        if csr_soft_reset = '1' then
                            csr_done      <= '0';
                            csr_tag_valid <= '0';
                            gcm_state     <= GCM_IDLE;
                        elsif csr_start = '1' then
                            -- New operation
                            csr_done      <= '0';
                            csr_tag_valid <= '0';
                            gcm_state     <= GCM_IDLE;
                        end if;

                    when GCM_ERROR =>
                        if csr_soft_reset = '1' then
                            csr_error <= '0';
                            gcm_state <= GCM_IDLE;
                        end if;

                    when GCM_SOFT_RESET =>
                        csr_done      <= '0';
                        csr_tag_valid <= '0';
                        csr_error     <= '0';
                        cipher_busy   <= '0';
                        gcm_state     <= GCM_IDLE;

                    when others =>
                        gcm_state <= GCM_IDLE;
                end case;
            end if;
        end if;
    end process p_gcm_fsm;

end architecture rtl;
