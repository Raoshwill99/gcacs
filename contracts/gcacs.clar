;; Governance Contract with Advanced Features

;; Define constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant VOTING_PERIOD u144) ;; ~1 day in Stacks blocks
(define-constant MIN_PROPOSAL_THRESHOLD u100000000) ;; 100 STX
(define-constant MAX_VOTING_POWER u1000000) ;; Maximum voting power (1 million)
(define-constant REPUTATION_FACTOR u100) ;; Reputation factor for voting power calculation
(define-constant SUSPICIOUS_VOTE_THRESHOLD u80) ;; 80% similarity threshold
(define-constant TIME_LOCK_PERIOD u72) ;; ~12 hours in Stacks blocks
(define-constant REQUIRED_APPROVALS u3) ;; Number of approvals needed for multi-sig
(define-constant DELEGATION_COOLDOWN u36) ;; ~6 hours cooldown for delegation changes
(define-constant INCENTIVE_REWARD u1000000) ;; 1 STX reward for voting
(define-constant EMERGENCY_DELAY u36) ;; ~6 hours delay for emergency actions

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PROPOSAL (err u101))
(define-constant ERR-ALREADY-VOTED (err u102))
(define-constant ERR-PROPOSAL-EXPIRED (err u103))
(define-constant ERR-INVALID-STATE (err u104))
(define-constant ERR-INSUFFICIENT-BALANCE (err u105))
(define-constant ERR-ALREADY-CLAIMED (err u106))
(define-constant ERR-NOT-EMERGENCY-SIGNER (err u107))
(define-constant ERR-EMERGENCY-ACTIVE (err u108))
(define-constant ERR-EMERGENCY-INACTIVE (err u109))
(define-constant ERR-DELEGATION-COOLDOWN (err u110))

;; Define data maps
(define-map proposals
  { proposal-id: uint }
  {
    creator: principal,
    title: (string-ascii 50),
    description: (string-utf8 500),
    start-block: uint,
    end-block: uint,
    yes-votes: uint,
    no-votes: uint,
    status: (string-ascii 10),
    execution-block: uint,
    approvals: uint,
    approved-by: (list 10 principal),
    is-emergency: bool
  }
)

(define-map votes
  { proposal-id: uint, voter: principal }
  { 
    vote: (string-ascii 3), 
    weight: uint, 
    timestamp: uint,
    incentive-claimed: bool
  }
)

(define-map user-reputation
  { user: principal }
  { 
    reputation-score: uint, 
    last-action-block: uint,
    delegated-to: (optional principal),
    delegation-until-block: uint,
    total-delegated-power: uint
  }
)

(define-map voting-patterns
  { user: principal }
  { total-votes: uint, agreement-count: uint }
)

(define-map emergency-signers
  { signer: principal }
  { is-active: bool }
)

;; Define variables
(define-data-var proposal-count uint u0)
(define-data-var is-emergency-mode bool false)
(define-data-var emergency-start-block uint u0)

;; Helper functions
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-reputation (user principal))
  (default-to
    { 
      reputation-score: u100, 
      last-action-block: u0,
      delegated-to: none,
      delegation-until-block: u0,
      total-delegated-power: u0
    }
    (map-get? user-reputation { user: user })
  )
)

(define-read-only (is-emergency-signer (account principal))
  (default-to 
    false
    (get is-active (map-get? emergency-signers { signer: account }))
  )
)

;; Reputation management functions
(define-private (update-reputation (user principal) (action-type (string-ascii 10)))
  (let
    (
      (current-reputation (get-reputation user))
      (reputation-change (if (is-eq action-type "proposal")
                            u10
                            (if (is-eq action-type "vote")
                              u5
                              u0)))
      (new-score (+ (get reputation-score current-reputation) reputation-change))
    )
    (map-set user-reputation
      { user: user }
      (merge current-reputation
        {
          reputation-score: (min new-score u1000),
          last-action-block: block-height
        }
      )
    )
  )
)

