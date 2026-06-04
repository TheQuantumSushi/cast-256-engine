-- ┌──────────────────────────────────────────────────────────────────┐
-- │ crypto — top-level integration                                   │
-- │                                                                  │
-- │ Instantiates:                                                    │
-- │   u_slave : axi_slave  — AXI4-Lite control plane (12-bit addr) │
-- │   u_dma   : dma_engine — AXI4-Lite DMA master (30-bit, 1 GB)   │
-- │   u_gcm   : gcm        — GCM+CAST-256 engine                   │
-- │                                                                  │
-- │ p_dma_adapter bridges the per-block request model of gcm.vhd   │
-- │ to the burst model of dma_engine.                               │
-- │                                                                  │
-- │ Address width: axi_slave outputs 32-bit; gcm ports are 30-bit.  │
-- │ Bits [31:30] are truncated at the port map; axi_slave rejects   │
-- │ writes with those bits set (SLVERR).                            │
-- └──────────────────────────────────────────────────────────────────┘

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

        -- Debug / IO
        sw               : in  std_ulogic_vector( 3 downto 0);
        btn              : in  std_ulogic_vector( 3 downto 0);
        led              : out std_ulogic_vector( 3 downto 0);
        irq              : out std_ulogic
    );
end entity crypto;

architecture rtl of crypto is

    ---------------------------------------------------------------------------
    -- Component: gcm (authoritative GCM+cipher implementation)
    -- Entity defined in vhdl/crypto/gcm/gcm.vhd (Milestones 1+2).
    -- Internally instantiates cast256 and ghash.
    ---------------------------------------------------------------------------
    component gcm is
        port (
            aclk           : in  std_ulogic;
            aresetn        : in  std_ulogic;
            -- Control inputs (from axi_slave register bank)
            mode_i         : in  std_ulogic;                      -- 0=encrypt 1=decrypt
            key_i          : in  std_ulogic_vector(255 downto 0);
            iv_i           : in  std_ulogic_vector( 95 downto 0);
            aad_addr_i     : in  std_ulogic_vector( 29 downto 0); -- byte address (1 GB space)
            aad_len_i      : in  std_ulogic_vector( 29 downto 0); -- byte length, multiple of 16
            pt_addr_i      : in  std_ulogic_vector( 29 downto 0);
            pt_len_i       : in  std_ulogic_vector( 29 downto 0);
            ct_addr_i      : in  std_ulogic_vector( 29 downto 0);
            tag_i          : in  std_ulogic_vector(127 downto 0); -- expected tag (decrypt)
            start_i        : in  std_ulogic;                      -- single-cycle start pulse
            -- Status outputs
            tag_o          : out std_ulogic_vector(127 downto 0); -- computed tag
            done_o         : out std_ulogic;                      -- single-cycle done pulse
            auth_fail_o    : out std_ulogic;                      -- tag mismatch (decrypt)
            -- DMA read interface (per-block request model — Step 3 bridges to dma_engine)
            dma_rd_addr_o  : out std_ulogic_vector( 29 downto 0);
            dma_rd_req_o   : out std_ulogic;
            dma_rd_data_i  : in  std_ulogic_vector(127 downto 0);
            dma_rd_valid_i : in  std_ulogic;
            -- DMA write interface (per-block request model — Step 3 bridges to dma_engine)
            dma_wr_addr_o  : out std_ulogic_vector( 29 downto 0);
            dma_wr_data_o  : out std_ulogic_vector(127 downto 0);
            dma_wr_req_o   : out std_ulogic;
            dma_wr_done_i  : in  std_ulogic
        );
    end component gcm;

    ---------------------------------------------------------------------------
    -- Component: axi_slave (Milestone 3)
    -- Entity defined in vhdl/crypto/axi_slave/axi_slave.vhd.
    ---------------------------------------------------------------------------
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

    ---------------------------------------------------------------------------
    -- Component: dma_engine (Milestone 4)
    -- Entity defined in vhdl/crypto/dma/dma_engine.vhd.
    ---------------------------------------------------------------------------
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
    -- AXI slave register outputs
    ---------------------------------------------------------------------------
    signal key_reg        : std_ulogic_vector(255 downto 0);
    signal iv_reg         : std_ulogic_vector( 95 downto 0);
    signal aad_addr_reg   : std_ulogic_vector(31 downto 0);
    signal aad_len_reg    : std_ulogic_vector(31 downto 0);
    signal pt_addr_reg    : std_ulogic_vector(31 downto 0);
    signal pt_len_reg     : std_ulogic_vector(31 downto 0);
    signal ct_addr_reg    : std_ulogic_vector(31 downto 0);
    signal tag_expected   : std_ulogic_vector(127 downto 0);
    signal csr_start      : std_ulogic;
    signal csr_soft_reset : std_ulogic;
    signal csr_mode       : std_ulogic;
    -- key_loaded_pulse from axi_slave is unused by gcm.vhd (key schedule
    -- runs on every start_i).  Kept wired to silence undriven-output warnings.
    signal key_loaded     : std_ulogic;

    ---------------------------------------------------------------------------
    -- Status signals: crypto top-level → axi_slave
    ---------------------------------------------------------------------------
    signal csr_busy       : std_ulogic := '0';
    signal csr_done       : std_ulogic := '0';
    signal csr_tag_valid  : std_ulogic := '0';
    signal csr_error      : std_ulogic := '0';
    -- GCM is a stream cipher; CT length equals PT length.
    signal ct_len_out     : std_ulogic_vector(31 downto 0);
    signal tag_computed   : std_ulogic_vector(127 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- GCM engine wires
    ---------------------------------------------------------------------------
    signal gcm_tag       : std_ulogic_vector(127 downto 0);
    signal gcm_done      : std_ulogic;
    signal gcm_auth_fail : std_ulogic;

    ---------------------------------------------------------------------------
    -- GCM ↔ DMA adapter signals
    --
    -- gcm.vhd uses a per-block request model: one {req, addr} pulse per
    -- 128-bit block, expects one {data, valid} or {done} response.
    -- dma_engine uses a burst model: {start, base, count} then streaming
    -- blocks.  p_dma_adapter translates between the two.
    ---------------------------------------------------------------------------
    signal dma_rd_addr    : std_ulogic_vector(29 downto 0);   -- gcm → adapter
    signal dma_rd_req     : std_ulogic;                        -- gcm → adapter
    signal dma_rd_data    : std_ulogic_vector(127 downto 0);   -- adapter → gcm
    signal dma_rd_valid   : std_ulogic;                        -- adapter → gcm

    signal dma_wr_addr    : std_ulogic_vector(29 downto 0);   -- gcm → adapter
    signal dma_wr_data    : std_ulogic_vector(127 downto 0);   -- gcm → adapter
    signal dma_wr_req     : std_ulogic;                        -- gcm → adapter
    signal dma_wr_done    : std_ulogic;                        -- adapter → gcm

    ---------------------------------------------------------------------------
    -- Soft-reset: csr_soft_reset (one-cycle pulse from axi_slave) is ANDed
    -- with aresetn to produce derived resets for gcm and dma_engine.
    -- "Soft" means software-initiated, not non-disruptive; all FSMs and the
    -- DMA burst adapter are reset together to prevent stale burst state.
    -- In-flight AXI transactions are abandoned, which is acceptable for a
    -- synchronous reset in this teaching context.
    ---------------------------------------------------------------------------
    signal aresetn_gcm    : std_ulogic;
    signal aresetn_dma    : std_ulogic;

    ---------------------------------------------------------------------------
    -- IRQ edge-detection
    ---------------------------------------------------------------------------
    signal irq_i      : std_ulogic := '0';
    signal prev_done  : std_ulogic := '0';
    signal prev_error : std_ulogic := '0';

    ---------------------------------------------------------------------------
    -- DMA burst adapter (p_dma_adapter)
    --
    -- Read adapter FSM:
    --   Phase 0 = AAD, Phase 1 = GCTR.
    --   On the first dma_rd_req of each phase, start the DMA read burst.
    --   For each subsequent pulse, forward the next assembled block.
    --   gcm_wants_rd_r latches "GCM is waiting" so the block can arrive later.
    --
    -- Write adapter:
    --   On the first dma_wr_req, issue wr_start with the total block count.
    --   For every dma_wr_req, push data into the split FIFO.
    --   dma_wr_done is a sticky level that fires when wr_done_s fires (all AXI
    --   writes acknowledged by BRESP), ensuring GCM_GCTR_LAST does not proceed
    --   until DDR writes are complete.  Cleared on csr_start or reset.
    ---------------------------------------------------------------------------

    -- Adapter phase / state registers
    signal rd_adp_phase_r   : std_ulogic                    := '0';
    signal rd_adp_started_r : std_ulogic                    := '0';
    signal rd_blk_fwd_r     : unsigned(23 downto 0)         := (others => '0');
    signal rd_blk_total_r   : unsigned(23 downto 0)         := (others => '0');
    signal gcm_wants_rd_r   : std_ulogic                    := '0';
    signal wr_adp_started_r : std_ulogic                    := '0';
    signal gcm_has_wr_r     : std_ulogic                    := '0';
    signal wr_data_r        : std_ulogic_vector(127 downto 0) := (others => '0');

    -- Adapter → dma_engine control
    signal rd_start_s          : std_ulogic                    := '0';
    signal rd_base_addr_s      : std_ulogic_vector(31 downto 0) := (others => '0');
    signal rd_block_count_s    : std_ulogic_vector(23 downto 0) := (others => '0');
    signal wr_start_s          : std_ulogic                    := '0';
    signal wr_base_addr_s      : std_ulogic_vector(31 downto 0) := (others => '0');
    signal wr_block_count_s    : std_ulogic_vector(23 downto 0) := (others => '0');
    signal rd_block_consumed_s : std_ulogic                    := '0';
    signal wr_block_valid_s    : std_ulogic                    := '0';
    signal wr_block_data_s     : std_ulogic_vector(127 downto 0) := (others => '0');

    -- dma_engine → adapter / p_status wires
    signal rd_block_data_s     : std_ulogic_vector(127 downto 0);
    signal rd_block_valid_s    : std_ulogic;
    signal wr_block_accepted_s : std_ulogic;
    signal rd_done_s           : std_ulogic;
    signal wr_done_s           : std_ulogic;
    signal dma_error_s         : std_ulogic;

begin

    ---------------------------------------------------------------------------
    -- Combinatorial assignments
    ---------------------------------------------------------------------------
    aresetn_gcm <= aresetn and not csr_soft_reset;
    aresetn_dma <= aresetn and not csr_soft_reset;
    ct_len_out  <= pt_len_reg;                  -- GCM: CT len = PT len
    irq         <= irq_i and not sw(0);         -- sw(0) gates IRQ for polling mode
    led(0)      <= csr_busy;
    led(1)      <= csr_done;
    led(2)      <= csr_error;
    led(3)      <= csr_tag_valid;

    ---------------------------------------------------------------------------
    -- Status register management
    -- Derives csr_busy/done/tag_valid/error from gcm_done / gcm_auth_fail.
    -- gcm.vhd: done_o fires for exactly one cycle; tag_o is stable then.
    ---------------------------------------------------------------------------
    p_status : process(aclk) is
    begin
        if rising_edge(aclk) then
            if aresetn = '0' or csr_soft_reset = '1' then
                csr_busy      <= '0';
                csr_done      <= '0';
                csr_tag_valid <= '0';
                csr_error     <= '0';
                tag_computed  <= (others => '0');
            else
                if csr_start = '1' then
                    csr_busy      <= '1';
                    csr_done      <= '0';
                    csr_tag_valid <= '0';
                    csr_error     <= '0';
                end if;
                if gcm_done = '1' then
                    csr_busy     <= '0';
                    csr_done     <= '1';
                    tag_computed <= gcm_tag;
                    if gcm_auth_fail = '1' or dma_error_s = '1' then
                        csr_error     <= '1';
                        csr_tag_valid <= '0';
                    else
                        csr_error     <= '0';
                        csr_tag_valid <= '1';
                    end if;
                elsif dma_error_s = '1' then
                    csr_error <= '1';
                end if;
            end if;
        end if;
    end process p_status;

    ---------------------------------------------------------------------------
    -- IRQ: one-cycle pulse on csr_done or csr_error rising edge
    ---------------------------------------------------------------------------
    p_irq : process(aclk) is
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                irq_i      <= '0';
                prev_done  <= '0';
                prev_error <= '0';
            else
                irq_i      <= '0';
                prev_done  <= csr_done;
                prev_error <= csr_error;
                if (csr_done = '1' and prev_done = '0') or
                   (csr_error = '1' and prev_error = '0') then
                    irq_i <= '1';
                end if;
            end if;
        end if;
    end process p_irq;

    ---------------------------------------------------------------------------
    -- DMA burst adapter
    ---------------------------------------------------------------------------
    p_dma_adapter : process(aclk) is
    begin
        if rising_edge(aclk) then
            -- One-cycle pulse defaults
            rd_start_s          <= '0';
            wr_start_s          <= '0';
            rd_block_consumed_s <= '0';
            wr_block_valid_s    <= '0';
            dma_rd_valid        <= '0';
            -- dma_wr_done is sticky: once armed it stays '1' until the next
            -- csr_start or reset, so GCM_GCTR_LAST can sample it any cycle.

            if aresetn = '0' or csr_soft_reset = '1' then
                rd_adp_phase_r   <= '0';
                rd_adp_started_r <= '0';
                rd_blk_fwd_r     <= (others => '0');
                rd_blk_total_r   <= (others => '0');
                gcm_wants_rd_r   <= '0';
                wr_adp_started_r <= '0';
                gcm_has_wr_r     <= '0';
                dma_wr_done      <= '0';
                wr_data_r        <= (others => '0');
                wr_block_data_s  <= (others => '0');
            else
                -- Re-arm on every new GCM operation
                if csr_start = '1' then
                    rd_adp_started_r <= '0';
                    rd_blk_fwd_r     <= (others => '0');
                    gcm_wants_rd_r   <= '0';
                    wr_adp_started_r <= '0';
                    gcm_has_wr_r     <= '0';
                    dma_wr_done      <= '0';
                    -- If AAD is zero-length, first read request is GCTR
                    if aad_len_reg = x"00000000" then
                        rd_adp_phase_r <= '1';
                    else
                        rd_adp_phase_r <= '0';
                    end if;
                end if;

                -- ── READ ADAPTER ─────────────────────────────────────────
                -- dma_rd_req means GCM has moved to a _WAIT state and will
                -- hold there until dma_rd_valid fires.
                -- The FIRST request of each phase also starts the DMA burst.

                if dma_rd_req = '1' then
                    gcm_wants_rd_r <= '1';
                    if rd_adp_started_r = '0' then
                        rd_start_s     <= '1';
                        rd_base_addr_s <= "00" & dma_rd_addr;
                        if rd_adp_phase_r = '0' then   -- AAD phase
                            rd_block_count_s <= aad_len_reg(27 downto 4);
                            rd_blk_total_r   <= unsigned(aad_len_reg(27 downto 4));
                        else                            -- GCTR phase
                            rd_block_count_s <= pt_len_reg(27 downto 4);
                            rd_blk_total_r   <= unsigned(pt_len_reg(27 downto 4));
                        end if;
                        rd_blk_fwd_r     <= (others => '0');
                        rd_adp_started_r <= '1';
                    end if;
                end if;

                -- Forward assembled block to GCM when both sides are ready.
                -- rd_block_valid_s stays high until rd_block_consumed_s fires
                -- (block_join uses a FIFO with combinatorial valid).
                if gcm_wants_rd_r = '1' and rd_block_valid_s = '1' then
                    dma_rd_data         <= rd_block_data_s;
                    dma_rd_valid        <= '1';
                    rd_block_consumed_s <= '1';
                    gcm_wants_rd_r      <= '0';
                    -- Advance forward counter; switch phase after last AAD block
                    if rd_blk_fwd_r + 1 = rd_blk_total_r then
                        rd_adp_started_r <= '0';
                        rd_adp_phase_r   <= '1';   -- GCTR phase next
                    end if;
                    rd_blk_fwd_r <= rd_blk_fwd_r + 1;
                end if;

                -- ── WRITE ADAPTER ────────────────────────────────────────
                -- dma_wr_req means GCM has a complete output block ready.
                -- The FIRST request also sets up the DMA write burst.

                if dma_wr_req = '1' then
                    wr_data_r    <= dma_wr_data;
                    gcm_has_wr_r <= '1';
                    if wr_adp_started_r = '0' then
                        wr_start_s       <= '1';
                        wr_base_addr_s   <= "00" & dma_wr_addr;
                        wr_block_count_s <= pt_len_reg(27 downto 4);
                        wr_adp_started_r <= '1';
                    end if;
                end if;

                -- Keep wr_block_valid asserted until block_split accepts.
                -- wr_block_accepted_s = split_s_ready is combinatorial and
                -- fires on the same cycle the block is queued into the FIFO.
                if gcm_has_wr_r = '1' then
                    wr_block_valid_s <= '1';
                    wr_block_data_s  <= wr_data_r;
                    if wr_block_accepted_s = '1' then
                        gcm_has_wr_r <= '0';
                    end if;
                end if;

                -- dma_wr_done: sticky; armed when the DMA write engine confirms the
                -- last AXI write via BRESP (wr_done_s), not when block_split merely
                -- accepts data into its FIFO.  This ensures done_o is not asserted
                -- while DDR writes are still in flight, preventing cache-invalidation
                -- races on the CPU side.
                if wr_done_s = '1' then
                    dma_wr_done <= '1';
                end if;

            end if;
        end if;
    end process p_dma_adapter;

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
            fsm_state_in     => (others => '0'),  -- gcm.vhd does not expose FSM state
            key_loaded_pulse => key_loaded
        );

    ---------------------------------------------------------------------------
    -- DMA engine instantiation
    ---------------------------------------------------------------------------
    u_dma : dma_engine
        port map (
            aclk               => aclk,
            aresetn            => aresetn_dma,
            m0_axi_araddr      => m0_axi_araddr,
            m0_axi_arvalid     => m0_axi_arvalid,
            m0_axi_arready     => m0_axi_arready,
            m0_axi_rdata       => m0_axi_rdata,
            m0_axi_rresp       => m0_axi_rresp,
            m0_axi_rvalid      => m0_axi_rvalid,
            m0_axi_rready      => m0_axi_rready,
            m0_axi_awaddr      => m0_axi_awaddr,
            m0_axi_awvalid     => m0_axi_awvalid,
            m0_axi_awready     => m0_axi_awready,
            m0_axi_wdata       => m0_axi_wdata,
            m0_axi_wstrb       => m0_axi_wstrb,
            m0_axi_wvalid      => m0_axi_wvalid,
            m0_axi_wready      => m0_axi_wready,
            m0_axi_bresp       => m0_axi_bresp,
            m0_axi_bvalid      => m0_axi_bvalid,
            m0_axi_bready      => m0_axi_bready,
            rd_start           => rd_start_s,
            rd_base_addr       => rd_base_addr_s,
            rd_block_count     => rd_block_count_s,
            wr_start           => wr_start_s,
            wr_base_addr       => wr_base_addr_s,
            wr_block_count     => wr_block_count_s,
            rd_block_data      => rd_block_data_s,
            rd_block_valid     => rd_block_valid_s,
            rd_block_consumed  => rd_block_consumed_s,
            wr_block_data      => wr_block_data_s,
            wr_block_valid     => wr_block_valid_s,
            wr_block_accepted  => wr_block_accepted_s,
            rd_done            => rd_done_s,
            wr_done            => wr_done_s,
            dma_error          => dma_error_s
        );

    ---------------------------------------------------------------------------
    -- GCM engine instantiation
    ---------------------------------------------------------------------------
    u_gcm : gcm
        port map (
            aclk           => aclk,
            aresetn        => aresetn_gcm,
            mode_i         => csr_mode,
            key_i          => key_reg,
            iv_i           => iv_reg,
            aad_addr_i     => aad_addr_reg(29 downto 0),
            aad_len_i      => aad_len_reg(29 downto 0),
            pt_addr_i      => pt_addr_reg(29 downto 0),
            pt_len_i       => pt_len_reg(29 downto 0),
            ct_addr_i      => ct_addr_reg(29 downto 0),
            tag_i          => tag_expected,
            start_i        => csr_start,
            tag_o          => gcm_tag,
            done_o         => gcm_done,
            auth_fail_o    => gcm_auth_fail,
            -- DMA interface: wired to p_dma_adapter burst bridge
            dma_rd_addr_o  => dma_rd_addr,
            dma_rd_req_o   => dma_rd_req,
            dma_rd_data_i  => dma_rd_data,
            dma_rd_valid_i => dma_rd_valid,
            dma_wr_addr_o  => dma_wr_addr,
            dma_wr_data_o  => dma_wr_data,
            dma_wr_req_o   => dma_wr_req,
            dma_wr_done_i  => dma_wr_done
        );

end architecture rtl;
