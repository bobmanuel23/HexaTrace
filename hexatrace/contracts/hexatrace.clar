;; Supply Chain Verification System
;; Enables tracking of products through the supply chain with
;; immutable records and verification at each step of the process

;; Product definitions
(define-map products
  { product-id: uint }
  {
    name: (string-utf8 128),
    description: (string-utf8 1024),
    manufacturer: principal,
    batch-code: (string-ascii 64),
    created-at: uint,
    status: (string-ascii 32),  ;; "created", "in-transit", "delivered", "sold", "recalled"
    product-type: (string-ascii 64),
    origin-location: (string-utf8 128),
    current-custodian: principal,
    final-destination: (optional (string-utf8 128)),
    expected-delivery: (optional uint),
    metadata-uri: (optional (string-utf8 256))
  }
)

;; Supply chain checkpoints
(define-map checkpoints
  { product-id: uint, checkpoint-id: uint }
  {
    location: (string-utf8 128),
    timestamp: uint,
    custodian: principal,
    verified-by: principal,
    checkpoint-type: (string-ascii 32),  ;; "manufacture", "shipping", "customs", "warehouse", "retail", "delivery"
    temperature: (optional int),         ;; For temperature-sensitive goods
    humidity: (optional uint),           ;; For humidity-sensitive goods
    notes: (optional (string-utf8 512)),
    attestation-hash: (buff 32)         ;; Hash of checkpoint attestation document
  }
)

;; Authorized verifiers for each company
(define-map company-verifiers
  { company: principal, verifier: principal }
  {
    name: (string-utf8 128),
    role: (string-ascii 64),
    authorized-at: uint,
    authorized-by: principal,
    active: bool
  }
)

;; Custody transfers
(define-map custody-transfers
  { product-id: uint, transfer-id: uint }
  {
    from: principal,
    to: principal,
    initiated-at: uint,
    completed-at: (optional uint),
    status: (string-ascii 32),  ;; "pending", "completed", "rejected", "cancelled"
    conditions: (optional (string-utf8 512))
  }
)

;; Certifications and compliance
(define-map certifications
  { product-id: uint, certification-type: (string-ascii 64) }
  {
    issuer: principal,
    issued-at: uint,
    valid-until: uint,
    certificate-hash: (buff 32),
    certificate-uri: (optional (string-utf8 256)),
    status: (string-ascii 32)  ;; "valid", "expired", "revoked"
  }
)

;; Next available IDs
(define-data-var next-product-id uint u0)
(define-map next-checkpoint-id { product-id: uint } { id: uint })
(define-map next-transfer-id { product-id: uint } { id: uint })

;; Helper function to convert string to buffer for hashing
(define-private (string-utf8-to-buff (val (string-utf8 512)))
  ;; In a real implementation, you would convert the string to bytes
  0x68656c6c6f20776f726c64 ;; Example buffer (represents "hello world" in hex)
)

;; Helper function to convert ascii string to buffer for hashing
(define-private (ascii-to-buff (val (string-ascii 64)))
  ;; In a real implementation, you would convert the string to bytes
  0x68656c6c6f20776f726c64 ;; Example buffer (represents "hello world" in hex)
)

;; Helper function to convert principal to string
(define-private (principal-to-string (val principal))
  u"principal" ;; Simplified implementation
)

;; Register a new product
(define-public (register-product
                (name (string-utf8 128))
                (description (string-utf8 1024))
                (batch-code (string-ascii 64))
                (product-type (string-ascii 64))
                (origin-location (string-utf8 128))
                (metadata-uri (optional (string-utf8 256))))
  (let
    ((product-id (var-get next-product-id)))
    
    ;; Create the product record
    (map-set products
      { product-id: product-id }
      {
        name: name,
        description: description,
        manufacturer: tx-sender,
        batch-code: batch-code,
        created-at: block-height,
        status: "created",
        product-type: product-type,
        origin-location: origin-location,
        current-custodian: tx-sender,
        final-destination: none,
        expected-delivery: none,
        metadata-uri: metadata-uri
      }
    )
    
    ;; Initialize checkpoint counter
    (map-set next-checkpoint-id
      { product-id: product-id }
      { id: u0 }
    )
    
    ;; Initialize transfer counter
    (map-set next-transfer-id
      { product-id: product-id }
      { id: u0 }
    )
    
    ;; Create initial manufacturing checkpoint
    (try! (add-checkpoint
            product-id
            origin-location
            "manufacture"
            none
            none
            (some u"Product manufactured with batch code")
            (sha256 (ascii-to-buff batch-code))
          ))
    
    ;; Increment product ID counter
    (var-set next-product-id (+ product-id u1))
    
    (ok product-id)
  )
)