;; Anti-corruption functions
(define-private (calculate-voting-power (voter principal))
  (let
    (
      (reputation (get-reputation voter))
      (stx-balance (stx-get-balance voter))
      (base-power (/ (* stx-balance (get reputation-score reputation)) REPUTATION_FACTOR))
      (delegated-power (get total-delegated-power reputation))
      (total-power (+ base-power delegated-power))
    )
    (min total-power MAX_VOTING_POWER)
  )
)

(define-read-only (check-voting-power (voter principal))
  (ok (calculate-voting-power voter))
)

;; Delegation system functions
(define-public (delegate-votes (delegate-to principal))
  (let
    (
      (current-reputation (get-reputation tx-sender))
      (delegate-reputation (get-reputation delegate-to))
      (current-block block-height)
      (voting-power (calculate-voting-power tx-sender))
    )
    (asserts! (not (is-eq tx-sender delegate-to)) ERR-INVALID-STATE)
    (asserts! (>= (- current-block (get last-action-block current-reputation)) 
                  DELEGATION_COOLDOWN) 
              ERR-DELEGATION-COOLDOWN)
    
    (map-set user-reputation
      { user: tx-sender }
      (merge current-reputation 
        { 
          delegated-to: (some delegate-to),
          delegation-until-block: (+ current-block DELEGATION_COOLDOWN)
        }
      )
    )
    
    (map-set user-reputation
      { user: delegate-to }
      (merge delegate-reputation
        {
          total-delegated-power: (+ (get total-delegated-power delegate-reputation) 
                                   voting-power)
        }
      )
    )
    (ok true)
  )
)

;; Emergency management functions
(define-public (add-emergency-signer (new-signer principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR-NOT-AUTHORIZED)
    (map-set emergency-signers
      { signer: new-signer }
      { is-active: true }
    )
    (ok true)
  )
)

(define-public (activate-emergency-mode)
  (begin
    (asserts! (is-emergency-signer tx-sender) ERR-NOT-EMERGENCY-SIGNER)
    (asserts! (not (var-get is-emergency-mode)) ERR-EMERGENCY-ACTIVE)
    (var-set is-emergency-mode true)
    (var-set emergency-start-block block-height)
    (ok true)
  )
)

(define-public (deactivate-emergency-mode)
  (begin
    (asserts! (is-emergency-signer tx-sender) ERR-NOT-EMERGENCY-SIGNER)
    (asserts! (var-get is-emergency-mode) ERR-EMERGENCY-INACTIVE)
    (asserts! (>= (- block-height (var-get emergency-start-block)) 
                  EMERGENCY_DELAY) 
              ERR-INVALID-STATE)
    (var-set is-emergency-mode false)
    (ok true)
  )
)

;; Incentive system functions
(define-public (claim-vote-incentive (proposal-id uint))
  (let
    (
      (vote (unwrap! (get-vote proposal-id tx-sender) ERR-INVALID-PROPOSAL))
      (proposal (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
    )
    (asserts! (is-eq (get status proposal) "finalized") ERR-INVALID-STATE)
    (asserts! (not (get incentive-claimed vote)) ERR-ALREADY-CLAIMED)
    
    (try! (stx-transfer? INCENTIVE_REWARD CONTRACT_OWNER tx-sender))
    (map-set votes
      { proposal-id: proposal-id, voter: tx-sender }
      (merge vote { incentive-claimed: true })
    )
    (ok true)
  )
)

;; Multi-signature functions
(define-public (approve-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
      (current-block block-height)
    )
    (asserts! (is-eq (get status proposal) "passed") ERR-INVALID-STATE)
    (asserts! (> (get execution-block proposal) current-block) ERR-PROPOSAL-EXPIRED)
    (asserts! (not (is-in-list tx-sender (get approved-by proposal))) ERR-ALREADY-VOTED)
    
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal 
        { 
          approvals: (+ (get approvals proposal) u1),
          approved-by: (unwrap! (as-max-len? 
            (append (get approved-by proposal) tx-sender) u10) 
            ERR-INVALID-STATE)
        }
      )
    )
    (ok true)
  )
)

