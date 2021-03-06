---------------------------------------------------------------------------------------------------
--    _____      _      _    _ __  __ __  __
--   |  __ \    (_)    | |  | |  \/  |  \/  |
--   | |__) |_ _ _ _ __| |__| | \  / | \  / |
--   |  ___/ _` | | '__|  __  | |\/| | |\/| |
--   | |  | (_| | | |  | |  | | |  | | |  | |
--   |_|   \__,_|_|_|  |_|  |_|_|  |_|_|  |_|
---------------------------------------------------------------------------------------------------
-- Processing Element
---------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.functions.all;
use work.posit_common.all;
use work.pe_package.all;                -- Posit configuration specific

entity pe is
  generic (
    FIRST           : std_logic := '0';  -- Not first processing element by default
    DISABLE_THETA   : std_logic := '1';  -- Theta is disabled by default
    DISABLE_UPSILON : std_logic := '1'  -- Upsilon is disabled by default
    );
  port (
    cr : in  cr_in;
    i  : in  pe_in;
    o  : out pe_out
    );
end pe;

architecture rtl of pe is
  -- Intermediate signals
  signal step     : step_type;
  signal step_raw : step_raw_type;

  -- Shift Registers (SRs)
  signal initial_sr : initial_array_pe_raw    := (others => value_empty);
  signal mids_sr    : mids_raw_array          := (others => mids_raw_empty);
  signal tmis_sr    : transmissions_raw_array := (others => tmis_raw_empty);
  signal emis_sr    : emissions_raw_array     := (others => emis_raw_empty);
  signal valid_sr   : valid_array             := (others => '0');
  signal cell_sr    : cell_array              := (others => PE_NORMAL);
  signal x_sr       : bps                     := bps_empty;
  signal y_sr       : bps                     := bps_empty;

  -- To select the right input for the last Mult
  signal distm : value;

  -- Potential outputs depening on basepairs:
  signal o_normal : pe_out;
  signal o_bypass : pe_out;
  signal o_buf    : pe_out;

  -- Gamma delay SR to match the delay of alpha + beta adder
  type add_gamma_sr_type is array (0 to PE_ADD_CYCLES - 1) of value_product;
  signal add_gamma_sr : add_gamma_sr_type := (others => value_product_empty);

  type mul_sr_type is array (0 to PE_MUL_CYCLES - 1) of value_product;
  type add_sr_type is array (0 to PE_MUL_CYCLES - 1) of value_sum;
  signal mul_theta_sr             : add_sr_type                                := (others => value_sum_empty);
  signal mul_theta_truncated_sr   : std_logic_vector(PE_MUL_CYCLES-1 downto 0) := (others => '0');
  signal mul_upsilon_sr           : add_sr_type                                := (others => value_sum_empty);
  signal mul_upsilon_truncated_sr : std_logic_vector(PE_MUL_CYCLES-1 downto 0) := (others => '0');

  type fp_valids_type is array (0 to 13) of std_logic;
  signal fp_valids : fp_valids_type;

  signal posit_norm : step_type := step_type_init;

  -- signal distm_norm, emult_m_val, mul_theta_val, mul_upsilon_val, add_albetl_val, initial_val : std_logic_vector(31 downto 0);
  signal posit_truncated : std_logic_vector(10 downto 0) := (others => '0');
-- signal mids_ml, mids_il, mids_dl, add_albetl                                                : value                         := value_empty;
begin

  ---------------------------------------------------------------------------------------------------
  --    _____                   _
  --   |_   _|                 | |
  --     | |  _ __  _ __  _   _| |_ ___
  --     | | | '_ \| '_ \| | | | __/ __|
  --    _| |_| | | | |_) | |_| | |_\__ \
  --   |_____|_| |_| .__/ \__,_|\__|___/
  --               | |
  --               |_|
  ---------------------------------------------------------------------------------------------------
  step_raw.init.valid <= i.valid;
  step_raw.init.cell  <= i.cell;

  step_raw.init.initial <= i.initial;

  step_raw.init.x <= i.x;
  step_raw.init.y <= i.y;

  step_raw.init.tmis <= i.tmis;
  step_raw.init.emis <= i.emis;

  ----------------------------------------------------------------------------------------------------------------------- Coming from the left
  step_raw.init.mids.ml <= i.mids.ml when i.x /= BP_STOP else o_buf.mids.ml;  -- or own output when x is stop
  step_raw.init.mids.il <= i.mids.il when i.x /= BP_STOP else o_buf.mids.il;  -- or own output when x is stop
  step_raw.init.mids.dl <= i.mids.dl;

  ----------------------------------------------------------------------------------------------------------------------- Coming from the top
  -- All top inputs can be potentially zero when working on the first row of the matrix
  step_raw.init.mids.mt <= prod2val(step_raw.emult.m)               when i.cell /= PE_TOP else value_empty;
  step_raw.init.mids.it <= sum2val(mul_theta_sr(PE_MUL_CYCLES-1))   when i.cell /= PE_TOP else value_empty;
  step_raw.init.mids.dt <= sum2val(mul_upsilon_sr(PE_MUL_CYCLES-1)) when i.cell /= PE_TOP else i.initial;

----------------------------------------------------------------------------------------------------------------------- Coming from the top left
  -- Initial Signal for top left; if this is the First PE we get M,I,D [i-1][j-1] from the inputs
  ISF : if FIRST = '1' generate
    step_raw.init.mids.mtl <= mids_sr(PE_CYCLES-1).ml when i.cell /= PE_TOP else i.mids.mtl;
    step_raw.init.mids.itl <= mids_sr(PE_CYCLES-1).il when i.cell /= PE_TOP else i.mids.itl;
  end generate;
  -- Initial Signal; if this is Not the First PE we get M,I,D [i-1][j-1] from the shift registers
  ISNF : if FIRST /= '1' generate
    step_raw.init.mids.mtl <= mids_sr(PE_CYCLES-1).ml when i.cell /= PE_TOP else value_empty;
    step_raw.init.mids.itl <= mids_sr(PE_CYCLES-1).il when i.cell /= PE_TOP else value_empty;
  end generate;

  -- Initial Signal for D:
  step_raw.init.mids.dtl <= mids_sr(PE_CYCLES-1).dl when i.cell /= PE_TOP else i.initial;

  ---------------------------------------------------------------------------------------------------
  --     _____ _               __     __  __       _ _   _       _ _           _   _
  --    / ____| |             /_ |_  |  \/  |     | | | (_)     | (_)         | | (_)
  --   | (___ | |_ ___ _ __    | (_) | \  / |_   _| | |_ _ _ __ | |_  ___ __ _| |_ _  ___  _ __  ___
  --    \___ \| __/ _ \ '_ \   | |   | |\/| | | | | | __| | '_ \| | |/ __/ _` | __| |/ _ \| '_ \/ __|
  --    ____) | ||  __/ |_) |  | |_  | |  | | |_| | | |_| | |_) | | | (_| (_| | |_| | (_) | | | \__ \
  --   |_____/ \__\___| .__/   |_(_) |_|  |_|\__,_|_|\__|_| .__/|_|_|\___\__,_|\__|_|\___/|_| |_|___/
  --                  | |                                 | |
  --                  |_|                                 |_|
  ---------------------------------------------------------------------------------------------------
  -- Transmission probabilties multiplied with M, D, I
  --
  -- 4 CYCLES
  ---------------------------------------------------------------------------------------------------

  gen_es2_mul_alpha : if POSIT_ES = 2 generate
    mul_alpha : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.alpha,
      in2    => step_raw.init.mids.mtl,
      start  => step.init.valid,
      result => step_raw.trans.almtl,
      done   => fp_valids(0)
      );
  end generate;
  gen_es3_mul_alpha : if POSIT_ES = 3 generate
    mul_alpha : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.alpha,
      in2    => step_raw.init.mids.mtl,
      start  => step.init.valid,
      result => step_raw.trans.almtl,
      done   => fp_valids(0)
      );
  end generate;

  gen_es2_mul_beta : if POSIT_ES = 2 generate
    mul_beta : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.beta,
      in2    => step_raw.init.mids.itl,
      start  => step_raw.init.valid,
      result => step_raw.trans.beitl,
      done   => fp_valids(1)
      );
  end generate;
  gen_es3_mul_beta : if POSIT_ES = 3 generate
    mul_beta : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.beta,
      in2    => step_raw.init.mids.itl,
      start  => step_raw.init.valid,
      result => step_raw.trans.beitl,
      done   => fp_valids(1)
      );
  end generate;

  gen_es2_mul_gamma : if POSIT_ES = 2 generate
    mul_gamma : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.beta,
      in2    => step_raw.init.mids.dtl,
      start  => step_raw.init.valid,
      result => step_raw.trans.gadtl,
      done   => fp_valids(2)
      );
  end generate;
  gen_es3_mul_gamma : if POSIT_ES = 3 generate
    mul_gamma : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.beta,
      in2    => step_raw.init.mids.dtl,
      start  => step_raw.init.valid,
      result => step_raw.trans.gadtl,
      done   => fp_valids(2)
      );
  end generate;

  gen_es2_mul_delta : if POSIT_ES = 2 generate
    mul_delta : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.delta,
      in2    => step_raw.init.mids.mt,
      start  => step_raw.init.valid,
      result => step_raw.trans.demt,
      done   => fp_valids(3)
      );
  end generate;
  gen_es3_mul_delta : if POSIT_ES = 3 generate
    mul_delta : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.delta,
      in2    => step_raw.init.mids.mt,
      start  => step_raw.init.valid,
      result => step_raw.trans.demt,
      done   => fp_valids(3)
      );
  end generate;

  gen_es2_mul_epsilon : if POSIT_ES = 2 generate
    mul_epsilon : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.epsilon,
      in2    => step_raw.init.mids.it,
      start  => step_raw.init.valid,
      result => step_raw.trans.epit,
      done   => fp_valids(4)
      );
  end generate;
  gen_es3_mul_epsilon : if POSIT_ES = 3 generate
    mul_epsilon : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.epsilon,
      in2    => step_raw.init.mids.it,
      start  => step_raw.init.valid,
      result => step_raw.trans.epit,
      done   => fp_valids(4)
      );
  end generate;

  gen_es2_mul_zeta : if POSIT_ES = 2 generate
    mul_zeta : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.zeta,
      in2    => step_raw.init.mids.ml,
      start  => step_raw.init.valid,
      result => step_raw.trans.zeml,
      done   => fp_valids(5)
      );
  end generate;
  gen_es3_mul_zeta : if POSIT_ES = 3 generate
    mul_zeta : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.zeta,
      in2    => step_raw.init.mids.ml,
      start  => step_raw.init.valid,
      result => step_raw.trans.zeml,
      done   => fp_valids(5)
      );
  end generate;

  gen_es2_mul_eta : if POSIT_ES = 2 generate
    mul_eta : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.eta,
      in2    => step_raw.init.mids.dl,
      start  => step_raw.init.valid,
      result => step_raw.trans.etdl,
      done   => fp_valids(6)
      );
  end generate;
  gen_es3_mul_eta : if POSIT_ES = 3 generate
    mul_eta : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => step_raw.init.tmis.eta,
      in2    => step_raw.init.mids.dl,
      start  => step_raw.init.valid,
      result => step_raw.trans.etdl,
      done   => fp_valids(6)
      );
  end generate;

  ---------------------------------------------------------------------------------------------------
  --     _____ _               ___                  _     _ _ _   _
  --    / ____| |             |__ \ _      /\      | |   | (_) | (_)
  --   | (___ | |_ ___ _ __      ) (_)    /  \   __| | __| |_| |_ _  ___  _ __  ___
  --    \___ \| __/ _ \ '_ \    / /      / /\ \ / _` |/ _` | | __| |/ _ \| '_ \/ __|
  --    ____) | ||  __/ |_) |  / /_ _   / ____ \ (_| | (_| | | |_| | (_) | | | \__ \
  --   |_____/ \__\___| .__/  |____(_) /_/    \_\__,_|\__,_|_|\__|_|\___/|_| |_|___/
  --                  | |
  --                  |_|
  ---------------------------------------------------------------------------------------------------
  -- Addition of the multiplied probabilities
  --
  -- 8 CYCLES
  ---------------------------------------------------------------------------------------------------

  -- BEGIN alpha + beta + delayed gamma
  -- Substep adding alpha + beta
  gen_es2_add_alpha_beta : if POSIT_ES = 2 generate
    add_alpha_beta : positadd_4_raw port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.almtl),
      in2       => prod2val(step_raw.trans.beitl),
      start     => step_raw.init.valid,
      result    => step_raw.add.albetl,
      done      => fp_valids(7),
      truncated => posit_truncated(0)
      );
  end generate;
  gen_es3_add_alpha_beta : if POSIT_ES = 3 generate
    add_alpha_beta : positadd_4_raw_es3 port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.almtl),
      in2       => prod2val(step_raw.trans.beitl),
      start     => step_raw.init.valid,
      result    => step_raw.add.albetl,
      done      => fp_valids(7),
      truncated => posit_truncated(0)
      );
  end generate;

  -- Substep adding alpha + beta + delayed gamma
  gen_es2_add_alpha_beta_gamma : if POSIT_ES = 2 generate
    add_alpha_beta_gamma : positadd_4_raw port map (
      clk       => cr.clk,
      in1       => sum2val(step_raw.add.albetl),
      in2       => prod2val(add_gamma_sr(PE_ADD_CYCLES-1)),
      start     => step_raw.init.valid,
      result    => step_raw.add.albegatl,
      done      => fp_valids(8),
      truncated => posit_truncated(1)
      );
  end generate;
  gen_es3_add_alpha_beta_gamma : if POSIT_ES = 3 generate
    add_alpha_beta_gamma : positadd_4_raw_es3 port map (
      clk       => cr.clk,
      in1       => sum2val(step_raw.add.albetl),
      in2       => prod2val(add_gamma_sr(PE_ADD_CYCLES-1)),
      start     => step_raw.init.valid,
      result    => step_raw.add.albegatl,
      done      => fp_valids(8),
      truncated => posit_truncated(1)
      );
  end generate;
  -- END alpha + beta + delayed gamma

  gen_es2_add_delta_epsilon : if POSIT_ES = 2 generate
    add_delta_epsilon : positadd_8_raw port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.demt),
      in2       => prod2val(step_raw.trans.epit),
      start     => step_raw.init.valid,
      result    => step_raw.add.deept,
      done      => fp_valids(9),
      truncated => posit_truncated(2)
      );
  end generate;
  gen_es3_add_delta_epsilon : if POSIT_ES = 3 generate
    add_delta_epsilon : positadd_8_raw_es3 port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.demt),
      in2       => prod2val(step_raw.trans.epit),
      start     => step_raw.init.valid,
      result    => step_raw.add.deept,
      done      => fp_valids(9),
      truncated => posit_truncated(2)
      );
  end generate;

  gen_es2_add_zeta_eta : if POSIT_ES = 2 generate
    add_zeta_eta : positadd_8_raw port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.zeml),
      in2       => prod2val(step_raw.trans.etdl),
      start     => step_raw.init.valid,
      result    => step_raw.add.zeett,
      done      => fp_valids(10),
      truncated => posit_truncated(3)
      );
  end generate;
  gen_es3_add_zeta_eta : if POSIT_ES = 3 generate
    add_zeta_eta : positadd_8_raw_es3 port map (
      clk       => cr.clk,
      in1       => prod2val(step_raw.trans.zeml),
      in2       => prod2val(step_raw.trans.etdl),
      start     => step_raw.init.valid,
      result    => step_raw.add.zeett,
      done      => fp_valids(10),
      truncated => posit_truncated(3)
      );
  end generate;

  ---------------------------------------------------------------------------------------------------
  --     _____ _               ____      __  __       _ _   _       _ _           _   _
  --    / ____| |             |___ \ _  |  \/  |     | | | (_)     | (_)         | | (_)
  --   | (___ | |_ ___ _ __     __) (_) | \  / |_   _| | |_ _ _ __ | |_  ___ __ _| |_ _  ___  _ __  ___
  --    \___ \| __/ _ \ '_ \   |__ <    | |\/| | | | | | __| | '_ \| | |/ __/ _` | __| |/ _ \| '_ \/ __|
  --    ____) | ||  __/ |_) |  ___) |_  | |  | | |_| | | |_| | |_) | | | (_| (_| | |_| | (_) | | | \__ \
  --   |_____/ \__\___| .__/  |____/(_) |_|  |_|\__,_|_|\__|_| .__/|_|_|\___\__,_|\__|_|\___/|_| |_|___/
  --                  | |                                    | |
  --                  |_|                                    |_|
  ---------------------------------------------------------------------------------------------------
  -- Step 3: Multiplication of the emission probabilities
  --
  -- 4 CYCLES
  ---------------------------------------------------------------------------------------------------

  -- Mux for the final multiplication
  -- Select correct emission probability (distm) depending on read
  process(step_raw, y_sr, x_sr)
  begin
    if y_sr(PE_BCC-1) = x_sr(PE_BCC-1) or y_sr(PE_BCC-1) = BP_N or x_sr(PE_BCC-1) = BP_N
    then
      distm <= step_raw.add.emis.distm_simi;
    else
      distm <= step_raw.add.emis.distm_diff;
    end if;
  end process;

  gen_es2_mul_lambda : if POSIT_ES = 2 generate
    mul_lambda : positmult_4_raw port map (
      clk    => cr.clk,
      in1    => sum2val(step_raw.add.albegatl),
      in2    => distm,
      start  => step_raw.init.valid,
      result => step_raw.emult.m,
      done   => fp_valids(11)
      );
  end generate;
  gen_es3_mul_lambda : if POSIT_ES = 3 generate
    mul_lambda : positmult_4_raw_es3 port map (
      clk    => cr.clk,
      in1    => sum2val(step_raw.add.albegatl),
      in2    => distm,
      start  => step_raw.init.valid,
      result => step_raw.emult.m,
      done   => fp_valids(11)
      );
  end generate;

  fp_valids(12) <= '1';
  fp_valids(13) <= '1';

  ---------------------------------------------------------------------------------------------------
  --    ____         __  __
  --   |  _ \       / _|/ _|
  --   | |_) |_   _| |_| |_ ___ _ __ ___
  --   |  _ <| | | |  _|  _/ _ \ '__/ __|
  --   | |_) | |_| | | | ||  __/ |  \__ \
  --   |____/ \__,_|_| |_| \___|_|  |___/
  ---------------------------------------------------------------------------------------------------
  -- Shift register for gamma to match the latency of alpha+beta adder
  ---------------------------------------------------------------------------------------------------
  add_gamma_shift_reg : process(cr.clk)
  begin
    if rising_edge(cr.clk) then
      if cr.rst = '1' then
        -- Reset shift register:
        add_gamma_sr <= (others => value_product_empty);
      else
        add_gamma_sr(0) <= step_raw.trans.gadtl;
        -- Shifts:
        for I in 1 to PE_ADD_CYCLES-1 loop
          add_gamma_sr(I) <= add_gamma_sr(I-1);
        end loop;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------------------------------
  -- Shift register to match the latency of the lambda multiplier in case theta and upsilon
  -- are always 1.0
  ---------------------------------------------------------------------------------------------------
  skip_mul_theta_sr : process(cr.clk)
  begin
    if rising_edge(cr.clk) then
      if cr.rst = '1' then
        -- Reset shift register:
        mul_theta_sr           <= (others => value_sum_empty);
        mul_theta_truncated_sr <= (others => '0');
      else
        mul_theta_sr(0)           <= step_raw.add.deept;
        mul_theta_truncated_sr(0) <= posit_truncated(2);
        -- Shifts:
        for I in 1 to PE_MUL_CYCLES-1 loop
          mul_theta_sr(I)           <= mul_theta_sr(I-1);
          mul_theta_truncated_sr(I) <= mul_theta_truncated_sr(I-1);
        end loop;
      end if;
    end if;
  end process;

  skip_mul_upsilon_sr : process(cr.clk)
  begin
    if rising_edge(cr.clk) then
      if cr.rst = '1' then
        -- Reset shift register:
        mul_upsilon_sr           <= (others => value_sum_empty);
        mul_upsilon_truncated_sr <= (others => '0');
      else
        mul_upsilon_sr(0)           <= step_raw.add.zeett;
        mul_upsilon_truncated_sr(0) <= posit_truncated(3);
        -- Shifts:
        for I in 1 to PE_MUL_CYCLES-1 loop
          mul_upsilon_sr(I)           <= mul_upsilon_sr(I-1);
          mul_upsilon_truncated_sr(I) <= mul_upsilon_truncated_sr(I-1);
        end loop;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------------------------------
  -- Shift register to do the following:
  -- *  Delay the transmission and emission probabilities to insert them in the proper cycle.
  -- *  Delay the M, I and D from the top left cell with one full iteration.
  ---------------------------------------------------------------------------------------------------
  constants_shift : process(cr.clk)
  begin
    if rising_edge(cr.clk) then
      if cr.rst = '1' then
        -- Reset shift register:
        initial_sr <= (others => value_empty);
        mids_sr    <= (others => mids_raw_empty);
        tmis_sr    <= (others => tmis_raw_empty);
        emis_sr    <= (others => emis_raw_empty);
        valid_sr   <= (others => '0');
        cell_sr    <= (others => PE_NORMAL);
        x_sr       <= bps_empty;
        y_sr       <= bps_empty;
      else
        initial_sr(0) <= step_raw.init.initial;
        mids_sr(0)    <= step_raw.init.mids;
        tmis_sr(0)    <= step_raw.init.tmis;
        emis_sr(0)    <= step_raw.init.emis;

        valid_sr(0) <= step_raw.init.valid;
        cell_sr(0)  <= step_raw.init.cell;
        x_sr(0)     <= step_raw.init.x;
        y_sr(0)     <= step_raw.init.y;

        -- Shifts:
        for I in 1 to PE_CYCLES-1 loop
          initial_sr(I) <= initial_sr(I-1);
          mids_sr(I)    <= mids_sr(I-1);
          tmis_sr(I)    <= tmis_sr(I-1);
          emis_sr(I)    <= emis_sr(I-1);

          valid_sr(I) <= valid_sr(I-1);
          cell_sr(I)  <= cell_sr(I-1);
          x_sr(I)     <= x_sr(I-1);
          y_sr(I)     <= y_sr(I-1);
        end loop;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------------------------------
  --     _____ _                   _
  --    / ____(_)                 | |
  --   | (___  _  __ _ _ __   __ _| |___
  --    \___ \| |/ _` | '_ \ / _` | / __|
  --    ____) | | (_| | | | | (_| | \__ \
  --   |_____/|_|\__, |_| |_|\__,_|_|___/
  --              __/ |
  --             |___/
  ---------------------------------------------------------------------------------------------------

  step_raw.add.tmis <= tmis_sr(PE_MUL_CYCLES + 2 * PE_ADD_CYCLES - 1);
  step_raw.add.emis <= emis_sr(PE_MUL_CYCLES + 2 * PE_ADD_CYCLES - 1);

  step_raw.emult.tmis <= tmis_sr(PE_CYCLES-1);
  step_raw.emult.emis <= emis_sr(PE_CYCLES-1);

  ---------------------------------------------------------------------------------------------------
  --    _   _                            _    ____        _               _
  --   | \ | |                          | |  / __ \      | |             | |
  --   |  \| | ___  _ __ _ __ ___   __ _| | | |  | |_   _| |_ _ __  _   _| |_ ___
  --   | . ` |/ _ \| '__| '_ ` _ \ / _` | | | |  | | | | | __| '_ \| | | | __/ __|
  --   | |\  | (_) | |  | | | | | | (_| | | | |__| | |_| | |_| |_) | |_| | |_\__ \
  --   |_| \_|\___/|_|  |_| |_| |_|\__,_|_|  \____/ \__,_|\__| .__/ \__,_|\__|___/
  --                                                         | |
  --                                                         |_|
  ---------------------------------------------------------------------------------------------------
  -- Outputs when this PE is not in bypass mode
  ---------------------------------------------------------------------------------------------------

  o_normal.valid <= valid_sr(PE_CYCLES-1);
  o_normal.cell  <= cell_sr(PE_CYCLES-1);

  -- Probabilities
  o_normal.emis <= step_raw.emult.emis;
  o_normal.tmis <= step_raw.emult.tmis;

  o_normal.mids.ml  <= prod2val(step_raw.emult.m);
  o_normal.mids.mtl <= value_empty;
  o_normal.mids.mt  <= prod2val(step_raw.emult.m);

  o_normal.mids.il <= sum2val(mul_theta_sr(PE_MUL_CYCLES-1));

  o_normal.mids.itl <= value_empty;
  o_normal.mids.it  <= value_empty;

  o_normal.mids.dl <= sum2val(mul_upsilon_sr(PE_MUL_CYCLES-1));

  o_normal.mids.dtl <= value_empty;
  o_normal.mids.dt  <= value_empty;

  -- Output X & Y
  o_normal.x <= x_sr(PE_CYCLES-1);
  o_normal.y <= y_sr(PE_CYCLES-1);

  o_normal.initial <= initial_sr(PE_CYCLES-1);

  o_normal.ready <= '1';

  ---------------------------------------------------------------------------------------------------
  --    ____                               ____        _               _
  --   |  _ \                             / __ \      | |             | |
  --   | |_) |_   _ _ __   __ _ ___ ___  | |  | |_   _| |_ _ __  _   _| |_ ___
  --   |  _ <| | | | '_ \ / _` / __/ __| | |  | | | | | __| '_ \| | | | __/ __|
  --   | |_) | |_| | |_) | (_| \__ \__ \ | |__| | |_| | |_| |_) | |_| | |_\__ \
  --   |____/ \__, | .__/ \__,_|___/___/  \____/ \__,_|\__| .__/ \__,_|\__|___/
  --           __/ | |                                    | |
  --          |___/|_|                                    |_|
  ---------------------------------------------------------------------------------------------------

  o_bypass.valid <= valid_sr(PE_CYCLES-1);
  o_bypass.cell  <= cell_sr(PE_CYCLES-1);

  -- Probabilities
  o_bypass.emis <= emis_sr(PE_CYCLES-1);
  o_bypass.tmis <= tmis_sr(PE_CYCLES-1);

  -- Output MIDs
  o_bypass.mids <= mids_sr(PE_CYCLES-1);

  -- Output X & Y
  o_bypass.x <= x_sr(PE_CYCLES-1);
  o_bypass.y <= y_sr(PE_CYCLES-1);

  -- Initial D row value
  o_bypass.initial <= initial_sr(PE_CYCLES-1);

  o_bypass.ready <= '1';

  --------------------------------------------------------------------------------------------------- Determine output:

  determine_out : process(o_bypass, o_normal, x_sr, y_sr)
  begin
    if x_sr(PE_CYCLES-1) = BP_STOP or y_sr(PE_CYCLES-1) = BP_STOP
    then
      o_buf <= o_bypass;
    else
      o_buf <= o_normal;
    end if;
  end process;

  o <= o_buf;

---------------------------------------------------------------------------------------------------
end rtl;
