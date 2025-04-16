;; Stacks Microloan Smart Contract

;; ERROR CONSTANTS
(define-constant ERR-NUMERIC-OVERFLOW (err u100))
(define-constant ERR-AMOUNT-INVALID (err u101))
(define-constant ERR-BALANCE-INSUFFICIENT (err u102))
(define-constant ERR-LOAN-ALREADY-EXISTS (err u103))
(define-constant ERR-LOAN-NOT-REGISTERED (err u104))
(define-constant ERR-UNAUTHORIZED-ACCESS (err u105))
(define-constant ERR-TERM-INVALID (err u106))
(define-constant ERR-INTEREST-RATE-INVALID (err u107))
(define-constant ERR-LOAN-PAST-DUE (err u108))
(define-constant ERR-LOAN-NOT-IN-ACTIVE-STATE (err u109))
(define-constant ERR-RECIPIENT-INVALID (err u110))
(define-constant ERR-BORROWER-INELIGIBLE (err u120))
(define-constant ERR-LOAN-MAX-AMOUNT-EXCEEDED (err u121))
(define-constant ERR-NO-LOAN-ACTIVE (err u122))
(define-constant ERR-EXTENSION-LIMIT-REACHED (err u123))
(define-constant ERR-EARLY-REPAYMENT-PROCESSING (err u124))
(define-constant ERR-INVALID-STATUS (err u125))
(define-constant ERR-INVALID-ADDRESS (err u126))

;; CONTRACT CONFIGURATION CONSTANTS
(define-constant contract-administrator tx-sender)
(define-constant daily-block-count u144) ;; approximately 144 blocks per day on Stacks
(define-constant loan-amount-minimum u1000000) ;; 1 STX minimum
(define-constant loan-amount-maximum u1000000000) ;; 1000 STX maximum
(define-constant loan-term-minimum (* daily-block-count u7)) ;; Minimum 7 days
(define-constant loan-term-maximum (* daily-block-count u365)) ;; Maximum 365 days

;; LOAN HEALTH STATUS CONSTANTS
(define-constant health-score-excellent u100)
(define-constant health-score-good u80)
(define-constant health-score-fair u60)
(define-constant health-score-poor u40)
(define-constant health-score-default u0)

;; LOAN PARAMETER CONSTANTS
(define-constant extension-limit-maximum u3)
(define-constant extension-fee-percentage u10000) ;; 1% fee for extension
(define-constant early-payment-discount-rate u20000) ;; 2% discount for early repayment

;; CONTRACT STATE VARIABLES
(define-data-var is-contract-paused bool false)
(define-data-var lending-pool-balance uint u0)
(define-data-var outstanding-loan-count uint u0)

;; DATA STRUCTURES
(define-map active-loans
    { borrower-address: principal }
    {
        borrowed-amount: uint,
        annual-interest-rate: uint,
        loan-creation-height: uint,
        loan-maturity-height: uint,
        amount-repaid: uint,
        loan-status: (string-ascii 20),
        credit-score: uint,
        recent-payment-height: uint
    }
)

(define-map lender-contributions
    { lender-address: principal }
    { 
        contribution-amount: uint,
        deposit-block-height: uint
    }
)

;; Valid loan statuses
(define-data-var valid-statuses (list 5 (string-ascii 20)) (list "ACTIVE" "COMPLETED" "DEFAULT" "OVERDUE" "CLOSED"))

;; ARITHMETIC SAFETY FUNCTIONS
(define-private (add-with-overflow-check (first-value uint) (second-value uint))
    (let ((result-sum (+ first-value second-value)))
        (if (>= result-sum first-value)
            (ok result-sum)
            ERR-NUMERIC-OVERFLOW))
)

(define-private (subtract-with-overflow-check (minuend uint) (subtrahend uint))
    (if (>= minuend subtrahend)
        (ok (- minuend subtrahend))
        ERR-NUMERIC-OVERFLOW)
)

(define-private (divide-safely (dividend uint) (divisor uint))
    (if (> divisor u0)
        (ok (/ dividend divisor))
        ERR-AMOUNT-INVALID)
)

