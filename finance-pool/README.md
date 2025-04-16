# Stacks Microloan Smart Contract

## Introduction
This decentralized finance (DeFi) smart contract implements a peer-to-peer microfinance platform on the Stacks blockchain. The contract allows STX holders to contribute to a collective lending pool and enables borrowers to access these funds through structured microloans with predefined interest rates, terms, and repayment schedules.

## Core Functionality
- **Pooled Lending System**: Contributors deposit STX into a shared lending pool
- **Flexible Loan Parameters**: Configurable loan amounts, interest rates, and durations
- **Automated Repayment Tracking**: System monitors payments and calculates obligations
- **Financial Incentives**: Rewards for early repayment and penalties for defaults
- **Risk Assessment**: Dynamic credit evaluation system for borrowers
- **Safety Mechanisms**: Administrative controls for emergency situations

## Technical Specifications

### Error Management
| Code | Description |
|------|-------------|
| ERR-NUMERIC-OVERFLOW (u100) | Mathematical calculation resulted in overflow |
| ERR-AMOUNT-INVALID (u101) | Requested amount outside permitted boundaries |
| ERR-BALANCE-INSUFFICIENT (u102) | Not enough funds available in the pool |
| ERR-LOAN-ALREADY-EXISTS (u103) | User already has an active loan |
| ERR-LOAN-NOT-REGISTERED (u104) | Referenced loan doesn't exist |
| ERR-UNAUTHORIZED-ACCESS (u105) | Operation restricted to authorized parties |
| ERR-TERM-INVALID (u106) | Loan duration outside acceptable parameters |
| ERR-INTEREST-RATE-INVALID (u107) | Specified interest rate not permitted |
| ERR-LOAN-PAST-DUE (u108) | Loan has exceeded its maturity date |
| ERR-LOAN-NOT-IN-ACTIVE-STATE (u109) | Operation requires an active loan |
| ERR-RECIPIENT-INVALID (u110) | Invalid destination for funds transfer |
| ERR-BORROWER-INELIGIBLE (u120) | Applicant doesn't meet lending criteria |
| ERR-LOAN-MAX-AMOUNT-EXCEEDED (u121) | Requested amount exceeds allowed maximum |
| ERR-NO-LOAN-ACTIVE (u122) | Operation requires an existing loan |
| ERR-EXTENSION-LIMIT-REACHED (u123) | Maximum number of extensions used |
| ERR-EARLY-REPAYMENT-PROCESSING (u124) | Issue with early repayment calculation |

### Loan Constraints
- **Loan Range**: 1-1,000 STX (u1000000 to u1000000000 micro-STX)
- **Term Range**: 7-365 days (approximated as block heights)
- **Standard APR**: 5% annually
- **Early Repayment Discount**: 2% of remaining principal
- **Maximum Extensions**: 3 per loan
- **Extension Fee**: 1% of outstanding balance

### Credit Evaluation Tiers
| Score | Classification | Description |
|-------|---------------|-------------|
| 100 | Excellent | Optimal repayment history |
| 80 | Good | Minor delays but reliable |
| 60 | Fair | Occasional missed payments |
| 40 | Poor | Significant repayment issues |
| 0 | Default | Non-performing loan status |

## Contract State Variables
- `is-contract-paused`: Emergency circuit breaker
- `lending-pool-balance`: Current available liquidity
- `outstanding-loan-count`: Active loan counter

## Data Models

### Loan Record Structure
```
{
  borrower-address: principal => {
    borrowed-amount: uint,         // Principal amount
    annual-interest-rate: uint,    // APR (scaled by 1,000,000)
    loan-creation-height: uint,    // Block when issued
    loan-maturity-height: uint,    // Due date in block height
    amount-repaid: uint,           // Total repaid to date
    loan-status: (string-ascii 20), // Current loan status
    credit-score: uint,            // Borrower's score
    recent-payment-height: uint    // Last payment block
  }
}
```

### Lender Record Structure
```
{
  lender-address: principal => {
    contribution-amount: uint,     // Total deposited
    deposit-block-height: uint     // Block of last deposit
  }
}
```