;; Core proposal functions
(define-public (create-proposal (title (string-ascii 50)) 
                              (description (string-utf8 500))
                              (is-emergency bool))
  (let
    (
      (proposal-id (+ (var-get proposal-count) u1))
      (start-block (+ block-height u1))
      (end-block (+ start-block VOTING_PERIOD))
      (execution-block (+ end-block TIME_LOCK_PERIOD))
    )
    (asserts! (>= (stx-get-balance tx-sender) MIN_PROPOSAL_THRESHOLD) 
              ERR-INSUFFICIENT-BALANCE)
    (asserts! (or (not is-emergency) (is-emergency-signer tx-sender)) 
              ERR-NOT-EMERGENCY-SIGNER)
    
    (map-set proposals
      { proposal-id: proposal-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        start-block: start-block,
        end-block: end-block,
        yes-votes: u0,
        no-votes: u0,
        status: "active",
        execution-block: execution-block,
        approvals: u0,
        approved-by: (list),
        is-emergency: is-emergency
      }
    )
    (var-set proposal-count proposal-id)
    (update-reputation tx-sender "proposal")
    (ok proposal-id)
  )
)

(define-public (vote (proposal-id uint) (vote-type (string-ascii 3)))
  (let
    (
      (proposal (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
      (current-block block-height)
      (voting-power (calculate-voting-power tx-sender))
    )
    (asserts! (and (>= current-block (get start-block proposal)) 
                   (< current-block (get end-block proposal))) 
              ERR-PROPOSAL-EXPIRED)
    (asserts! (is-none (get-vote proposal-id tx-sender)) ERR-ALREADY-VOTED)
    (asserts! (or (is-eq vote-type "yes") (is-eq vote-type "no")) ERR-INVALID-STATE)
    
    (map-set votes
      { proposal-id: proposal-id, voter: tx-sender }
      { 
        vote: vote-type, 
        weight: voting-power, 
        timestamp: block-height,
        incentive-claimed: false
      }
    )
    
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal 
        {
          yes-votes: (if (is-eq vote-type "yes")
                        (+ (get yes-votes proposal) voting-power)
                        (get yes-votes proposal)),
          no-votes: (if (is-eq vote-type "no")
                       (+ (get no-votes proposal) voting-power)
                       (get no-votes proposal))
        }
      )
    )
    
    (update-reputation tx-sender "vote")
    (ok true)
  )
)

(define-public (finalize-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
      (current-block block-height)
    )
    (asserts! (>= current-block (get end-block proposal)) ERR-INVALID-STATE)
    (asserts! (is-eq (get status proposal) "active") ERR-INVALID-STATE)
    
    (if (> (get yes-votes proposal) (get no-votes proposal))
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { status: "passed" })
      )
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { status: "rejected" })
      )
    )
    
    (ok true)
  )
)

(define-public (execute-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (get-proposal proposal-id) ERR-INVALID-PROPOSAL))
      (current-block block-height)
    )
    (asserts! (is-eq (get status proposal) "passed") ERR-INVALID-STATE)
    (asserts! (>= current-block (get execution-block proposal)) ERR-INVALID-STATE)
    (asserts! (>= (get approvals proposal) REQUIRED_APPROVALS) ERR-INVALID-STATE)
    (asserts! (or 
                (not (get is-emergency proposal))
                (and
                  (var-get is-emergency-mode)
                  (>= (- current-block (var-get emergency-start-block)) 
                      EMERGENCY_DELAY))) 
              ERR-INVALID-STATE)
    
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal { status: "executed" })
    )
    (ok true)
  )
)