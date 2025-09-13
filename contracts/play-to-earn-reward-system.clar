;; Play-to-Earn Reward System Smart Contract
;; Manages reward distribution and gaming economy

;; Constants
(define-constant ERR_NOT_AUTHORIZED (err u200))
(define-constant ERR_PLAYER_NOT_FOUND (err u201))
(define-constant ERR_INSUFFICIENT_REWARDS (err u202))
(define-constant ERR_INVALID_AMOUNT (err u203))
(define-constant ERR_ALREADY_REGISTERED (err u204))
(define-constant ERR_GAME_NOT_REGISTERED (err u205))
(define-constant ERR_ACHIEVEMENT_EXISTS (err u206))
(define-constant ERR_INVALID_LEVEL (err u207))
(define-constant ERR_COOLDOWN_ACTIVE (err u208))
(define-constant CONTRACT_OWNER tx-sender)
(define-constant BLOCKS_PER_DAY u144) ;; Approximately 144 blocks per day

;; Data Variables
(define-data-var total-rewards-distributed uint u0)
(define-data-var reward-pool-balance uint u0)
(define-data-var base-reward-rate uint u100) ;; Base reward per achievement
(define-data-var daily-reward-cap uint u1000) ;; Maximum rewards per player per day
(define-data-var contract-paused bool false)
(define-data-var reward-multiplier uint u100) ;; 100 = 1.0x multiplier

;; Data Maps
(define-map registered-players
    { player: principal }
    {
        join-date: uint,
        level: uint,
        total-score: uint,
        rewards-earned: uint,
        last-activity: uint,
        status: (string-ascii 20)
    }
)

(define-map player-daily-stats
    { player: principal, day: uint }
    {
        games-played: uint,
        achievements-earned: uint,
        rewards-claimed: uint,
        last-claim: uint
    }
)

(define-map game-achievements
    { achievement-id: uint }
    {
        name: (string-ascii 50),
        description: (string-ascii 200),
        reward-amount: uint,
        difficulty: (string-ascii 20),
        created-by: principal,
        active: bool
    }
)

(define-map player-achievements
    { player: principal, achievement-id: uint }
    {
        earned-at: uint,
        reward-claimed: bool,
        performance-score: uint
    }
)

(define-map leaderboard-scores
    { player: principal }
    {
        weekly-score: uint,
        monthly-score: uint,
        all-time-score: uint,
        rank: uint,
        last-updated: uint
    }
)

(define-map reward-modifiers
    { player: principal }
    {
        streak-bonus: uint,
        level-multiplier: uint,
        special-bonus: uint,
        expires-at: uint
    }
)

(define-map gaming-sessions
    { player: principal, session-id: uint }
    {
        start-time: uint,
        end-time: uint,
        score-earned: uint,
        achievements-unlocked: uint,
        rewards-generated: uint
    }
)

;; Achievement ID counter
(define-data-var achievement-counter uint u0)
(define-data-var session-counter uint u0)

;; Public Functions

;; Register a new player in the reward system
(define-public (register-player)
    (let ((player tx-sender))
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-none (map-get? registered-players { player: player })) ERR_ALREADY_REGISTERED)
        
        ;; Register player with initial stats
        (map-set registered-players
            { player: player }
            {
                join-date: block-height,
                level: u1,
                total-score: u0,
                rewards-earned: u0,
                last-activity: block-height,
                status: "active"
            }
        )
        
        ;; Initialize leaderboard entry
        (map-set leaderboard-scores
            { player: player }
            {
                weekly-score: u0,
                monthly-score: u0,
                all-time-score: u0,
                rank: u0,
                last-updated: block-height
            }
        )
        
        (ok true)
    )
)