## Function Reference

### Lender Operations
- **deposit-to-lending-pool**
  - Parameters: `deposit-amount` (uint)
  - Description: Adds funds to the lending pool for distribution
  - Returns: Boolean success indicator

### Borrower Operations
- **apply-for-loan**
  - Parameters: `loan-amount` (uint), `duration-blocks` (uint)
  - Description: Requests loan issuance with specified terms
  - Returns: Boolean success indicator

- **submit-loan-payment**
  - Parameters: `payment-amount` (uint)
  - Description: Processes standard loan repayment
  - Returns: Boolean success indicator

- **make-early-repayment**
  - Parameters: `payment-amount` (uint)
  - Description: Completes loan ahead of schedule with discount
  - Returns: Boolean success indicator

### Loan Assessment Functions
- **check-borrower-eligibility**
  - Parameters: `borrower-address` (principal)
  - Description: Evaluates if applicant meets lending criteria
  - Returns: Success response or error code

- **determine-maximum-loan-amount**
  - Parameters: `borrower-address` (principal)
  - Description: Calculates borrowing capacity based on credit score
  - Returns: Maximum permitted loan amount

- **evaluate-loan-health**
  - Parameters: `borrower-address` (principal)
  - Description: Generates health score of existing loan
  - Returns: Numerical health assessment

### Administrative Controls
- **change-loan-status**
  - Parameters: `borrower-address` (principal), `updated-status` (string-ascii)
  - Description: Manually updates loan status
  - Returns: Boolean success indicator

- **pause-contract-operations**
  - Parameters: None
  - Description: Temporarily suspends all contract functions
  - Returns: Boolean success indicator

- **resume-contract-operations**
  - Parameters: None
  - Description: Reactivates suspended contract
  - Returns: Boolean success indicator

### Information Retrieval
- **calculate-interest-amount**
  - Parameters: `principal` (uint), `rate` (uint)
  - Description: Computes interest for specified amount and rate
  - Returns: Interest amount or error code

- **get-borrower-loan-details**
  - Parameters: `borrower-address` (principal)
  - Description: Retrieves comprehensive loan information
  - Returns: Complete loan record

- **get-lender-contribution**
  - Parameters: `lender-address` (principal)
  - Description: Retrieves lender's deposit information
  - Returns: Contribution record

- **get-lending-pool-balance**
  - Parameters: None
  - Description: Reports current pool liquidity
  - Returns: Available pool balance

## Implementation Details
The contract employs several technical safeguards:
- Arithmetic safety wrappers to prevent overflow/underflow
- Input validation across all parameters
- State-based operation restrictions
- Block height tracking for time-based calculations
- Access control restrictions for sensitive operations

## Loan Process Flow
1. **Pool Contribution**: Lenders deposit STX to the lending pool
2. **Application**: Borrowers request loans with desired terms
3. **Issuance**: Approved loans transfer funds to borrowers
4. **Repayment Phase**: Borrowers make payments according to terms
5. **Completion**: Loan fully repaid or defaults handled

## Implementation Examples

### Contributing to the Pool
```clarity
;; Deposit 15 STX to the lending pool
(contract-call? .microloan-protocol deposit-to-lending-pool u15000000)
```

### Requesting a Loan
```clarity
;; Request 8 STX loan for 60 days (approx. 8,640 blocks)
(contract-call? .microloan-protocol apply-for-loan u8000000 u8640)
```

### Making Payments
```clarity
;; Submit 2 STX payment toward existing loan
(contract-call? .microloan-protocol submit-loan-payment u2000000)
```

### Early Loan Settlement
```clarity
;; Pay remaining balance with early repayment discount
(contract-call? .microloan-protocol make-early-repayment u6500000)
```

## Security Considerations
- Contract administrator has emergency control capabilities
- Mathematical operations include comprehensive safety checks
- Parameter boundaries prevent extreme values
- Strict authorization controls on all sensitive functions
- State validation prevents inappropriate operation sequencing