# Rolling Loans — Milestone 1 Resubmission Evidence

Project: Rolling Loans: Continuous Borrowing on Danogo  
Milestone: Milestone 1 — Smart Contract Development  
Project ID: 1400107

This repository contains the Milestone 1 resubmission evidence package.

The evidence is organized according to the Milestone 1 Evidence of Completion items:

1. Detailed test results
2. Technical report describing test scenarios
3. Testnet deployment/reference transaction evidence
4. Preview/Preprod transaction IDs demonstrating functionality

## Evidence Files

### 1. Detailed Test Results

File: [`01_Detailed_Test_Results_M1.pdf`](./01_Detailed_Test_Results_M1.pdf)

This document maps each test scenario to the expected result, actual transaction evidence, before/after state comparison, and pass/fail status.

### 2. Technical Report Describing Test Scenarios

File: [`02_Technical_Report_Test_Scenarios_M1.pdf`](./02_Technical_Report_Test_Scenarios_M1.pdf)

This report explains the tested rolling-loan state transition, including the Float Loan SC to Leverage Loan SC refinancing path, interest-index handling, pool accounting updates, and collateral transfer logic.

### 3. Testnet Deployment Transactions

File: [`03_Testnet_Deployment_Transactions_M1.pdf`](./03_Testnet_Deployment_Transactions_M1.pdf)

This document lists the deployment/reference transaction evidence for the smart contracts used in the Milestone 1 validation flow.

### 4. Preview Transaction IDs Demonstrating Functionality

File: [`04_Preview_Transaction_IDs_Functionality_Proof_M1.pdf`](./04_Preview_Transaction_IDs_Functionality_Proof_M1.pdf)

This document maps the primary rolling-loan execution transaction to the tested functionality.

Primary rolling-loan transaction:

`b09fa33a42fda235b28be38b58f1daab764e3dfb58768b9506a3c9d5ba5e851f`

Cardanoscan:

https://preprod.cardanoscan.io/transaction/b09fa33a42fda235b28be38b58f1daab764e3dfb58768b9506a3c9d5ba5e851f

### 5. Reviewer Checklist

File: [`05_Reviewer_Checklist_M1.pdf`](./05_Reviewer_Checklist_M1.pdf)

This checklist helps reviewers quickly locate where each Milestone 1 evidence requirement is addressed.

## Supporting Documents

Business specification:

[`docs/Business_Specifications.md`](./docs/Business_Specifications.md)

## Supporting Screenshots

The `screenshots/` folder contains visual references for:

- rolling-loan transaction overview
- source loan input datum before migration
- target loan output datum after migration

Files:

- [`screenshots/tx_rolling_loan_overview.png`](./screenshots/tx_rolling_loan_overview.png)
- [`screenshots/datum_before_input.png`](./screenshots/datum_before_input.png)
- [`screenshots/datum_after_output.png`](./screenshots/datum_after_output.png)

## Demo Video

https://www.youtube.com/watch?v=1eG3JKXwskM&t=9s

## Main Transaction Links

Float Pool Script:  
https://preprod.cardanoscan.io/transaction/2709db63040f43cd5eb4bc10b571b71ecf9d3ed94b870895331452ad4571cc2a

Float Loan Script:  
https://preprod.cardanoscan.io/transaction/a8ecefa50e47e4084ad3085b99093b56d5e8c48b55a4641748a700d31e48a96b

Leverage Pool Script:  
https://preprod.cardanoscan.io/transaction/d9cf6b2d222eaf86afd97de6e0f150ec252031a8c6dbac9253d99f45d883a837

Leverage Loan Script:  
https://preprod.cardanoscan.io/transaction/d8dc1fcc5fcec28d043b7658797b081c85bdbd42140839d5bab0c58cb7b000f6

Rolling Loan Execution Transaction:  
https://preprod.cardanoscan.io/transaction/b09fa33a42fda235b28be38b58f1daab764e3dfb58768b9506a3c9d5ba5e851f