;; Create a new achievement for the game
(define-public (create-achievement 
    (name (string-ascii 50))
    (description (string-ascii 200))
    (reward-amount uint)
    (difficulty (string-ascii 20))
)
    (let
        (
            (new-achievement-id (+ (var-get achievement-counter) u1))
            (creator tx-sender)
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (> reward-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
        
        ;; Create achievement record
        (map-set game-achievements
            { achievement-id: new-achievement-id }
            {
                name: name,
                description: description,
                reward-amount: reward-amount,
                difficulty: difficulty,
                created-by: creator,
                active: true
            }
        )
        
        ;; Update counter
        (var-set achievement-counter new-achievement-id)
        
        (ok new-achievement-id)
    )
)

;; Record an achievement for a player
(define-public (record-achievement (player principal) (achievement-id uint) (performance-score uint))
    (let
        (
            (achievement (map-get? game-achievements { achievement-id: achievement-id }))
            (player-info (map-get? registered-players { player: player }))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some achievement) ERR_ACHIEVEMENT_EXISTS)
        (asserts! (is-some player-info) ERR_PLAYER_NOT_FOUND)
        (asserts! (get active (unwrap-panic achievement)) ERR_NOT_AUTHORIZED)
        (asserts! (is-none (map-get? player-achievements { player: player, achievement-id: achievement-id })) ERR_ACHIEVEMENT_EXISTS)
        
        ;; Record the achievement
        (map-set player-achievements
            { player: player, achievement-id: achievement-id }
            {
                earned-at: block-height,
                reward-claimed: false,
                performance-score: performance-score
            }
        )
        
        ;; Update player stats
        (update-player-progress player performance-score)
        
        ;; Update daily stats
        (update-daily-stats player)
        
        (ok true)
    )
)

;; Claim rewards for completed achievements
(define-public (claim-rewards (achievement-id uint))
    (let
        (
            (player tx-sender)
            (achievement (map-get? game-achievements { achievement-id: achievement-id }))
            (player-achievement (map-get? player-achievements { player: player, achievement-id: achievement-id }))
            (base-reward (get reward-amount (unwrap! achievement ERR_ACHIEVEMENT_EXISTS)))
            (performance-score (get performance-score (unwrap! player-achievement ERR_ACHIEVEMENT_EXISTS)))
            (player-modifiers (get-player-modifiers player))
            (final-reward (calculate-final-reward base-reward performance-score player-modifiers))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (not (get reward-claimed (unwrap! player-achievement ERR_ACHIEVEMENT_EXISTS))) ERR_NOT_AUTHORIZED)
        (asserts! (>= (var-get reward-pool-balance) final-reward) ERR_INSUFFICIENT_REWARDS)
        (asserts! (check-daily-limit player final-reward) ERR_INVALID_AMOUNT)
        
        ;; Mark reward as claimed
        (map-set player-achievements
            { player: player, achievement-id: achievement-id }
            {
                earned-at: (get earned-at (unwrap-panic player-achievement)),
                reward-claimed: true,
                performance-score: performance-score
            }
        )
        
        ;; Update player rewards
        (update-player-rewards player final-reward)
        
        ;; Update pool balance
        (var-set reward-pool-balance (- (var-get reward-pool-balance) final-reward))
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) final-reward))
        
        ;; Transfer rewards to player
        (try! (stx-transfer? final-reward (as-contract tx-sender) player))
        
        (ok final-reward)
    )
)

;; Start a gaming session
(define-public (start-gaming-session)
    (let
        (
            (player tx-sender)
            (new-session-id (+ (var-get session-counter) u1))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some (map-get? registered-players { player: player })) ERR_PLAYER_NOT_FOUND)
        
        ;; Create session record
        (map-set gaming-sessions
            { player: player, session-id: new-session-id }
            {
                start-time: block-height,
                end-time: u0,
                score-earned: u0,
                achievements-unlocked: u0,
                rewards-generated: u0
            }
        )
        
        ;; Update session counter
        (var-set session-counter new-session-id)
        
        ;; Update player activity
        (update-player-activity player)
        
        (ok new-session-id)
    )
)

