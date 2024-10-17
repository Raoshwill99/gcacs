;; Governance Contract with Multi-Signature Upgrades

;; Define constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant VOTING_PERIOD u144) ;; ~1 day in Stacks blocks
(define-constant MIN_PROPOSAL_THRESHOLD u100000000) ;; 100 STX
(define-constant MAX_VOTING_POWER u1000000) ;; Maximum voting power (1 million)
(define-constant REPUTATION_FACTOR u100) ;; Reputation factor for voting power calculation
(define-constant SUSPICIOUS_VOTE_THRESHOLD u0.8) ;; 80% similarity threshold for suspicious votes
(define-constant REQUIRED_SIGNATURES u3) ;; Number of signatures required for upgrades

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
  { vote: (string-ascii 3), weight: uint, timestamp: uint }
)

(define-map user-reputation
  { user: principal }
  { reputation-score: uint, last-action-block: uint }
)

(define-map voting-patterns
  { user: principal }
  { total-votes: uint, agreement-count: uint }
)

(define-map signers 
  { signer: principal } 
  { is-signer: bool }
)

(define-map upgrade-proposals
  { proposal-id: uint }
  {
    new-contract-address: principal,
    signatures: (list 10 principal),
    status: (string-ascii 10)
  }
)

;; Define variables
(define-data-var proposal-count uint u0)
(define-data-var upgrade-proposal-count uint u0)

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

(define-read-only (is-signer (account principal))
  (default-to false (get is-signer (map-get? signers { signer: account })))
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

;; Advanced analytics functions
(define-private (update-voting-pattern (voter principal) (vote-type (string-ascii 3)))
  (let
    (
      (current-pattern (default-to { total-votes: u0, agreement-count: u0 }
                                   (map-get? voting-patterns { user: voter })))
      (new-total (+ (get total-votes current-pattern) u1))
      (new-agreement (if (is-eq vote-type "yes")
                         (+ (get agreement-count current-pattern) u1)
                         (get agreement-count current-pattern)))
    )
    (map-set voting-patterns
      { user: voter }
      { total-votes: new-total, agreement-count: new-agreement }
    )
  )
)

(define-read-only (get-voting-similarity (voter-a principal) (voter-b principal))
  (let
    (
      (pattern-a (default-to { total-votes: u0, agreement-count: u0 }
                             (map-get? voting-patterns { user: voter-a })))
      (pattern-b (default-to { total-votes: u0, agreement-count: u0 }
                             (map-get? voting-patterns { user: voter-b })))
      (total-votes (min (get total-votes pattern-a) (get total-votes pattern-b)))
      (agreements (abs (- (get agreement-count pattern-a) (get agreement-count pattern-b))))
    )
    (if (> total-votes u0)
      (/ agreements total-votes)
      u0)
  )
)

(define-read-only (check-suspicious-similarity (voter-a principal) (voter-b principal))
  (>= (get-voting-similarity voter-a voter-b) SUSPICIOUS_VOTE_THRESHOLD)
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
      { vote: vote-type, weight: voting-power, timestamp: block-height }
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
    (update-voting-pattern tx-sender vote-type)
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

;; Multi-signature upgrade functions
(define-public (propose-upgrade (new-contract-address principal))
  (let
    (
      (proposal-id (+ (var-get upgrade-proposal-count) u1))
    )
    (asserts! (is-signer tx-sender) (err u8))
    (map-set upgrade-proposals
      { proposal-id: proposal-id }
      {
        new-contract-address: new-contract-address,
        signatures: (list tx-sender),
        status: "active"
      }
    )
    (var-set upgrade-proposal-count proposal-id)
    (ok proposal-id)
  )
)

(define-public (sign-upgrade-proposal (proposal-id uint))
  (let
    (
      (proposal (unwrap! (map-get? upgrade-proposals { proposal-id: proposal-id }) (err u9)))
      (current-signatures (get signatures proposal))
    )
    (asserts! (is-signer tx-sender) (err u8))
    (asserts! (is-none (index-of current-signatures tx-sender)) (err u10))
    (asserts! (is-eq (get status proposal) "active") (err u11))
    
    (map-set upgrade-proposals
      { proposal-id: proposal-id }
      (merge proposal 
        { signatures: (unwrap! (as-max-len? (append current-signatures tx-sender) u10) (err u12)) }
      )
    )
    (ok true)
  )
)

(define-public (finalize-upgrade (proposal-id uint))
  (let
    (
      (proposal (unwrap! (map-get? upgrade-proposals { proposal-id: proposal-id }) (err u9)))
      (signatures (get signatures proposal))
    )
    (asserts! (is-signer tx-sender) (err u8))
    (asserts! (is-eq (get status proposal) "active") (err u11))
    (asserts! (>= (len signatures) REQUIRED_SIGNATURES) (err u13))
    
    (map-set upgrade-proposals
      { proposal-id: proposal-id }
      (merge proposal { status: "executed" })
    )
    
    ;; Here we would typically call a function to upgrade the contract
    ;; For demonstration, we'll just return success
    (ok true)
  )
)

;; Governance parameters update function
(define-public (update-governance-params 
  (new-voting-period (optional uint))
  (new-min-proposal-threshold (optional uint))
  (new-max-voting-power (optional uint))
  (new-reputation-factor (optional uint))
  (new-suspicious-vote-threshold (optional uint)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) (err u14))
    (if (is-some new-voting-period)
      (var-set VOTING_PERIOD (unwrap! new-voting-period (err u15)))
      true
    )
    (if (is-some new-min-proposal-threshold)
      (var-set MIN_PROPOSAL_THRESHOLD (unwrap! new-min-proposal-threshold (err u16)))
      true
    )
    (if (is-some new-max-voting-power)
      (var-set MAX_VOTING_POWER (unwrap! new-max-voting-power (err u17)))
      true
    )
    (if (is-some new-reputation-factor)
      (var-set REPUTATION_FACTOR (unwrap! new-reputation-factor (err u18)))
      true
    )
    (if (is-some new-suspicious-vote-threshold)
      (var-set SUSPICIOUS_VOTE_THRESHOLD (unwrap! new-suspicious-vote-threshold (err u19)))
      true
    )
    (ok true)
  )
)

;; Signer management functions
(define-public (add-signer (new-signer principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) (err u14))
    (map-set signers { signer: new-signer } { is-signer: true })
    (ok true)
  )
)

(define-public (remove-signer (signer-to-remove principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) (err u14))
    (map-set signers { signer: signer-to-remove } { is-signer: false })
    (ok true)
  )
)