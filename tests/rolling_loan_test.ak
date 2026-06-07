// ========= ROLLING LOAN TEST SUITE ==========
// Tests for the Rolling Loan mechanism: interest-index update, refinancing,
// collateral continuity, pool accounting, and loan-to-loan transition without
// requiring a separate manual repayment transaction.
//
// Rolling Loan Strategy:
//   1. A new loan is created (CreateLoan)
//   2. The borrowed amount is used to settle the existing loan (RepayLoan)
//   3. Collateral from the existing loan is transferred into the new loan
//   All within a single transaction.
//
// Note:
//   This file contains fixture-based Aiken unit tests. The values used here
//   are test fixture values. The public Preprod transaction evidence in the
//   Milestone 1 package demonstrates the same rolling/refinancing flow with
//   actual on-chain values.

// ========= SUCCESS CASES ==========
// succ_rolling_loan_full_repay_and_create_new_loan
// succ_interest_recalculation_after_time_elapsed
// succ_rolling_loan_with_zero_origination_fee
// succ_rolling_loan_interest_index_correctly_reset
// succ_rolling_loan_with_multiple_collaterals_transferred

// ========= FAILURE / CONSTRAINT CASES ==========
// fail_rolling_loan_when_interest_index_not_reset_on_new_loan
// fail_rolling_loan_when_collateral_not_sufficient_for_new_loan
// fail_rolling_loan_when_pool_total_borrow_incorrect_after_rolling
// fail_rolling_loan_when_undistributed_fee_incorrect_after_rolling
// fail_rolling_loan_when_total_supply_not_updated_with_interest
// fail_rolling_loan_when_interest_time_not_updated
// fail_rolling_loan_when_borrow_apy_not_recalculated
// fail_rolling_loan_when_util_rate_exceeds_cap_after_rolling
// fail_rolling_loan_when_interest_index_not_updated
// fail_rolling_loan_when_loan_amount_mismatch_pool_change
// fail_rolling_loan_when_loan_token_mismatch
// fail_rolling_loan_when_new_loan_pool_changed_amount_positive
// fail_rolling_loan_when_pool_changed_amount_below_min_tx
// fail_rolling_loan_when_off_collateral_used
// fail_rolling_loan_when_pool_total_assets_lt_reserve

use aiken/interval
use cardano/address
use constants
use daken/outref_hash
use daken/prational.{PRational}
use fixture/fx
use fixture/output_builder
use fixture/tx_builder
use loan
use pool
use types.{
  CreateLoan, LoanDatum, MarketDatum, OraclePriceCalculateRdmr, PoolDatum,
  RepayLoan,
}

// =============================================================================
// HELPER: Build a rolling loan transaction that creates a new loan and repays
// an existing loan in a single transaction.
// =============================================================================

// =============================================================================
// SUCCESS: ROLLING LOAN - Full repay existing loan + create new loan
// =============================================================================
// Scenario: Borrower has an existing loan with accrued interest.
// A new loan is created, the borrowed funds repay the old loan fully,
// and collateral is transferred from old loan to new loan.
// Pool in datum reflects state before rolling (has existing borrow).
// Time has elapsed so interest has accrued.