;; Add a checkpoint to a product's supply chain journey
(define-public (add-checkpoint
                (product-id uint)
                (location (string-utf8 128))
                (checkpoint-type (string-ascii 32))
                (temperature (optional int))
                (humidity (optional uint))
                (notes (optional (string-utf8 512)))
                (attestation-hash (buff 32)))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found")))
     (checkpoint-counter (unwrap! (map-get? next-checkpoint-id { product-id: product-id }) 
                                 (err u"Counter not found")))
     (checkpoint-id (get id checkpoint-counter)))
    
    ;; Validate
    (asserts! (or (is-eq tx-sender (get current-custodian product)) 
                  (is-company-verifier (get current-custodian product) tx-sender))
              (err u"Not authorized to add checkpoint"))
    (asserts! (not (is-eq (get status product) "recalled")) (err u"Product has been recalled"))
    
    ;; Create the checkpoint
    (map-set checkpoints
      { product-id: product-id, checkpoint-id: checkpoint-id }
      {
        location: location,
        timestamp: block-height,
        custodian: (get current-custodian product),
        verified-by: tx-sender,
        checkpoint-type: checkpoint-type,
        temperature: temperature,
        humidity: humidity,
        notes: notes,
        attestation-hash: attestation-hash
      }
    )
    
    ;; Update product status based on checkpoint type
    (map-set products
      { product-id: product-id }
      (merge product 
        { 
          status: (if (is-eq checkpoint-type "delivery") "delivered" 
                    (if (is-eq checkpoint-type "retail-sale") "sold" "in-transit"))
        }
      )
    )
    
    ;; Increment checkpoint counter
    (map-set next-checkpoint-id
      { product-id: product-id }
      { id: (+ checkpoint-id u1) }
    )
    
    (ok checkpoint-id)
  )
)

;; Check if a principal is an authorized verifier for a company
(define-private (is-company-verifier (company principal) (verifier principal))
  (match (map-get? company-verifiers { company: company, verifier: verifier })
    verifier-data (get active verifier-data)
    false
  )
)

;; Authorize a verifier for a company
(define-public (authorize-verifier
                (verifier principal)
                (name (string-utf8 128))
                (role (string-ascii 64)))
  (begin
    ;; Set verifier as authorized
    (map-set company-verifiers
      { company: tx-sender, verifier: verifier }
      {
        name: name,
        role: role,
        authorized-at: block-height,
        authorized-by: tx-sender,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Revoke a verifier's authorization
(define-public (revoke-verifier (verifier principal))
  (let
    ((verifier-data (unwrap! (map-get? company-verifiers { company: tx-sender, verifier: verifier })
                            (err u"Verifier not found"))))
    
    (map-set company-verifiers
      { company: tx-sender, verifier: verifier }
      (merge verifier-data { active: false })
    )
    
    (ok true)
  )
)

;; Initiate custody transfer of a product
(define-public (initiate-transfer
                (product-id uint)
                (recipient principal)
                (conditions (optional (string-utf8 512))))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found")))
     (transfer-counter (unwrap! (map-get? next-transfer-id { product-id: product-id }) 
                               (err u"Counter not found")))
     (transfer-id (get id transfer-counter)))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get current-custodian product)) 
              (err u"Only current custodian can initiate transfer"))
    (asserts! (not (is-eq (get status product) "recalled")) 
              (err u"Product has been recalled"))
    
    ;; Create transfer record
    (map-set custody-transfers
      { product-id: product-id, transfer-id: transfer-id }
      {
        from: tx-sender,
        to: recipient,
        initiated-at: block-height,
        completed-at: none,
        status: "pending",
        conditions: conditions
      }
    )
    
    ;; Increment transfer counter
    (map-set next-transfer-id
      { product-id: product-id }
      { id: (+ transfer-id u1) }
    )
    
    (ok transfer-id)
  )
)

;; Accept a custody transfer
(define-public (accept-transfer (product-id uint) (transfer-id uint))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found")))
     (transfer (unwrap! (map-get? custody-transfers { product-id: product-id, transfer-id: transfer-id })
                       (err u"Transfer not found"))))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get to transfer)) (err u"Only recipient can accept"))
    (asserts! (is-eq (get status transfer) "pending") (err u"Transfer not pending"))
    
    ;; Update transfer record
    (map-set custody-transfers
      { product-id: product-id, transfer-id: transfer-id }
      (merge transfer 
        { 
          completed-at: (some block-height),
          status: "completed"
        }
      )
    )
    
    ;; Update product custodian
    (map-set products
      { product-id: product-id }
      (merge product { current-custodian: tx-sender })
    )
    
    ;; Add a checkpoint for the custody transfer
    (try! (add-checkpoint
            product-id
            u"custody-transfer" ;; Generic location for transfer as utf8
            "transfer"
            none
            none
            (some u"Custody transferred")
            (sha256 (string-utf8-to-buff u"custody-transfer"))
          ))
    
    (ok true)
  )
)

;; Reject a custody transfer
(define-public (reject-transfer (product-id uint) (transfer-id uint) (reason (string-utf8 512)))
  (let
    ((transfer (unwrap! (map-get? custody-transfers { product-id: product-id, transfer-id: transfer-id })
                       (err u"Transfer not found"))))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get to transfer)) (err u"Only recipient can reject"))
    (asserts! (is-eq (get status transfer) "pending") (err u"Transfer not pending"))
    
    ;; Update transfer record
    (map-set custody-transfers
      { product-id: product-id, transfer-id: transfer-id }
      (merge transfer 
        { 
          completed-at: (some block-height),
          status: "rejected",
          conditions: (some reason)
        }
      )
    )
    
    (ok true)
  )
)

