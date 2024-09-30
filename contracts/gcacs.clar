;; Governance Contract with Enhanced Anti-Corruption Safeguards

;; Define constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant VOTING_PERIOD u144) ;; ~1 day in Stacks blocks
(define-constant MIN_PROPOSAL_THRESHOLD u100000000) ;; 100 STX
(define-constant MAX_VOTING_POWER u1000000) ;; Maximum voting power (1 million)
(define-constant REPUTATION_FACTOR u100) ;; Reputation factor for voting power calculation

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
    status: (string-ascii 10)
  }
)

(define-map votes
  { proposal-id: uint, voter: principal }
  { vote: (string-ascii 3), weight: uint }
)

(define-map user-reputation
  { user: principal }
  { reputation-score: uint, last-action-block: uint }
)

;; Define variables
(define-data-var proposal-count uint u0)

;; Helper functions
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-reputation (user principal))
  (default-to
    { reputation-score: u100, last-action-block: u0 }
    (map-get? user-reputation { user: user })
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
      {
        reputation-score: (min new-score u1000),
        last-action-block: block-height
      }
    )
  )
)

;; Anti-corruption functions
(define-private (calculate-voting-power (voter principal))
  (let
    (
      (reputation (get-reputation voter))
      (stx-balance (stx-get-balance voter))
      (raw-voting-power (/ (* stx-balance (get reputation-score reputation)) REPUTATION_FACTOR))
    )
    (min raw-voting-power MAX_VOTING_POWER)
  )
)

(define-read-only (check-voting-power (voter principal))
  (ok (calculate-voting-power voter))
)

;; Core functions
(define-public (create-proposal (title (string-ascii 50)) (description (string-utf8 500)))
  (let
    (
      (proposal-id (+ (var-get proposal-count) u1))
      (start-block (+ block-height u1))
      (end-block (+ start-block VOTING_PERIOD))
    )
    (asserts! (>= (stx-get-balance tx-sender) MIN_PROPOSAL_THRESHOLD) (err u1))
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
        status: "active"
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
      (proposal (unwrap! (get-proposal proposal-id) (err u2)))
      (current-block block-height)
      (voting-power (calculate-voting-power tx-sender))
    )
    (asserts! (and (>= current-block (get start-block proposal)) (< current-block (get end-block proposal))) (err u3))
    (asserts! (is-none (get-vote proposal-id tx-sender)) (err u4))
    (asserts! (or (is-eq vote-type "yes") (is-eq vote-type "no")) (err u5))
    
    (map-set votes
      { proposal-id: proposal-id, voter: tx-sender }
      { vote: vote-type, weight: voting-power }
    )
    
    (if (is-eq vote-type "yes")
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { yes-votes: (+ (get yes-votes proposal) voting-power) })
      )
      (map-set proposals
        { proposal-id: proposal-id }
        (merge proposal { no-votes: (+ (get no-votes proposal) voting-power) })
      )
    )
    
    (update-reputation tx-sender "vote")
    (ok true)
  )
)

(define-public (finalize-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (get-proposal proposal-id) (err u2)))
      (current-block block-height)
    )
    (asserts! (>= current-block (get end-block proposal)) (err u6))
    (asserts! (is-eq (get status proposal) "active") (err u7))
    
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

;; Governance parameters update function
(define-public (update-governance-params 
  (new-voting-period (optional uint))
  (new-min-proposal-threshold (optional uint))
  (new-max-voting-power (optional uint))
  (new-reputation-factor (optional uint)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) (err u8))
    (if (is-some new-voting-period)
      (var-set VOTING_PERIOD (unwrap! new-voting-period (err u9)))
      true
    )
    (if (is-some new-min-proposal-threshold)
      (var-set MIN_PROPOSAL_THRESHOLD (unwrap! new-min-proposal-threshold (err u10)))
      true
    )
    (if (is-some new-max-voting-power)
      (var-set MAX_VOTING_POWER (unwrap! new-max-voting-power (err u11)))
      true
    )
    (if (is-some new-reputation-factor)
      (var-set REPUTATION_FACTOR (unwrap! new-reputation-factor (err u12)))
      true
    )
    (ok true)
  )
)