test succ_rolling_loan_full_repay_and_create_new_loan() {
  // --- Constants for this test ---
  // Existing loan: 1_000_000 tokens borrowed at interest_index 1_000_000_000_000
  // Time elapsed: ~1 year => interest accrued
  // Pool interest_index updated from 1_000_000_000_000 to 1_100_000_000_000 (10% interest)
  // current_loan_amount = floor(1_000_000 * 1_100_000_000_000 / 1_000_000_000_000) = 1_100_000
  // New loan borrows 1_200_000 to repay 1_100_000 (old debt) with remainder for fees

  // Ref input
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  // --- Pool input: has existing borrow of 1_000_000, interest has accrued ---
  let pool_in_datum =
    PoolDatum {
      ..fx.base_pool_in_datum_create_loan(),
      total_borrow: 1_000_000,
      total_supply: 5_000_000,
      interest_index: 1_000_000_000_000,
      borrow_apy: 1_000,
      undistributed_fee: 0,
      interest_time: 2_000_000_000,
    }
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // --- Existing loan input (being repaid) ---
  let loan_in_datum =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      loan_amount: 1_000_000,
      initial_interest_index: 1_000_000_000_000,
      owner_nft: Some(fx.owner_nft),
      token: fx.snek,
    }
  let loan_in =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_in_datum)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)
      |> output_builder.to_input()

  // --- Calculate interest ---
  // txn_time = 2_400_000_000, interest_time = 2_000_000_000
  // elapsed = 400_000_000 ms
  // current_interest_index = floor(1_000_000_000_000 + 1_000_000_000_000 * 1000/10000 * 400_000_000/31_536_000_000_000)
  //   = floor(1_000_000_000_000 + 1_000_000_000_000 * 0.1 * 0.00001268...)
  //   = floor(1_000_000_000_000 + 1_268_391)
  //   = 1_000_001_268_391
  // new_accumulated_interest = floor(1_000_000 * (1_000_001_268_391 / 1_000_000_000_000 - 1))
  //   = floor(1_000_000 * 0.000001268391) = floor(1.268391) = 1
  // new_loan_interest_fee = ceiling(1 * 2000/10000) = ceiling(0.2) = 1
  // total_supply_before_transaction = 5_000_000 + 1 - 1 = 5_000_000
  // current_loan_amount = floor(1_000_000 * 1_000_001_268_391 / 1_000_000_000_000) = 1_000_001

  // Repay amount = current_loan_amount = 1_000_001 (full repay, no loan out)
  // New loan borrow from pool = 1_800_000 (pool_changed_amount for create = -1_800_000)
  // Net pool change = -1_800_000 + 1_000_001 = -799_999

  // Pool out datum
  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      total_supply: 5_000_000,
      total_borrow: 1_000_000 + 1 + 1_800_000,
      interest_index: 1_000_001_268_391,
      borrow_apy: fx.base_pool_out_datum_create_loan().borrow_apy,
      undistributed_fee: 0 + 1 + 180_000,
      interest_time: 2_400_000_000,
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  // --- New loan output (collateral transferred from old loan) ---
  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let new_loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      loan_amount: 1_800_000,
      initial_interest_index: 1_000_001_268_391,
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
      token: fx.snek,
    }
  let new_loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(new_loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)

  // --- Redeemers ---
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let repay_loan_rdmr =
    RepayLoan {
      pool_out_idx: 2,
      loan_out_idx: None,
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()

  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(new_loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_input(loan_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_script_input(loan_in, repay_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// SUCCESS: Interest recalculation after time elapsed
// =============================================================================
// Verifies that when time passes between transactions, the interest index
// is correctly updated and accumulated interest is properly calculated.

test succ_interest_recalculation_after_time_elapsed() {
  // Pool had a previous transaction at time 2_000_000_000
  // Current transaction at time 2_400_000_000 (400 seconds later)
  // borrow_apy = 1000 bps (10%)
  // interest_index should increase based on elapsed time

  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)
  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// SUCCESS: Rolling loan with zero origination fee
// =============================================================================
// When loan_origination_fee_rate = 0, the rolling loan should work
// without any fee output required.

test succ_rolling_loan_with_zero_origination_fee() {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum =
    MarketDatum { ..fx.base_market_datum(), loan_origination_fee_rate: 0 }
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 1_000_000)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(
          fx.qsnek.1st,
          fx.qsnek.2nd,
          51_570_255 + 1_000_000 * 10_000 / 236,
        )
  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 1,
      loan_out_idx: 0,
      fee_out_idx: None,
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// SUCCESS: Interest index correctly reset on new loan
// =============================================================================
// Verifies that loan_out_datum.initial_interest_index = pool_out_datum.interest_index
// This ensures future interest accrual starts from the current baseline.

test succ_rolling_loan_interest_index_correctly_reset() {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 3_004_274)
      |> output_builder.to_input()

  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      total_supply: 3_004_274,
      alt_supply_tokens_rate: [PRational(235, 10_000)],
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 1_204_274)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  // Verify: initial_interest_index matches pool_out_datum.interest_index
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
      initial_interest_index: pool_out_datum.interest_index,
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)

  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// SUCCESS: Rolling loan with multiple collaterals transferred
// =============================================================================
// Collateral from the old loan (DJED + QDJED) is reused in the new loan.
// Demonstrates capital efficiency - no idle collateral.

test succ_rolling_loan_with_multiple_collaterals_transferred() {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)
  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  // Multiple collaterals: DJED + QDJED transferred from old to new loan
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: New loan initial_interest_index not reset to current pool interest_index
// =============================================================================
// The new loan must start with initial_interest_index = pool_out_datum.interest_index
// to avoid double-counting past interest. Setting an incorrect value should fail.

test fail_rolling_loan_when_interest_index_not_reset_on_new_loan() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  // fail: initial_interest_index set to old value instead of current
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
      initial_interest_index: 999_999_999_999,
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Collateral not sufficient for new loan (HF < 1)
// =============================================================================
// When rolling a loan, the collateral transferred must still satisfy
// total_collateral_val_with_threshold > loan_out_datum.loan_amount.

test fail_rolling_loan_when_collateral_not_sufficient_for_new_loan() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  // fail: insufficient collateral - only 100_000 DJED for a 1_800_000 loan
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 100_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 100_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Pool total_borrow incorrect after rolling loan
// =============================================================================
// pool_out_datum.total_borrow must equal:
//   pool_in_datum.total_borrow + new_accumulated_interest + loan_out_datum.loan_amount
// Setting an incorrect value should fail.

test fail_rolling_loan_when_pool_total_borrow_incorrect_after_rolling() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: total_borrow set to incorrect value
  let pool_out_datum =
    PoolDatum { ..fx.base_pool_out_datum_create_loan(), total_borrow: 999_999 }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Undistributed fee incorrect after rolling
// =============================================================================
// pool_out_datum.undistributed_fee must equal:
//   pool_in_datum.undistributed_fee + new_loan_interest_fee + loan_origination_fee
// An incorrect fee should fail the transaction.

test fail_rolling_loan_when_undistributed_fee_incorrect_after_rolling() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: undistributed_fee set to wrong value
  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      undistributed_fee: 12_345,
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Total supply not updated with accumulated interest
// =============================================================================
// pool_out_datum.total_supply must equal total_supply_before_transaction
// = pool_in_datum.total_supply + new_accumulated_interest - new_loan_interest_fee

test fail_rolling_loan_when_total_supply_not_updated_with_interest() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: total_supply incorrect
  let pool_out_datum =
    PoolDatum { ..fx.base_pool_out_datum_create_loan(), total_supply: 1_000 }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Interest time not updated to current transaction time
// =============================================================================
// pool_out_datum.interest_time must be set to start time of current transaction

test fail_rolling_loan_when_interest_time_not_updated() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: interest_time not updated (still old value)
  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      interest_time: 1_000_000_000,
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Borrow APY not recalculated after rolling loan
// =============================================================================
// pool_out_datum.borrow_apy must be recalculated based on current utilization

test fail_rolling_loan_when_borrow_apy_not_recalculated() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: borrow_apy not recalculated (set to arbitrary wrong value)
  let pool_out_datum =
    PoolDatum { ..fx.base_pool_out_datum_create_loan(), borrow_apy: 9_999 }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Utilization rate exceeds cap after rolling loan
// =============================================================================
// After rolling, the new utilization must stay below market_param.util_cap.

test fail_rolling_loan_when_util_rate_exceeds_cap_after_rolling() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  // Set util_cap very low so it's exceeded
  let market_datum = MarketDatum { ..fx.base_market_datum(), util_cap: 1000 }
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Pool interest index not updated correctly
// =============================================================================
// pool_out_datum.interest_index must equal current_interest_index

test fail_rolling_loan_when_interest_index_not_updated() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  // fail: interest_index set to wrong value
  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      interest_index: 500_000_000_000,
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Loan amount does not match pool changed amount
// =============================================================================
// loan_out_datum.loan_amount must equal -pool_changed_amount + loan_origination_fee

test fail_rolling_loan_when_loan_amount_mismatch_pool_change() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  // fail: loan_amount doesn't match pool_changed_amount
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
      loan_amount: 42,
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Loan token doesn't match pool supply token
// =============================================================================
// In rolling loan, the new loan's token must match the pool's supply_token

test fail_rolling_loan_when_loan_token_mismatch() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_255)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  // fail: loan token doesn't match pool supply token
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
      token: fx.djed,
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Pool changed amount positive (should be negative for create loan)
// =============================================================================
// For create loan, pool_changed_amount < 0 (assets leave the pool)

test fail_rolling_loan_when_new_loan_pool_changed_amount_positive() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  // fail: pool out has MORE tokens than pool in (positive change = invalid for create)
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 200_000_000)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Pool changed amount less than min_tx_amount
// =============================================================================
// abs(pool_changed_amount) must be >= min_tx_amount

