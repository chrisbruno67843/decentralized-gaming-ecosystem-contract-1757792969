;; In-Game Asset Management Smart Contract
;; Handles creation, trading, and ownership of in-game assets

;; Constants
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_ASSET_NOT_FOUND (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_ASSET_ALREADY_LISTED (err u104))
(define-constant ERR_ASSET_NOT_FOR_SALE (err u105))
(define-constant ERR_INVALID_PRICE (err u106))
(define-constant ERR_SELF_TRADE (err u107))
(define-constant CONTRACT_OWNER tx-sender)

;; Data Variables
(define-data-var asset-id-counter uint u0)
(define-data-var contract-paused bool false)
(define-data-var platform-fee-percentage uint u250) ;; 2.5%

;; Data Maps
(define-map assets
    { asset-id: uint }
    {
        owner: principal,
        name: (string-ascii 50),
        description: (string-ascii 200),
        rarity: (string-ascii 20),
        asset-type: (string-ascii 30),
        power-level: uint,
        created-at: uint,
        tradeable: bool
    }
)

(define-map asset-balances
    { owner: principal, asset-id: uint }
    { balance: uint }
)

(define-map marketplace-listings
    { asset-id: uint }
    {
        seller: principal,
        price: uint,
        quantity: uint,
        listed-at: uint,
        active: bool
    }
)

(define-map player-inventory-count
    { player: principal }
    { total-assets: uint }
)

(define-map asset-trade-history
    { asset-id: uint, trade-id: uint }
    {
        from: principal,
        to: principal,
        price: uint,
        timestamp: uint
    }
)

(define-map player-achievements
    { player: principal }
    {
        assets-created: uint,
        assets-traded: uint,
        total-trade-volume: uint
    }
)

;; Public Functions

;; Create a new in-game asset
(define-public (create-asset 
    (name (string-ascii 50))
    (description (string-ascii 200))
    (rarity (string-ascii 20))
    (asset-type (string-ascii 30))
    (power-level uint)
    (quantity uint)
    (tradeable bool)
)
    (let
        (
            (new-asset-id (+ (var-get asset-id-counter) u1))
            (creator tx-sender)
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (> quantity u0) ERR_INVALID_AMOUNT)
        (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
        
        ;; Create asset record
        (map-set assets
            { asset-id: new-asset-id }
            {
                owner: creator,
                name: name,
                description: description,
                rarity: rarity,
                asset-type: asset-type,
                power-level: power-level,
                created-at: block-height,
                tradeable: tradeable
            }
        )
        
        ;; Set initial balance
        (map-set asset-balances
            { owner: creator, asset-id: new-asset-id }
            { balance: quantity }
        )
        
        ;; Update inventory count
        (map-set player-inventory-count
            { player: creator }
            { total-assets: (+ (get-player-asset-count creator) u1) }
        )
        
        ;; Update creator achievements
        (update-player-achievements creator u1 u0 u0)
        
        ;; Update asset counter
        (var-set asset-id-counter new-asset-id)
        
        (ok new-asset-id)
    )
)

;; Transfer assets between players
(define-public (transfer-asset (asset-id uint) (recipient principal) (amount uint))
    (let
        (
            (sender tx-sender)
            (current-balance (get-asset-balance sender asset-id))
            (asset-info (get-asset-info asset-id))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some asset-info) ERR_ASSET_NOT_FOUND)
        (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (not (is-eq sender recipient)) ERR_SELF_TRADE)
        
        ;; Update sender balance
        (map-set asset-balances
            { owner: sender, asset-id: asset-id }
            { balance: (- current-balance amount) }
        )
        
        ;; Update recipient balance
        (map-set asset-balances
            { owner: recipient, asset-id: asset-id }
            { balance: (+ (get-asset-balance recipient asset-id) amount) }
        )
        
        ;; Record trade history
        (record-trade asset-id sender recipient u0)
        
        (ok true)
    )
)

;; List asset for sale on marketplace
(define-public (list-asset-for-sale (asset-id uint) (price uint) (quantity uint))
    (let
        (
            (seller tx-sender)
            (asset-balance (get-asset-balance seller asset-id))
            (asset-info (get-asset-info asset-id))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-some asset-info) ERR_ASSET_NOT_FOUND)
        (asserts! (>= asset-balance quantity) ERR_INSUFFICIENT_BALANCE)
        (asserts! (> price u0) ERR_INVALID_PRICE)
        (asserts! (> quantity u0) ERR_INVALID_AMOUNT)
        (asserts! (get tradeable (unwrap-panic asset-info)) ERR_NOT_AUTHORIZED)
        (asserts! (is-none (map-get? marketplace-listings { asset-id: asset-id })) ERR_ASSET_ALREADY_LISTED)
        
        ;; Create marketplace listing
        (map-set marketplace-listings
            { asset-id: asset-id }
            {
                seller: seller,
                price: price,
                quantity: quantity,
                listed-at: block-height,
                active: true
            }
        )
        
        (ok true)
    )
)