;; VALIDATION FUNCTIONS
(define-private (validate-loan-amount (amount uint))
    (and 
        (>= amount loan-amount-minimum)
        (<= amount loan-amount-maximum)
    )
)

(define-private (validate-loan-term (blocks uint))
    (and 
        (>= blocks loan-term-minimum)
        (<= blocks loan-term-maximum)
    )
)

(define-private (validate-interest-rate (rate uint))
    (and 
        (> rate u0)
        (<= rate u1000000) ;; Max 100% APR represented as 1000000/1000000
    )
)

;; Validate if a given status is in the list of valid statuses
(define-private (validate-loan-status (status (string-ascii 20)))
    (is-some (index-of (var-get valid-statuses) status))
)

;; Validate borrower address
(define-private (validate-borrower-address (address principal))
    (and 
        (not (is-eq address (as-contract tx-sender)))  ;; Address should not be the contract itself
        (not (is-eq address contract-administrator))   ;; Address should not be the administrator
        (is-some (map-get? active-loans { borrower-address: address })) ;; Address should have an active loan
    )
)

;; Enhanced address validation for admin functions
(define-private (validate-address-for-admin (address principal))
    (and 
        (not (is-eq address (as-contract tx-sender)))  ;; Address should not be the contract itself
        (not (is-eq address contract-administrator))   ;; Address should not be the administrator
    )
)

(define-read-only (check-contract-status)
    (not (var-get is-contract-paused))
)

;; LENDER FUNCTIONS
(define-public (deposit-to-lending-pool (deposit-amount uint))
    (begin
        (asserts! (check-contract-status) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (> deposit-amount u0) ERR-AMOUNT-INVALID)
        (asserts! (validate-loan-amount deposit-amount) ERR-AMOUNT-INVALID)

        (let ((updated-pool-total (try! (add-with-overflow-check (var-get lending-pool-balance) deposit-amount))))
            (asserts! (<= updated-pool-total loan-amount-maximum) ERR-NUMERIC-OVERFLOW)

            (try! (stx-transfer? deposit-amount tx-sender (as-contract tx-sender)))

            (let ((current-lender-share (default-to 
                    { contribution-amount: u0, deposit-block-height: u0 } 
                    (map-get? lender-contributions { lender-address: tx-sender }))))

                (let ((new-contribution-amount (try! (add-with-overflow-check 
                      (get contribution-amount current-lender-share) deposit-amount))))
                    (map-set lender-contributions
                        { lender-address: tx-sender }
                        { 
                            contribution-amount: new-contribution-amount,
                            deposit-block-height: block-height
                        }
                    )

                    (var-set lending-pool-balance updated-pool-total)
                    (ok true)
                )
            )
        )
    )
)

;; BORROWER FUNCTIONS
(define-public (apply-for-loan (loan-amount uint) (duration-blocks uint))
    (let (
        (borrower-address tx-sender)
        (current-block-height block-height)
        (loan-end-height (+ current-block-height duration-blocks))
    )
        (asserts! (check-contract-status) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (not (is-eq borrower-address (as-contract tx-sender))) ERR-RECIPIENT-INVALID)

        (asserts! (validate-loan-amount loan-amount) ERR-AMOUNT-INVALID)
        (asserts! (validate-loan-term duration-blocks) ERR-TERM-INVALID)
        (asserts! (<= loan-amount (var-get lending-pool-balance)) ERR-BALANCE-INSUFFICIENT)
        (asserts! (is-none (map-get? active-loans { borrower-address: borrower-address })) ERR-LOAN-ALREADY-EXISTS)

        (try! (stx-transfer? loan-amount (as-contract tx-sender) borrower-address))

        (let (
            (updated-pool-balance (try! (subtract-with-overflow-check (var-get lending-pool-balance) loan-amount)))
            (updated-loan-count (try! (add-with-overflow-check (var-get outstanding-loan-count) u1)))
        )
            (map-set active-loans
                { borrower-address: borrower-address }
                {
                    borrowed-amount: loan-amount,
                    annual-interest-rate: u50000, ;; 5% represented as 50000/1000000
                    loan-creation-height: current-block-height,
                    loan-maturity-height: loan-end-height,
                    amount-repaid: u0,
                    loan-status: "ACTIVE",
                    credit-score: u100,
                    recent-payment-height: current-block-height
                }
            )

            (var-set lending-pool-balance updated-pool-balance)
            (var-set outstanding-loan-count updated-loan-count)
            (ok true)
        )
    )
)

