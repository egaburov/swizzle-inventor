#lang rosette

(require "util.rkt" "cuda.rkt" "cuda-synth.rkt")

(define struct-size 3)
(define n-block 1)

(define (create-IO warpSize)
  (set-warpSize warpSize)
  (define block-size (* 2 warpSize))
  (define array-size (* n-block block-size))
  (define I-sizes (x-y-z (* array-size struct-size)))
  (define I (create-matrix I-sizes gen-uid))
  (define O (create-matrix I-sizes))
  (define O* (create-matrix I-sizes))
  (values block-size I-sizes I O O*))

(define (run-with-warp-size spec kernel w)
  (define-values (block-size I-sizes I O O*)
  (create-IO w))

  (define c (gcd struct-size warpSize))
  (define a (/ struct-size c))
  (define b (/ warpSize c))

  (run-kernel spec (x-y-z block-size) (x-y-z n-block) I O a b c)
  (run-kernel kernel (x-y-z block-size) (x-y-z n-block) I O* a b c)
  (define ret (equal? O O*))
  ;(pretty-display `(O ,O))
  ;(pretty-display `(O* ,O*))
  ret)

(define (AOS-load-spec threadId blockID blockDim I O a b c)
  (define I-cached (create-matrix (x-y-z struct-size)))
  (define warpID (get-warpId threadId))
  (define offset (+ (* struct-size blockID blockDim) (* struct-size warpID warpSize)))  ;; warpID = (threadIdy * blockDimx + threadIdx)/warpSize
  (define gid (get-global-threadId threadId blockID))
  (global-to-warp-reg I I-cached
                 (x-y-z struct-size)
                 offset (x-y-z (* warpSize struct-size)) #f)
  (warp-reg-to-global I-cached O
                      (x-y-z 1) offset (x-y-z (* warpSize struct-size)) #f)
  )

(define (print-vec x)
  (format "#(~a)" (string-join (for/list ([xi x]) (format "~a" xi)))))

(define (AOS-load-test threadId blockID blockDim I O a b c)
   (define log-a (bvlog a))
   (define log-b (bvlog b))
   (define log-c (bvlog c))
   (define log-m (bvlog struct-size))
   (define log-n (bvlog warpSize))
   (define I-cached (create-matrix (x-y-z struct-size)))
   (define O-cached
     (for/vector ((i blockSize)) (create-matrix (x-y-z struct-size))))
   (define warpID (get-warpId threadId))
   (define offset
     (+ (* struct-size blockID blockDim) (* struct-size warpID warpSize)))
   (define gid (get-global-threadId threadId blockID))
   (global-to-warp-reg
    I
    I-cached
    (x-y-z 1)
    offset
    (x-y-z (* warpSize struct-size))
    #f)
   (define localId (get-idInWarp threadId))
  (pretty-display `(threadId ,threadId))
   (for/bounded
    ((i struct-size))
    (let* ((index
            (@int
             (extract
              (bvlshr
               (bvshl
                (bvsub
                 (extract (@dup (bv 1 BW)) (bv 5 BW))
                 (bvsub (@dup (@bv i)) (@bv localId)))
                (bv 5 BW))
               (bv 5 BW))
              log-m)))
           (lane
            (@int
             (bvadd
              (bvlshr
               (bvadd
                (bvshl (@bv localId) (bv 3 BW))
                (bvshl (@bv localId) (bv 3 BW)))
               (bv 2 BW))
              (extract
               (bvadd
                (bvsub (@dup (@bv i)) (@dup (bv 1 BW)))
                (bvlshr (@bv localId) (bv 3 BW)))
               (bv 2 BW)))))
           (x (shfl (get I-cached index) lane))
           (index-o
            (@int
             (extract
              (bvadd
               (bvlshr (@bv localId) (bv 3 BW))
               (bvsub (@dup (@bv i)) (@dup (bv 1 BW))))
              log-m))))
      (pretty-display `(i ,i ,(print-vec localId)))
      (pretty-display `(index ,(print-vec index)))
      (pretty-display `(lane ,(print-vec lane)))
      (pretty-display `(index-o ,(print-vec index-o)))
      (unique-warp (modulo lane warpSize))
      (set O-cached index-o x)))
   (warp-reg-to-global
    O-cached
    O
    (x-y-z 1)
    offset
    (x-y-z (* warpSize struct-size))
    #f))

;; struct size = 4
;; warpSize 2 4: > 1 hr
;; warpSize 2 4, bv, constrain row permute: 43/596 s
;; warpSize 4 8, bv, constrain row permute: 287/9840 s (still wrong for 32)
;; warpSize 32, bv, constrain row permute, depth 4/4/2: 76/1681 s

;; warpSize 32, depth 3/4/2: 142/4661 s
;; warpSize 32, depth 3/4/2, constrain row permute: 500/2817 s
;; warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 89/2518 s
;; warpSize 32, depth 3/4/2, constraint col+row permute, distinct?, ref: > 8 h

;; struct-size 2, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 27/266 s
;; struct-size 3, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 59/410 s
;; struct-size 4, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 89/2518 s
;; struct-size 4, warpSize 8, depth 3/4/2, constraint col+row permute, distinct?: 57/777 s

;; Ras's sketch
;; struct-size 2, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 2/9 s
;; struct-size 3, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 2/14 s
;; struct-size 4, warpSize 32, depth 3/4/2, constraint col+row permute, distinct?: 4/42 s
;; struct-size 4, warpSize 8, depth 3/4/2, constraint col+row permute, distinct?: 1/3 s
(define (AOS-load-sketch threadId blockID blockDim I O a b c)
  #|
  (define log-a (bvlog a))
  (define log-b (bvlog b))
  (define log-c (bvlog c))
  (define log-m (bvlog struct-size))
  (define log-n (bvlog warpSize))
|#
  
  (define I-cached (create-matrix (x-y-z struct-size)))
  (define O-cached (for/vector ([i blockSize]) (create-matrix (x-y-z struct-size))))
  (define warpID (get-warpId threadId))
  (define offset (+ (* struct-size blockID blockDim) (* struct-size warpID warpSize)))  ;; warpID = (threadIdy * blockDimx + threadIdx)/warpSize
  (define gid (get-global-threadId threadId blockID))
  (global-to-warp-reg I I-cached
                 (x-y-z 1)
                 ;;(x-y-z (?warp-offset [(get-x blockID) (get-x blockDim)] [warpID warpSize]))
                 offset
                 (x-y-z (* warpSize struct-size)) #f)

  (define indices (make-vector struct-size))
  (define indices-o (make-vector struct-size))
  (define localId (get-idInWarp threadId))
  (for/bounded ([i struct-size])
    (let* (;[index (modulo (?lane localId (@dup i) [a b c struct-size warpSize] 3) struct-size)]
           ;[lane (?lane localId (@dup i) [a b c struct-size warpSize] 4)]
           ;[index (@int (extract (?lane-log-bv (@bv localId) (@dup (@bv i)) [2 3 4 5] 4) log-m))]
           ;[lane (@int (?lane-log-bv (@bv localId) (@dup (@bv i)) [2 3 4 5] 4))]
           [index (modulo (+ (* (@dup i) (?const a b c struct-size warpSize)) (* localId (?const a b c struct-size warpSize))
                             (quotient (@dup i) (?const a b c struct-size warpSize)) (quotient localId (?const a b c struct-size warpSize))
                             (?const a b c struct-size warpSize))
                          struct-size)]
           [lane (+ (modulo (+ (* (@dup i) (?const a b c struct-size warpSize)) (* localId (?const a b c struct-size warpSize))
                               (quotient (@dup i) (?const a b c struct-size warpSize)) (quotient localId (?const a b c struct-size warpSize))
                               (?const a b c struct-size warpSize))
                            (?const a b c struct-size warpSize))
                    (modulo (+ (* (@dup i) (?const a b c struct-size warpSize)) (* localId (?const a b c struct-size warpSize))
                               (quotient (@dup i) (?const a b c struct-size warpSize)) (quotient localId (?const a b c struct-size warpSize))
                               (?const a b c struct-size warpSize))
                            (?const a b c struct-size warpSize))
                    )]
           [x (shfl (get I-cached index) lane)]
           ;[index-o (modulo (?index localId (@dup i) [a b c struct-size warpSize] 2) struct-size)]
           ;[index-o (@int (extract (?lane-log-bv (@bv localId) (@dup (@bv i)) [2 3 4 5] 2) log-m))]
           [index-o (modulo (+ (* (@dup i) (?const a b c struct-size warpSize)) (* localId (?const a b c struct-size warpSize))
                             (quotient (@dup i) (?const a b c struct-size warpSize)) (quotient localId (?const a b c struct-size warpSize))
                             (?const a b c struct-size warpSize))
                          struct-size)]
           )
      (unique-warp (modulo lane warpSize))
      (vector-set! indices i index)
      (vector-set! indices-o i index-o)
      (set O-cached index-o x))
    )
  (for ([t blockSize])
    (let ([l (for/list ([i struct-size]) (vector-ref (vector-ref indices i) t))]
          [lo (for/list ([i struct-size]) (vector-ref (vector-ref indices-o i) t))])
      (unique-list l)
      (unique-list lo)))
  
  (warp-reg-to-global O-cached O
                      (x-y-z 1)
                      ;;(x-y-z (?warp-offset [(get-x blockID) (get-x blockDim)] [warpID warpSize]))
                      offset
                      (x-y-z (* warpSize struct-size)) #f)
  )

(define (test)
  (for ([w (list 32)])
    (let ([ret (run-with-warp-size AOS-load-spec AOS-load-test w)])
      (pretty-display `(test ,w ,ret))))
  )
;(test)

(define (synthesis)
  (pretty-display "solving...")
  (define sol (time (solve (assert (andmap (lambda (w) (run-with-warp-size AOS-load-spec AOS-load-sketch w))
                                           (list 32))))))
  (print-forms sol)
  )
(synthesis)