;; Purchase asset from marketplace
(define-public (purchase-asset (asset-id uint) (quantity uint))
    (let
        (
            (buyer tx-sender)
            (listing (map-get? marketplace-listings { asset-id: asset-id }))
            (seller (get seller (unwrap! listing ERR_ASSET_NOT_FOR_SALE)))
            (price (get price (unwrap! listing ERR_ASSET_NOT_FOR_SALE)))
            (available-quantity (get quantity (unwrap! listing ERR_ASSET_NOT_FOR_SALE)))
            (total-cost (* price quantity))
            (platform-fee (/ (* total-cost (var-get platform-fee-percentage)) u10000))
            (seller-proceeds (- total-cost platform-fee))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (get active (unwrap! listing ERR_ASSET_NOT_FOR_SALE)) ERR_ASSET_NOT_FOR_SALE)
        (asserts! (>= available-quantity quantity) ERR_INSUFFICIENT_BALANCE)
        (asserts! (> quantity u0) ERR_INVALID_AMOUNT)
        (asserts! (not (is-eq buyer seller)) ERR_SELF_TRADE)
        
        ;; Transfer STX from buyer to seller
        (try! (stx-transfer? seller-proceeds buyer seller))
        
        ;; Transfer platform fee to contract owner
        (try! (stx-transfer? platform-fee buyer CONTRACT_OWNER))
        
        ;; Transfer asset from seller to buyer
        (map-set asset-balances
            { owner: seller, asset-id: asset-id }
            { balance: (- (get-asset-balance seller asset-id) quantity) }
        )
        
        (map-set asset-balances
            { owner: buyer, asset-id: asset-id }
            { balance: (+ (get-asset-balance buyer asset-id) quantity) }
        )
        
        ;; Update marketplace listing
        (if (is-eq available-quantity quantity)
            (map-delete marketplace-listings { asset-id: asset-id })
            (map-set marketplace-listings
                { asset-id: asset-id }
                {
                    seller: seller,
                    price: price,
                    quantity: (- available-quantity quantity),
                    listed-at: (get listed-at (unwrap-panic listing)),
                    active: true
                }
            )
        )
        
        ;; Record trade
        (record-trade asset-id seller buyer price)
        
        ;; Update achievements
        (update-player-achievements seller u0 u1 price)
        (update-player-achievements buyer u0 u1 price)
        
        (ok true)
    )
)

;; Cancel marketplace listing
(define-public (cancel-listing (asset-id uint))
    (let
        (
            (listing (map-get? marketplace-listings { asset-id: asset-id }))
            (seller (get seller (unwrap! listing ERR_ASSET_NOT_FOR_SALE)))
        )
        (asserts! (not (var-get contract-paused)) ERR_NOT_AUTHORIZED)
        (asserts! (is-eq tx-sender seller) ERR_NOT_AUTHORIZED)
        
        (map-delete marketplace-listings { asset-id: asset-id })
        (ok true)
    )
)

;; Administrative function to pause contract
(define-public (toggle-contract-pause)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (var-set contract-paused (not (var-get contract-paused)))
        (ok (var-get contract-paused))
    )
)

;; Update platform fee
(define-public (update-platform-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (asserts! (<= new-fee u1000) ERR_INVALID_AMOUNT) ;; Max 10%
        (var-set platform-fee-percentage new-fee)
        (ok true)
    )
)

;; Read-Only Functions

;; Get asset information
(define-read-only (get-asset-info (asset-id uint))
    (map-get? assets { asset-id: asset-id })
)

;; Get asset balance for a player
(define-read-only (get-asset-balance (owner principal) (asset-id uint))
    (default-to u0 (get balance (map-get? asset-balances { owner: owner, asset-id: asset-id })))
)

;; Get marketplace listing
(define-read-only (get-marketplace-listing (asset-id uint))
    (map-get? marketplace-listings { asset-id: asset-id })
)

;; Get player's total asset count
(define-read-only (get-player-asset-count (player principal))
    (default-to u0 (get total-assets (map-get? player-inventory-count { player: player })))
)

;; Get player achievements
(define-read-only (get-player-achievements (player principal))
    (default-to
        { assets-created: u0, assets-traded: u0, total-trade-volume: u0 }
        (map-get? player-achievements { player: player })
    )
)

;; Get current asset ID counter
(define-read-only (get-current-asset-id)
    (var-get asset-id-counter)
)

;; Get contract status
(define-read-only (get-contract-status)
    {
        paused: (var-get contract-paused),
        platform-fee: (var-get platform-fee-percentage),
        total-assets: (var-get asset-id-counter)
    }
)

;; Private Functions

;; Record a trade in history
(define-private (record-trade (asset-id uint) (from principal) (to principal) (price uint))
    (let
        ((trade-id (+ (var-get asset-id-counter) block-height)))
        (map-set asset-trade-history
            { asset-id: asset-id, trade-id: trade-id }
            {
                from: from,
                to: to,
                price: price,
                timestamp: block-height
            }
        )
    )
)

;; Update player achievements
(define-private (update-player-achievements (player principal) (assets-created uint) (assets-traded uint) (trade-volume uint))
    (let
        ((current-achievements (get-player-achievements player)))
        (map-set player-achievements
            { player: player }
            {
                assets-created: (+ (get assets-created current-achievements) assets-created),
                assets-traded: (+ (get assets-traded current-achievements) assets-traded),
                total-trade-volume: (+ (get total-trade-volume current-achievements) trade-volume)
            }
        )
    )
)