(define-public (submit-loan-payment (payment-amount uint))
    (let (
        (borrower-address tx-sender)
        (loan-details (unwrap! (map-get? active-loans { borrower-address: borrower-address }) ERR-LOAN-NOT-REGISTERED))
        (current-block-height block-height)
    )
        (asserts! (check-contract-status) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (> payment-amount u0) ERR-AMOUNT-INVALID)
        (asserts! (is-eq (get loan-status loan-details) "ACTIVE") ERR-LOAN-NOT-IN-ACTIVE-STATE)
        (asserts! (<= current-block-height (get loan-maturity-height loan-details)) ERR-LOAN-PAST-DUE)

        (let (
            (updated-repaid-amount (try! (add-with-overflow-check (get amount-repaid loan-details) payment-amount)))
            (elapsed-blocks (- current-block-height (get loan-creation-height loan-details)))
            (total-blocks (- (get loan-maturity-height loan-details) (get loan-creation-height loan-details)))
            (prorated-interest (try! (calculate-prorated-interest 
                                    (get borrowed-amount loan-details) 
                                    (get annual-interest-rate loan-details)
                                    elapsed-blocks
                                    total-blocks)))
            (total-obligation (try! (add-with-overflow-check (get borrowed-amount loan-details) prorated-interest)))
        )
            (try! (stx-transfer? payment-amount borrower-address (as-contract tx-sender)))

            (map-set active-loans
                { borrower-address: borrower-address }
                (merge loan-details {
                    amount-repaid: updated-repaid-amount,
                    recent-payment-height: current-block-height,
                    loan-status: (if (>= updated-repaid-amount total-obligation)
                        "COMPLETED"
                        "ACTIVE"
                    )
                })
            )

            (var-set lending-pool-balance (try! (add-with-overflow-check (var-get lending-pool-balance) payment-amount)))

            (if (>= updated-repaid-amount total-obligation)
                (var-set outstanding-loan-count (try! (subtract-with-overflow-check (var-get outstanding-loan-count) u1)))
                true
            )

            (ok true)
        )
    )
)

;; READ-ONLY FUNCTIONS
(define-read-only (calculate-interest-amount (principal uint) (rate uint))
    (begin
        (asserts! (validate-interest-rate rate) ERR-INTEREST-RATE-INVALID)
        (divide-safely (* principal rate) u1000000)
    )
)

(define-read-only (calculate-prorated-interest (principal uint) (rate uint) (elapsed-blocks uint) (total-blocks uint))
    (begin
        (asserts! (validate-interest-rate rate) ERR-INTEREST-RATE-INVALID)
        (asserts! (> total-blocks u0) ERR-TERM-INVALID)
        (asserts! (<= elapsed-blocks total-blocks) ERR-LOAN-PAST-DUE)
        
        (let (
            (full-interest (try! (calculate-interest-amount principal rate)))
            (prorated (/ (* full-interest elapsed-blocks) total-blocks))
        )
            (ok prorated)
        )
    )
)

(define-read-only (get-borrower-loan-details (borrower-address principal))
    (map-get? active-loans { borrower-address: borrower-address })
)

(define-read-only (get-lender-contribution (lender-address principal))
    (map-get? lender-contributions { lender-address: lender-address })
)

(define-read-only (get-lending-pool-balance)
    (var-get lending-pool-balance)
)