;; Cancel a pending transfer (only current custodian)
(define-public (cancel-transfer (product-id uint) (transfer-id uint))
  (let
    ((transfer (unwrap! (map-get? custody-transfers { product-id: product-id, transfer-id: transfer-id })
                       (err u"Transfer not found"))))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get from transfer)) (err u"Only sender can cancel"))
    (asserts! (is-eq (get status transfer) "pending") (err u"Transfer not pending"))
    
    ;; Update transfer record
    (map-set custody-transfers
      { product-id: product-id, transfer-id: transfer-id }
      (merge transfer 
        { 
          completed-at: (some block-height),
          status: "cancelled"
        }
      )
    )
    
    (ok true)
  )
)

;; Add certification to a product
(define-public (add-certification
                (product-id uint)
                (certification-type (string-ascii 64))
                (valid-until uint)
                (certificate-hash (buff 32))
                (certificate-uri (optional (string-utf8 256))))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found"))))
    
    ;; Validate
    (asserts! (or (is-eq tx-sender (get manufacturer product)) 
                  (is-company-verifier (get manufacturer product) tx-sender))
              (err u"Not authorized to add certification"))
    (asserts! (> valid-until block-height) (err u"Certification must be valid for future blocks"))
    
    ;; Add certification
    (map-set certifications
      { product-id: product-id, certification-type: certification-type }
      {
        issuer: tx-sender,
        issued-at: block-height,
        valid-until: valid-until,
        certificate-hash: certificate-hash,
        certificate-uri: certificate-uri,
        status: "valid"
      }
    )
    
    (ok true)
  )
)

;; Revoke a certification
(define-public (revoke-certification (product-id uint) (certification-type (string-ascii 64)))
  (let
    ((certification (unwrap! (map-get? certifications 
                               { product-id: product-id, certification-type: certification-type })
                             (err u"Certification not found"))))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get issuer certification)) 
              (err u"Only issuer can revoke certification"))
    
    ;; Update certification
    (map-set certifications
      { product-id: product-id, certification-type: certification-type }
      (merge certification { status: "revoked" })
    )
    
    (ok true)
  )
)

;; Issue a product recall
(define-public (recall-product (product-id uint) (reason (string-utf8 512)))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found"))))
    
    ;; Validate
    (asserts! (is-eq tx-sender (get manufacturer product)) 
              (err u"Only manufacturer can recall product"))
    
    ;; Update product status
    (map-set products
      { product-id: product-id }
      (merge product { status: "recalled" })
    )
    
    ;; Add a checkpoint for the recall
    (try! (add-checkpoint
            product-id
            u"recall" ;; Using utf8 string for location
            "recall"
            none
            none
            (some reason)
            (sha256 (string-utf8-to-buff reason))
          ))
    
    (ok true)
  )
)

;; Set final destination and expected delivery
(define-public (set-shipping-details
                (product-id uint)
                (final-destination (string-utf8 128))
                (expected-delivery uint))
  (let
    ((product (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found"))))
    
    ;; Validate
    (asserts! (or (is-eq tx-sender (get current-custodian product)) 
                  (is-company-verifier (get current-custodian product) tx-sender))
              (err u"Not authorized to set shipping details"))
    
    ;; Update product
    (map-set products
      { product-id: product-id }
      (merge product 
        { 
          final-destination: (some final-destination),
          expected-delivery: (some expected-delivery)
        }
      )
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get product details
(define-read-only (get-product-details (product-id uint))
  (ok (unwrap! (map-get? products { product-id: product-id }) (err u"Product not found")))
)

;; Get checkpoint details
(define-read-only (get-checkpoint (product-id uint) (checkpoint-id uint))
  (ok (unwrap! (map-get? checkpoints { product-id: product-id, checkpoint-id: checkpoint-id })
              (err u"Checkpoint not found")))
)

;; Get transfer details
(define-read-only (get-transfer (product-id uint) (transfer-id uint))
  (ok (unwrap! (map-get? custody-transfers { product-id: product-id, transfer-id: transfer-id })
              (err u"Transfer not found")))
)

;; Get certification details
(define-read-only (get-certification (product-id uint) (certification-type (string-ascii 64)))
  (ok (unwrap! (map-get? certifications { product-id: product-id, certification-type: certification-type })
              (err u"Certification not found")))
)

;; Check if certification is valid
(define-read-only (is-certification-valid (product-id uint) (certification-type (string-ascii 64)))
  (match (map-get? certifications { product-id: product-id, certification-type: certification-type })
    certification (and (is-eq (get status certification) "valid")
                       (> (get valid-until certification) block-height))
    false
  )
)

;; Verify product authenticity (basic check)
(define-read-only (verify-product-authenticity (product-id uint))
  (match (map-get? products { product-id: product-id })
    product (ok {
              authentic: true,
              manufacturer: (get manufacturer product),
              batch-code: (get batch-code product),
              status: (get status product)
            })
    (err u"Product not found")
  )
)