;; End a gaming session and calculate rewards
(define-public (end-gaming-session (session-id uint) (score-earned uint) (achievements-unlocked uint))
    (let
        (
            (player tx-sender)
            (session (map-get? gaming-sessions { player: player, session-id: session-id }))
            (session-reward (calculate-session-reward score-earned achievements-unlocked))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some session) ERR_NOT_AUTHORIZED)
        (asserts! (is-eq (get end-time (unwrap-panic session)) u0) ERR_NOT_AUTHORIZED) ;; Session not ended
        
        ;; Update session record
        (map-set gaming-sessions
            { player: player, session-id: session-id }
            {
                start-time: (get start-time (unwrap-panic session)),
                end-time: block-height,
                score-earned: score-earned,
                achievements-unlocked: achievements-unlocked,
                rewards-generated: session-reward
            }
        )
        
        ;; Update player progress
        (update-player-progress player score-earned)
        
        (ok session-reward)
    )
)

;; Fund the reward pool (admin or community function)
(define-public (fund-reward-pool (amount uint))
    (begin
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set reward-pool-balance (+ (var-get reward-pool-balance) amount))
        (ok true)
    )
)

;; Administrative functions
(define-public (update-reward-parameters (base-rate uint) (daily-cap uint) (multiplier uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (var-set base-reward-rate base-rate)
        (var-set daily-reward-cap daily-cap)
        (var-set reward-multiplier multiplier)
        (ok true)
    )
)

(define-public (toggle-contract-pause)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (var-set contract-paused (not (var-get contract-paused)))
        (ok (var-get contract-paused))
    )
)

;; Read-Only Functions

;; Get player information
(define-read-only (get-player-info (player principal))
    (map-get? registered-players { player: player })
)

;; Get achievement details
(define-read-only (get-achievement-info (achievement-id uint))
    (map-get? game-achievements { achievement-id: achievement-id })
)

;; Get player achievement status
(define-read-only (get-player-achievement (player principal) (achievement-id uint))
    (map-get? player-achievements { player: player, achievement-id: achievement-id })
)

;; Get leaderboard scores
(define-read-only (get-leaderboard-score (player principal))
    (map-get? leaderboard-scores { player: player })
)

;; Get daily stats
(define-read-only (get-daily-stats (player principal) (day uint))
    (map-get? player-daily-stats { player: player, day: day })
)

;; Get contract statistics
(define-read-only (get-contract-stats)
    {
        total-rewards-distributed: (var-get total-rewards-distributed),
        reward-pool-balance: (var-get reward-pool-balance),
        base-reward-rate: (var-get base-reward-rate),
        daily-reward-cap: (var-get daily-reward-cap),
        total-achievements: (var-get achievement-counter),
        total-sessions: (var-get session-counter),
        paused: (var-get contract-paused)
    }
)

;; Get player modifiers
(define-read-only (get-player-modifiers (player principal))
    (default-to
        { streak-bonus: u100, level-multiplier: u100, special-bonus: u100, expires-at: u0 }
        (map-get? reward-modifiers { player: player })
    )
)

;; Private Functions

;; Update player progress and level
(define-private (update-player-progress (player principal) (score uint))
    (let
        (
            (current-info (unwrap-panic (map-get? registered-players { player: player })))
            (new-total-score (+ (get total-score current-info) score))
            (new-level (calculate-level new-total-score))
        )
        (map-set registered-players
            { player: player }
            {
                join-date: (get join-date current-info),
                level: new-level,
                total-score: new-total-score,
                rewards-earned: (get rewards-earned current-info),
                last-activity: block-height,
                status: (get status current-info)
            }
        )
        
        ;; Update leaderboard
        (update-leaderboard player score)
    )
)