;; ADMINISTRATIVE FUNCTIONS
;; Fixed function with proper validation of borrower-address
(define-public (change-loan-status (borrower-address principal) (updated-status (string-ascii 20)))
    (begin
        (asserts! (is-eq tx-sender contract-administrator) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (check-contract-status) ERR-UNAUTHORIZED-ACCESS)
        (asserts! (validate-loan-status updated-status) ERR-INVALID-STATUS)
        (asserts! (validate-address-for-admin borrower-address) ERR-INVALID-ADDRESS)
        
        ;; Check if loan exists before proceeding
        (let ((loan-exists (is-some (map-get? active-loans { borrower-address: borrower-address }))))
            (asserts! loan-exists ERR-LOAN-NOT-REGISTERED)
            
            ;; Now safely access the loan data with validated address
            (let ((loan-details (unwrap! (map-get? active-loans { borrower-address: borrower-address }) ERR-LOAN-NOT-REGISTERED)))
                (map-set active-loans
                    { borrower-address: borrower-address }
                    (merge loan-details { 
                        loan-status: updated-status,
                        recent-payment-height: block-height 
                    })
                )
                (ok true)
            )
        )
    )
)

(define-public (pause-contract-operations)
    (begin
        (asserts! (is-eq tx-sender contract-administrator) ERR-UNAUTHORIZED-ACCESS)
        (var-set is-contract-paused true)
        (ok true)
    )
)

(define-public (resume-contract-operations)
    (begin
        (asserts! (is-eq tx-sender contract-administrator) ERR-UNAUTHORIZED-ACCESS)
        (var-set is-contract-paused false)
        (ok true)
    )
)

;; LOAN EVALUATION FUNCTIONS
(define-public (check-borrower-eligibility (borrower-address principal))
    (let (
        (existing-loan (map-get? active-loans {borrower-address: borrower-address}))
        (borrower-data (default-to 
            {
                borrowed-amount: u0,
                annual-interest-rate: u0,
                loan-creation-height: u0,
                loan-maturity-height: u0,
                amount-repaid: u0,
                loan-status: "NONE",
                credit-score: u0,
                recent-payment-height: u0
            }
            existing-loan))
        (borrower-credit-score (get credit-score borrower-data))
    )
        (asserts! (is-none existing-loan) ERR-LOAN-ALREADY-EXISTS)
        (asserts! (>= borrower-credit-score u50) ERR-BORROWER-INELIGIBLE) ;; Minimum credit score requirement
        (asserts! (>= (var-get lending-pool-balance) loan-amount-minimum) ERR-BALANCE-INSUFFICIENT)
        (ok true)
    )
)

(define-public (determine-maximum-loan-amount (borrower-address principal))
    (let (
        (borrower-data (default-to 
            {
                borrowed-amount: u0,
                annual-interest-rate: u0,
                loan-creation-height: u0,
                loan-maturity-height: u0,
                amount-repaid: u0,
                loan-status: "NONE",
                credit-score: u0,
                recent-payment-height: u0
            }
            (map-get? active-loans {borrower-address: borrower-address})))
        (borrower-credit-score (get credit-score borrower-data))
        (available-pool-funds (var-get lending-pool-balance))
    )
        (let (
            (calculated-loan-amount (/ (* available-pool-funds borrower-credit-score) u100))
        )
            (ok (if (> calculated-loan-amount loan-amount-maximum)
                    loan-amount-maximum
                    calculated-loan-amount))
        )
    )
)

(define-read-only (evaluate-loan-health (borrower-address principal))
    (match (map-get? active-loans {borrower-address: borrower-address})
        loan-data (let (
            (current-height block-height)
            (expected-payment-amount (/ (* (get borrowed-amount loan-data) 
                                    (- current-height (get loan-creation-height loan-data)))
                                 (- (get loan-maturity-height loan-data) (get loan-creation-height loan-data))))
            (actual-payment-amount (get amount-repaid loan-data))
        )
            (if (> expected-payment-amount u0)
                (let ((payment-health-ratio (/ (* actual-payment-amount u100) expected-payment-amount)))
                    (ok (if (>= payment-health-ratio u95) 
                            health-score-excellent
                            (if (>= payment-health-ratio u80)
                                health-score-good
                                (if (>= payment-health-ratio u60)
                                    health-score-fair
                                    (if (>= payment-health-ratio u40)
                                        health-score-poor
                                        health-score-default))))))
                (ok health-score-excellent))) ;; New loan with no expected repayment yet
        ERR-LOAN-NOT-REGISTERED
    )
)

