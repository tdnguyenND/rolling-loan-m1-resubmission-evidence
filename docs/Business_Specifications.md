# Business Constraints for Rolling Loan

## Table of Contents
- [Objective](#objective)
- [Rolling Loan Strategy & Lifecycle](#rolling-loan-strategy--lifecycle)
- [Functional Design: Fixed vs. Floating Pools](#functional-design-fixed-vs-floating-pools)
- [Maturity Update Handling & Rollover Logic](#maturity-update-handling--rollover-logic)
- [Variables list](#variables-list)
   - [Constant](#constant)
   - [Market param](#market-param)
   - [Temporary](#temporary)
   - [Pool UTXO datum](#pool-utxo-datum)
   - [Loan UTXO datum](#loan-utxo-datum)
- [Redeemer of Flexible Pool](#redeemer-of-flexible-pool)
   - [Redeemer: Create Loan](#redeemer-create-loan)
   - [Redeemer: Repay Loan](#redeemer-repay-loan)

# Objective
This document defines the business logic and constraints of the smart contract for the Rolling Loan mechanism on Danogo.

The objective of this feature is to enable borrowers to:
- Extend or refinance their loan positions (fixed and floating) without fully repaying the debt.
- Maintain continuous borrowing exposure without idle collateral.
- Carry forward accrued interest seamlessly into a new loan.

The system allows a borrower to transition from an existing loan to a new loan position within a single transaction, ensuring seamless continuation of the borrowing lifecycle.

# Rolling Loan Strategy & Lifecycle (States and Transitions)

Rolling loan is implemented as a seamless **state transition** within a single transaction between two loan positions:
**State 1: Existing Active Loan** -> **State 2: Transition (Rollover)** -> **State 3: New Active Loan**

During the Rollover (State 2):
1. **Create Loan**: A new loan is originated, borrowing funds from the Pool.
2. **Repay Loan**: The newly borrowed amount is used to immediately pay off the outstanding debt (principal + interest) of the Existing Loan.
3. **Collateral Transfer**: Collateral from the Existing Loan is redirected entirely into the New Loan without being unlocked to the user's wallet.

*Triggers for Rollover*: 
- Approaching maturity (for fixed loans) or strategic refinancing (changing terms/pools). Any borrower can trigger this using their Loan Owner NFT.

This process ensures:
- No idle collateral
- No interruption in borrowing
- Improved capital efficiency

# Functional Design: Fixed vs. Floating Pools
The Rolling Loan smart contract dynamically supports both Floating (Variable) and Fixed interest mechanics through configured parameters.

- **Floating Loan Pools**: Interest rates adjust dynamically utilizing the `power_base` adjustment factor and the pool's overarching `util_rate`. The Smart Contract continuously updates the `interest_index` using the newly defined utilization percentage at each interaction block.
- **Fixed Loan Pools**: Achieved by setting `power_base = 0` or freezing the `borrow_apy` equivalent through specific constant Market Parameters. For these pools, the rollover locks a guaranteed rate matching the baseline `base_rate` without variance during the loan term. 

# Maturity Update Handling & Rollover Logic
When a rollover event is triggered:
1. **Accrued Interest Settlement**: The system recalculates `current_interest_index` based on the elapsed time between `pool_in_datum.interest_time` and the current transaction time.
2. **Maturity Baseline Reset**: For the new loan, the `loan_out_datum.initial_interest_index` is strictly bound to the updated `pool_out_datum.interest_index`. This resets the maturity curve baseline, cleanly segmenting the old debt ledger from the new term without double-counting interest.
3. **Timestamp Update**: The pool's `interest_time` advances to the execution block time, ensuring correct timeline boundaries for future interest.

# Variables list 

## Constant
| No. | Variables name       | Description                      |
| --- | -------------------- | -------------------------------- |
| 1   | basis                | Basis point (bps) is used to store interest rates as integers on-chain, ensuring accuracy up to two decimal places.<br> 1 = 100% = 10,000 bps <br>  0.04 = 4% = 400 bps <br> 0.1025 = 10.25% = 1,025 bps        |
| 2   | year_in_ms           | Time of 1 year converted to milliseconds <br> year_in_ms = 365 * 24 * 60 * 60 * 1000 = 31,536,000,000  |
| 3   | min_ada              | The minimum amount of ADA required to include a UTXO.|

## Market param
| No. | Variables name                                | Description                                          |
| --- | --------------------------------------------- | --------------------------------------------------------- |
| 1   | supply_token                                  | Native token that allows the supply of the pool                                                                                                                                                                                                                                |
| 2   | base_rate                                     | The annual base interest rate that the borrower is required to pay. Stored in bps, e.g., a base rate of 4% is stored as 400 bps                                                                                                                                                |
| 3   | power_base                                    | power_base is an adjustment factor that determines how the borrow interest rate increases as the utilization rate rises. <br> power_base is stored as basis point. E.g., power_base = 1.047 is stored as 10,470 bps                                                            |
| 4   | loan_fee_rate                                 | Protocol fee rate from borrower interest, stored in bps. E.g., loan_fee_rate = 20% is stored as 2,000 bps                                                                                                                                                                      |
| 5   | util_cap                                      | Utilization cap is the maximum borrowing limit in a pool (to protect liquidity), e.g., the DJED pool allows up to 85% utilization, and stored in bps as 8,500                                                                                                                  |
| 6   | loan_origination_fee_rate                     | Borrower fee paid to the platform in the borrowed asset. Stored in bps. Currently set to 0 as Float does not charge this fee.                                                                                                                                                  |
| 7   | collaterals: Pairs<Token, (Threshold, allow)> | Tokens accepted as collateral for borrowing the native token <br> Liquidation threshold for each collateral. <br> `allow` is a flag, When set to ON, it permits the collateral to be used in the Loan Out UTxO. When set to OFF, the collateral is not allowed to be used in the Loan Out UTxO but it will still be counted toward the Health Factor (HF) of existing loans<br>. E.g., You can borrow ADA up to 80% of your DJED collateral. If the collateral value falls below 80%, the loan will be liquidated. Threshold is stored in bps. |
| 8   | min_tx_amount                                 | The minimum tokens in all transactions (topup, withdraw, create loan, increase loan, decrease loan, repay)                                                                                                                                                                      |
| 9   | loan_origination_fee_min_amount               | Minimum fee charged when creating a loan, Default: 0 |  

## Pool UTXO datum
| No. | Variables name         | Description                       |
| --- | ---------------------- | --------------------------------- |
| 1   | interest_index         | Total pool assets of pool, including principal & accrued interest from loans, principal & interest from supply in other protocols (e.g., Liqwid), minus platform fees.<br> If total_supply < 0 then set total_supply = 0. <br> Default value: 1,000,000,000,000      |
| 2   | total_supply           | Total pool assets of pool, including principal & accrued interest from loans, principal & interest from supply in other protocols (e.g., Liqwid), minus platform fees. <br> If total_supply < 0 then set total_supply = 0, <br>  Default value: 0 |
| 3   | total_borrow           | Total loan amount, including interest, that the borrower must repay at the current time. <br> If total_borrow < 0 then set total_borrow = 0, <br> Default value: 0 |
| 4   | borrow_apy             | Annual interest rate that the borrower must pay, stored in bps. E.g., borrow_apy = 10.05% is stored as 1005 bps. <br>  Default value: To be decided  |
| 5   | undistributed_fee      | Platform fees accrued but not yet transferred to the platform wallet. <br>. Default value: 0 |
| 6   | interest_time          | Records the last time the system updated the interest rate. Based on this timestamp, the platform can calculate the elapsed time since the previous update to determine the accumulated interest for loan. <br> Default value: null |

## Loan UTXO datum

| No. | Variables name         | Description                       |
| --- | ---------------------- | --------------------------------- |
| 1   | initial_interest_index | Initial interest_index value      |
| 2   | loan_amount            | Value of loan (included interest) |
| 3   | owner_nft              | This NFT determines who the loan owner is |
| 4   | token                  | This is the token the borrower wants to borrow |

## Temporary
### 1. new_accumulated_interest:
- Accumulated interest of all loans from the last transaction to current transaction

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{new\_accumulated\_interest}%20=%20\text{floor}%20(\text{pool\_in\_datum.total\_borrow}%20*%20(\frac{\text{pool\_out\_datum.interest\_index}}{\text{pool\_in\_datum.interest\_index}}%20-%201))"/></p>  

### 2. new_loan_interest_fee: 
- Accumulated platform fee taken as a portion of loan interest accrued from the last transaction to the current transaction.   

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{new\_loan\_interest\_fee}%20=%20\text{ceiling}%20\left(%20\text{new\_accumulated\_interest}%20*%20\frac{\text{market\_param.loan\_fee\_rate}}{\text{basis}}%20\right)"/></p>  

### 3. pool_changed_amount: 
- Total value of asset changes of the pool in the current transaction

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{pool\_changed\_amount}%20=%20\text{pool\_out\_asset.supply\_token}%20-%20\text{pool\_in\_asset.supply\_token}"/></p>  

### 4. util_rate:
- Utilization ratio is total borrow over total supply  

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{util\_rate}%20=%20\frac{\text{pool\_out\_datum.total\_borrow}}{\text{pool\_out\_datum\_total\_supply}}"/></p>  

### 5. total_supply_before_transaction:
- Total pool assets calculated before the transaction, including principal & accrued interest from loans, principal & interest from   supply in other protocols (e.g., Liqwid), minus undistributed platform fees. This is also used as numerator of dtoken_rate  

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{total\_supply\_before\_transaction}%20=%20\text{pool\_in\_datum.total\_supply}%20+%20\text{new\_accumulated\_interest}%20-%20\text{new\_loan\_interest\_fee}"/></p>  

### 6. total_collateral_val_with_threshold:
- The total value of collaterals with threshold, that are locked in the loan  

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{total\_collateral\_val\_with\_threshold}%20=%20sum(floor(\text{loan\_out\_asset.collateral}[i]%20*%20\frac{\text{oracle.rate\_num}[i]}{\text{oracle.rate\_denom}[i]}%20*%20\frac{\textbf{market\_param.threshold}[i]}{\text{basis}}))"/></p>  

### 7. pool_total_asset:
- Total actual assets in the pool, including the supply token and alternative supply tokens converted to the supply token.   

<p align="center"><img src="https://latex.codecogs.com/gif.latex?pool\_total\_asset%20=%20pool\_out\_asset.supply\_token%20+%20\sum%20(floor(pool\_out\_asset.alt\_supply\_token%20*%20\frac{oracle.alt\_supply\_token\_rate\_num}{oracle.alt\_supply\_token\_rate\_denom}))"/></p>  

### 8. current_interest_index: 
- Interest_index is a scaling factor used to track the cumulative growth of interest over time. It ensures that interest is compounded continuously and is used to determine how much interest borrowers owe and how much lenders earn 

<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{current\_interest\_index}%20=%20\text{floor}%20(\text{pool\_in\_datum.interest\_index}%20+%20\text{pool\_in\_datum.interest\_index}%20*%20\frac{\text{pool\_in\_datum.borrow\_apy}}{\text{basis}}%20*%20\frac{(\text{txn\_time}%20-%20\text{pool\_in\_datum.interest\_time})}{\text{year\_in\_ms}})"/></p>  

### 9. current_loan_amount:
- The loan debt includes accumulated interest up to the current transaction
<p align="center"><img src="https://latex.codecogs.com/gif.latex?current\_loan\_amount%20=%20\text{floor}%20(\frac{\text{loan\_in\_datum.loan\_amount}%20*%20\text{current\_interest\_index}}{\text{loan\_in\_datum.initial\_interest\_index}})"/></p>  

### 10. current_borrow_apy:
- Annual interest rate that the borrower must pay in this current transaction, stored in bps. E.g., borrow_apy = 10.05% is stored as 1005 bps
<p align="center"><img src="https://latex.codecogs.com/gif.latex?\text{current\_borrow\_apy}%20=%20\text{floor}%20\left(%20\left(%20\frac{\text{market\_param.power\_base}}{\text{basis}}%20\right)^{\text{round}(\text{util\_rate}%20*%20100)}%20*%20100%20\right)%20+%20\text{market\_param.base\_rate}"/></p>  

if pool_out_datum.total_supply = 0 then current_borrow_apy = base_rate

### 11. loan_origination_fee  
- Fee charged by the platform when creating or increasing a loan.
<p align="center"><img src="https://latex.codecogs.com/gif.latex?loan\_origination\_fee%20=%20max({ceiling}%20(%20(loan\_out\_datum.loan\_amount%20-%20current\_loan\_amount)%20*%20\frac{{market\_param.loan\_origination\_fee\_rate}}{{basis}}%20),%20market\_param.loan\_origination\_fee\_min\_amount)"/></p>  

---------------------------------------------------------------------------------
## Redeemer: Create Loan
### 1. Objectives
- Allow borrowers to open a new loan using collateral
- Enable integration with rolling loan mechanism
- Support cross-contract refinancing (SC1 → SC2). 

#### Business Description
Create Loan is responsible for initializing a new borrowing position.
In the rolling loan mechanism:
- A new loan is created with a fresh interest baseline  
- The borrowed amount is used to settle an existing loan  
- Collateral from the previous loan is transferred into the new loan  

This allows the borrower to continue their position without requiring manual repayment or collateral withdrawal.

### 2. Constraints
* Anyone can create a new loan

#### 2.1. Loan UTXO
##### 2.1.1. Asset of Loan UTXO
1. The total value of collaterals with threshold locked in this loan must be greater than the debt value (including accumulated interest)
   ```python
   total_collateral_val_with_threshold > loan_out_datum.loan_amount
   ```

2. The loan only accepts collaterals configured in the corresponding market parameters and `allow` = ON, and ADA is required to maintain the loan UTXO

##### 2.1.2. Datum of Loan UTXO

1. Ensure that the loan amount correctly reflects the borrowed value from the pool, including any applicable origination fee.  
loan_out_datum.loan_amount = - pool_changed_amount + loan_origination_fee  

2. Ensure that the loan starts with the current interest index so that future interest accrual is calculated correctly.  
loan_out_datum.initial_interest_index = pool_out_datum.interest_index  

3. Ensure that the loan ownership is correctly assigned to the borrower through the owner NFT.  
loan_out_datum.owner_nft: owner_nft must match the borrower's loan owner nft

4. Ensure that the borrowed asset matches the pool configuration and prevents borrowing unsupported tokens.  
loan_out_datum.token: token must be supply_token was configured in market_param_datum


#### 2.2. Pool UTXO
The loan is created by borrowing assets directly from the pool. Therefore, it is required to validate both the asset balances and the datum state of the Pool UTXO to ensure consistency and correctness of the system.

These constraints ensure that:

- The pool has sufficient liquidity to fulfill the borrowing request  
- The pool accounting (total supply, total borrow, and interest) is correctly updated  
- The transaction does not violate protocol-level rules such as utilization limits  

By enforcing these conditions, the system guarantees that every new loan is backed by valid pool state transitions and does not compromise the integrity of the lending pool.

##### 2.2.1. asset
1. The total assets in the pool (configured in the current market param) must be greater than or equal to the amount recorded in the pool datum.  
   ```python
   pool_total_asset >= pool_out_datum.total_supply + pool_out_datum.undistributed_fee - pool_out_datum.total_borrow
   ```

2. The total value of asset changes of the pool in the current transaction must decrease 
   ```python
   pool_changed_amount < 0
   ```
3. The total value of asset changes of the pool in the current transaction must be greater than or equal to the minimum transaction amount
   ```python
   abs(pool_changed_amount) >= min_tx_amount
   ```


##### 2.2.2. datum

1. Ensure that the pool interest index is updated to reflect the latest accrued interest before applying the transaction.  
pool_out_datum.interest_index = current_interest_index

2. Ensure that the total supply is updated to include all accumulated interest and reflect the pool state before this transaction.  
pool_out_datum.total_supply = total_supply_before_transaction

3. Ensure that total borrow reflects both previously accrued interest and the newly created loan amount.  
pool_out_datum.total_borrow = pool_in_datum.total_borrow + new_accumulated_interest + loan_out_datum.loan_amount

4. Ensure that the borrow interest rate is updated based on the current utilization of the pool.  
pool_out_datum.borrow_apy = current_borrow_apy

5. Ensure that platform fees include both newly accrued interest fees and loan origination fees from this transaction.  
pool_out_datum.undistributed_fee = pool_in_datum.undistributed_fee + new_loan_interest_fee + loan_origination_fee

6. Ensure that the timestamp is updated to mark the start of interest calculation for the next period.  
pool_out_datum.interest_time = start time of current transaction


#### 2.3. Other constraints
1. The loan must not exceed the utilization cap configured in the market parameters of this pool
```python
   market_param.util_cap > pool_out_datum.total_borrow/ pool_out_datum.total_supply * basis
```


---------------------------------------------------------------------------
##  Redeemer: Repay Loan
### 1. Objectives
- Allow users to repay an existing loan
- Enable closing of a loan during refinancing
- Release collateral for reuse

#### Business Description
Repay Loan is responsible for reducing or closing an existing loan position.
In the rolling loan mechanism:
- The existing loan is repaid using funds from the new loan
- The loan is closed within the same transaction
- Collateral is released and immediately reused
This enables seamless transition between loan positions without requiring external user funds.


### 2. Constraints
- The loan owner is allowed to repay their loan either partially or fully, ensuring flexibility in managing their debt position.
    - In the context of the rolling loan mechanism, this redeemer is primarily used for full repayment, where the entire outstanding debt is settled using funds from a newly created loan.
    - However, the redeemer is designed to support partial repayment as well, allowing the system to be more flexible and extensible for future use cases such as incremental debt reduction or advanced refinancing strategies.

#### 2.1. Loan UTXO
The Loan UTXO represents the borrower’s debt position after repayment.

- In case of **full repayment**, the loan is completely closed and no Loan UTXO is created in the output.  
  Therefore, no Loan UTXO validation is required, and the repayment amount must equal the total outstanding debt.

- In case of **partial repayment**, the Loan UTXO remains and must be validated to ensure the updated loan state is correct.

```python
If no Loan UTXO output (full repayment):
    pool_change_amount = current_loan_amount
Else (partial repayment):
    pool_change_amount >= min_tx_amount
```

##### 2.1.1. Asset of Loan UTXO
1. The total value of collaterals with threshold for in this loan must be greater than the debt value (including accumulated interest)
   ```python
   total_collateral_val_with_threshold > loan_out_datum.loan_amount
   ```
2. The loan only accepts collaterals configured in the corresponding market parameters `allow` = ON, and ADA is required to maintain the loan UTXO

##### 2.1.2. Datum of Loan UTXO
1. The remaining loan amount must be greater than zero.
loan_out_datum.loan_amount > 0

2. The loan amount must be updated to reflect the remaining debt after repayment.
loan_out_datum.loan_amount = current_loan_amount - pool_change_amount

3. The initial interest index must be reset to the current pool interest index. Ensures future interest is calculated from the updated state without double-counting past interest.  
loan_out_datum.initial_interest_index = pool_out_datum.interest_index

4. The loan ownership must remain unchanged. Ensures the same borrower retains control of the loan position.  
loan_out_datum.owner_nft = loan_in_datum.owner_nft

5. The loan token must remain unchanged. Ensures consistency between the loan asset and the pool configuration. 
loan_out_datum.token = loan_in_datum.token


#### 2.2. Pool UTXO
The Pool UTXO represents the source of liquidity and the global accounting state of the lending system.  
During repayment, assets are returned to the pool, so it is critical to validate the Pool UTXO to ensure that:

- The repaid assets are transferred back to the correct pool  
- The amount returned matches the expected repayment value  
- The pool accounting (total supply, total borrow, and interest) is updated consistently  

These constraints guarantee that the repayment process correctly updates the pool state and does not introduce inconsistencies or loss of funds.

##### 2.2.1. Asset of Pool UTXO
1. The total assets in the pool (configured in the current market param) must be greater than or equal to the amount recorded in the pool datum.  
   ```python
   pool_total_asset >= pool_out_datum.total_supply + pool_out_datum.undistributed_fee - pool_out_datum.total_borrow
   ```

2. The total value of asset changes must not decrease
   ```python
   pool_changed_amount >= 0
   ```


##### 2.2.2. Datum of Pool UTXO

1. The interest index must be updated to the current value before applying repayment. Ensures that all accrued interest is accounted for prior to updating the pool state.  
   pool_out_datum.interest_index = current_interest_index

2. The total supply must include all accumulated interest before the transaction. Ensures that the pool reflects the correct total asset value, including interest earned from loans.  
   pool_out_datum.total_supply = total_supply_before_transaction

3. The total borrow must be reduced according to the repayment amount while including newly accrued interest. Ensures that the outstanding debt in the system is accurately updated after repayment.  
   pool_out_datum.total_borrow = pool_in_datum.total_borrow + new_accumulated_interest - pool_change_amount

4. The borrow interest rate must be updated based on the latest pool utilization. Ensures that future interest calculations reflect the current state of supply and borrow.  
   pool_out_datum.borrow_apy = current_borrow_apy

5. The undistributed fee must include the newly accrued interest fee. Ensures that platform fees are correctly accumulated and not lost during the repayment process.  
   pool_out_datum.undistributed_fee = pool_in_datum.undistributed_fee + new_loan_interest_fee

6. The interest timestamp must be updated to the current transaction time. Ensures that future interest accrual is calculated from the correct starting point.  
   pool_out_datum.interest_time = start time of current transaction