;; Update leaderboard scores
(define-private (update-leaderboard (player principal) (score uint))
    (let
        ((current-scores (get-leaderboard-score player)))
        (match current-scores
            scores (map-set leaderboard-scores
                { player: player }
                {
                    weekly-score: (+ (get weekly-score scores) score),
                    monthly-score: (+ (get monthly-score scores) score),
                    all-time-score: (+ (get all-time-score scores) score),
                    rank: (get rank scores),
                    last-updated: block-height
                }
            )
            (map-set leaderboard-scores
                { player: player }
                {
                    weekly-score: score,
                    monthly-score: score,
                    all-time-score: score,
                    rank: u0,
                    last-updated: block-height
                }
            )
        )
    )
)

;; Update daily statistics
(define-private (update-daily-stats (player principal))
    (let
        (
            (current-day (/ block-height BLOCKS_PER_DAY))
            (current-stats (map-get? player-daily-stats { player: player, day: current-day }))
        )
        (match current-stats
            stats (map-set player-daily-stats
                { player: player, day: current-day }
                {
                    games-played: (get games-played stats),
                    achievements-earned: (+ (get achievements-earned stats) u1),
                    rewards-claimed: (get rewards-claimed stats),
                    last-claim: (get last-claim stats)
                }
            )
            (map-set player-daily-stats
                { player: player, day: current-day }
                {
                    games-played: u0,
                    achievements-earned: u1,
                    rewards-claimed: u0,
                    last-claim: u0
                }
            )
        )
    )
)

;; Calculate player level based on total score
(define-private (calculate-level (total-score uint))
    (if (< total-score u1000) u1
    (if (< total-score u5000) u2
    (if (< total-score u15000) u3
    (if (< total-score u35000) u4
    (if (< total-score u70000) u5
    u6)))))
)

;; Calculate final reward with modifiers
(define-private (calculate-final-reward (base-reward uint) (performance-score uint) (modifiers (tuple (streak-bonus uint) (level-multiplier uint) (special-bonus uint) (expires-at uint))))
    (let
        (
            (performance-bonus (/ (* base-reward performance-score) u100))
            (streak-multiplier (get streak-bonus modifiers))
            (level-multiplier (get level-multiplier modifiers))
            (special-multiplier (get special-bonus modifiers))
            (total-multiplier (/ (* (* streak-multiplier level-multiplier) special-multiplier) u10000))
        )
        (/ (* (+ base-reward performance-bonus) total-multiplier) u100)
    )
)

;; Calculate session-based rewards
(define-private (calculate-session-reward (score uint) (achievements uint))
    (+ (/ (* score (var-get base-reward-rate)) u100) (* achievements (var-get base-reward-rate)))
)

;; Check daily reward limits
(define-private (check-daily-limit (player principal) (reward-amount uint))
    (let
        (
            (current-day (/ block-height BLOCKS_PER_DAY))
            (daily-stats (map-get? player-daily-stats { player: player, day: current-day }))
        )
        (match daily-stats
            stats (<= (+ (get rewards-claimed stats) reward-amount) (var-get daily-reward-cap))
            true
        )
    )
)

;; Update player rewards total
(define-private (update-player-rewards (player principal) (reward-amount uint))
    (let
        ((player-info (unwrap-panic (map-get? registered-players { player: player }))))
        (map-set registered-players
            { player: player }
            {
                join-date: (get join-date player-info),
                level: (get level player-info),
                total-score: (get total-score player-info),
                rewards-earned: (+ (get rewards-earned player-info) reward-amount),
                last-activity: (get last-activity player-info),
                status: (get status player-info)
            }
        )
    )
)

;; Update player activity timestamp
(define-private (update-player-activity (player principal))
    (let
        ((player-info (unwrap-panic (map-get? registered-players { player: player }))))
        (map-set registered-players
            { player: player }
            {
                join-date: (get join-date player-info),
                level: (get level player-info),
                total-score: (get total-score player-info),
                rewards-earned: (get rewards-earned player-info),
                last-activity: block-height,
                status: (get status player-info)
            }
        )
    )
)