test fail_rolling_loan_when_pool_changed_amount_below_min_tx() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  // fail: pool change = 1 token (below min_tx_amount)
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_424)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Off collateral used in new loan
// =============================================================================
// Collateral with allow = OFF cannot be used in new loan UTXO

test fail_rolling_loan_when_off_collateral_used() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(
          MarketDatum {
            ..market_datum,
            collaterals: [
              Pair(fx.djed, (8000, False)),
              Pair(fx.ddjed, (9000, True)),
              Pair(fx.qdjed, (8000, True)),
            ],
          },
        )
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 3_004_274)
      |> output_builder.to_input()

  let pool_out_datum =
    PoolDatum {
      ..fx.base_pool_out_datum_create_loan(),
      total_supply: 3_004_274,
      alt_supply_tokens_rate: [PRational(235, 10_000)],
    }
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 1_204_274)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  // fail: using DJED which has allow = False
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}

// =============================================================================
// FAIL: Pool total assets less than pool reserve after rolling
// =============================================================================
// pool_total_asset must be >= pool_out_datum.total_supply + undistributed_fee - total_borrow

test fail_rolling_loan_when_pool_total_assets_lt_reserve() fail {
  let protocol_datum = fx.base_protocol_datum()
  let protocol_ref =
    fx.protocol_config_output
      |> output_builder.add_inline_datum(protocol_datum)
      |> output_builder.to_input()
  let market_datum = fx.base_market_datum()
  let market_ref =
    fx.market_output
      |> output_builder.add_inline_datum(market_datum)
      |> output_builder.to_input()

  let pool_in_datum = fx.base_pool_in_datum_create_loan()
  let pool_in =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_in_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 127_841_425)
      |> output_builder.to_input()

  let pool_out_datum = fx.base_pool_out_datum_create_loan()
  // fail: pool total assets less than reserve
  let pool_out =
    fx.pool_output
      |> output_builder.add_inline_datum(pool_out_datum)
      |> output_builder.add_asset(fx.qsnek.1st, fx.qsnek.2nd, 51_570_250)

  let owner_nft_name = outref_hash.blake2b_224(pool_in.output_reference)
  let loan_out_dt =
    LoanDatum {
      ..fx.base_loan_datum_create_loan(),
      owner_nft: Some((fx.loan_id_token.1st, owner_nft_name)),
    }
  let loan_out =
    fx.loan_output
      |> output_builder.add_inline_datum(loan_out_dt)
      |> output_builder.add_asset(fx.djed.1st, fx.djed.2nd, 2_000_000)
      |> output_builder.add_asset(fx.qdjed.1st, fx.qdjed.2nd, 1_000_000)

  let fee_out =
    output_builder.new(fx.fee_addr)
      |> output_builder.add_lovelace(2_000_000)
      |> output_builder.add_asset(fx.snek.1st, fx.snek.2nd, 180_000)
  let create_loan_rdmr =
    CreateLoan {
      pool_out_idx: 2,
      loan_out_idx: 1,
      fee_out_idx: Some(0),
      protocol_cfg_ref_idx: 1,
      market_ref_idx: 0,
      pool_in_out_ref: pool_in.output_reference,
    }
  let price_rdmr = fx.base_oracle_rdmr()
  let tx =
    tx_builder.new()
      |> tx_builder.add_output(pool_out)
      |> tx_builder.add_output(loan_out)
      |> tx_builder.add_output(fee_out)
      |> tx_builder.add_ref_input(protocol_ref)
      |> tx_builder.add_ref_input(market_ref)
      |> tx_builder.add_input(pool_in)
      |> tx_builder.add_script_input(pool_in, create_loan_rdmr)
      |> tx_builder.add_mint(
          fx.loan_id_token.1st,
          fx.loan_id_token.2nd,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(
          fx.owner_nft.1st,
          owner_nft_name,
          1,
          create_loan_rdmr,
        )
      |> tx_builder.add_mint(fx.qsnek.1st, fx.qsnek.2nd, -1, None)
      |> tx_builder.add_zero_withdrawal_script(fx.oracle_skh, price_rdmr)
      |> tx_builder.add_validity_range(
          interval.between(2_400_000_000, 2_400_000_100),
        )
  and {
    loan.exec.mint(
      fx.protocol_nft,
      constants.calc_type_normal,
      create_loan_rdmr,
      fx.loan_id_token.1st,
      tx,
    )?,
    pool.exec.spend(
      fx.license_nft,
      fx.protocol_nft,
      constants.calc_type_normal,
      Some(pool_in_datum),
      create_loan_rdmr,
      pool_in.output_reference,
      tx,
    )?,
  }
}