;; EARLY REPAYMENT PROCESSING
(define-public (make-early-repayment (payment-amount uint))
    (let (
        (borrower-address tx-sender)
        (loan-details (unwrap! (map-get? active-loans {borrower-address: borrower-address}) ERR-LOAN-NOT-REGISTERED))
        (current-block-height block-height)
    )
        (asserts! (is-eq (get loan-status loan-details) "ACTIVE") ERR-LOAN-NOT-IN-ACTIVE-STATE)
        (asserts! (> payment-amount u0) ERR-AMOUNT-INVALID)

        (let (
            (elapsed-blocks (- current-block-height (get loan-creation-height loan-details)))
            (total-blocks (- (get loan-maturity-height loan-details) (get loan-creation-height loan-details)))
            (accrued-interest (try! (calculate-prorated-interest 
                              (get borrowed-amount loan-details) 
                              (get annual-interest-rate loan-details)
                              elapsed-blocks
                              total-blocks)))
            (outstanding-principal (- (get borrowed-amount loan-details) (get amount-repaid loan-details)))
            (early-payment-discount (/ (* (+ outstanding-principal accrued-interest) early-payment-discount-rate) u1000000))
            (discounted-payoff-amount (- (+ outstanding-principal accrued-interest) early-payment-discount))
        )
            (asserts! (>= payment-amount discounted-payoff-amount) ERR-BALANCE-INSUFFICIENT)

            ;; Process repayment
            (try! (stx-transfer? payment-amount borrower-address (as-contract tx-sender)))

            ;; Update loan status
            (map-set active-loans
                {borrower-address: borrower-address}
                (merge loan-details {
                    amount-repaid: (get borrowed-amount loan-details),
                    loan-status: "COMPLETED",
                    recent-payment-height: current-block-height
                })
            )

            ;; Update contract state
            (var-set outstanding-loan-count (try! (subtract-with-overflow-check (var-get outstanding-loan-count) u1)))
            (var-set lending-pool-balance (try! (add-with-overflow-check (var-get lending-pool-balance) payment-amount)))

            (ok true)
        )
    )
)

;; LOAN EXTENSION FUNCTION
(define-public (extend-loan-term (extension-blocks uint))
    (let (
        (borrower-address tx-sender)
        (loan-details (unwrap! (map-get? active-loans {borrower-address: borrower-address}) ERR-LOAN-NOT-REGISTERED))
        (current-block-height block-height)
        (original-term (- (get loan-maturity-height loan-details) (get loan-creation-height loan-details)))
        (allowed-extension (* original-term extension-limit-maximum u1 (/ u1 u10))) ;; Max extension is 30% of original term
    )
        (asserts! (is-eq (get loan-status loan-details) "ACTIVE") ERR-LOAN-NOT-IN-ACTIVE-STATE)
        (asserts! (<= extension-blocks allowed-extension) ERR-EXTENSION-LIMIT-REACHED)
        (asserts! (validate-loan-term (+ original-term extension-blocks)) ERR-TERM-INVALID)
        
        ;; Calculate extension fee
        (let (
            (loan-balance (- (get borrowed-amount loan-details) (get amount-repaid loan-details)))
            (extension-fee (/ (* loan-balance extension-fee-percentage) u1000000))
        )
            ;; Process fee payment
            (try! (stx-transfer? extension-fee borrower-address (as-contract tx-sender)))
            
            ;; Update loan terms
            (map-set active-loans
                {borrower-address: borrower-address}
                (merge loan-details {
                    loan-maturity-height: (+ (get loan-maturity-height loan-details) extension-blocks),
                    recent-payment-height: current-block-height
                })
            )
            
            ;; Add fee to lending pool
            (var-set lending-pool-balance (try! (add-with-overflow-check (var-get lending-pool-balance) extension-fee)))
            
            (ok true)
        )
    )
)