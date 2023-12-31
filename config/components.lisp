(defun make-inv-bat-chain (&rest plist)
  (let* ((no-meter (plist-get plist :no-meter))
         (bat-config (plist-get plist :bat-config))
         (inv-config (plist-get plist :inv-config))
         (initial-power (or (plist-get plist :initial-power) 0.0))

         (inv-id (get-comp-id))
         (bat-id (get-comp-id))
         (inv-power-symbol (power-symbol-from-id inv-id))
         (inv-energy-symbol (energy-symbol-from-id inv-id))

         (bat-config-alist `(,@bat-config ,@battery-defaults))
         (inv-config-alist `(,@inv-config ,@inverter-defaults))

         (capacity (alist-get 'capacity bat-config-alist))
         (initial-soc (alist-get 'initial-soc bat-config-alist))

         (bat-soc-symbol (soc-symbol-from-id bat-id))
         (bat-soc-expr `(setq ,bat-soc-symbol
                              (+ ,initial-soc
                                 ;; limit to 1 decimal place
                                 (/ (fround
                                     (* 1000.0 (/ ,inv-energy-symbol ,capacity)))
                                    10.0))))

         (bat-rated-bounds (or (alist-get 'rated-bounds bat-config-alist) '(0.0 0.0)))
         (inv-rated-bounds (or (alist-get 'rated-bounds inv-config-alist) '(0.0 0.0)))
         (bat-excl-bounds (or (alist-get 'exclusion-bounds bat-config-alist) '(0.0 0.0)))

         (bat-rated-lower (nth 0 bat-rated-bounds))
         (bat-rated-upper (nth 1 bat-rated-bounds))
         (inv-rated-lower (nth 0 inv-rated-bounds))
         (inv-rated-upper (nth 1 inv-rated-bounds))
         (bat-excl-lower (nth 0 bat-excl-bounds))
         (bat-excl-upper (nth 1 bat-excl-bounds))

         (bat-incl-lower-symbol (inclusion-lower-symbol-from-id bat-id))
         (bat-incl-upper-symbol (inclusion-upper-symbol-from-id bat-id))

         (bounds-check-func-symbol (bounds-check-func-symbol-from-id inv-id))

         (soc-lower (alist-get 'soc-lower bat-config-alist))
         (soc-upper (alist-get 'soc-upper bat-config-alist))

         (bat-incl-lower-expr `(setq ,bat-incl-lower-symbol
                                     (if (< (- ,bat-soc-symbol ,soc-lower) 10.0)
                                         (* ,bat-rated-lower
                                            (bounded-exp-decay ,(+ soc-lower 10.0)
                                                               ,soc-lower
                                                               ,bat-soc-symbol
                                                               1.2
                                                               0.0))
                                         ,bat-rated-lower)))
         (bat-incl-upper-expr `(setq ,bat-incl-upper-symbol
                                     (if (< (- ,soc-upper ,bat-soc-symbol) 10.0)
                                         (* ,bat-rated-upper
                                            (bounded-exp-decay ,(- soc-upper 10.0)
                                                               ,soc-upper
                                                               ,bat-soc-symbol
                                                               1.2
                                                               0.0))
                                         ,bat-rated-upper)))

         (battery (make-battery :id bat-id
                                :power inv-power-symbol
                                :soc bat-soc-symbol
                                :inclusion-lower bat-incl-lower-symbol
                                :inclusion-upper bat-incl-upper-symbol
                                :exclusion-lower bat-excl-lower
                                :exclusion-upper bat-excl-upper
                                :config bat-config))
         (inverter (make-battery-inverter :id inv-id
                                          :power inv-power-symbol
                                          :inclusion-lower inv-rated-lower
                                          :inclusion-upper inv-rated-upper
                                          :config inv-config)))

    (when (not (boundp inv-power-symbol))
      (set inv-power-symbol initial-power)
      (set inv-energy-symbol 0.0)
      (set bat-soc-symbol initial-soc))

    (set bounds-check-func-symbol
         (list 'lambda '(power)
               `(and (<= ,bat-incl-lower-symbol
                         power
                         ,bat-incl-upper-symbol)
                     (<= ,inv-rated-lower
                         power
                         ,inv-rated-upper)
                     (or (equal power 0.0)
                         (not (< ,bat-excl-lower
                                 power
                                 ,bat-excl-upper))))))

    (setq state-update-functions
          (cons (list 'lambda '(ms-since-last-call)
                      `(eval (setq ,inv-energy-symbol
                                   (+ ,inv-energy-symbol ;; ->> ?
                                      (* ,inv-power-symbol
                                         (/ ms-since-last-call
                                            ,(* 60.0 60.0 1000.0))))))
                      `(eval ,bat-soc-expr)
                      `(eval ,bat-incl-lower-expr)
                      `(eval ,bat-incl-upper-expr)
                      `(cond ((< ,inv-power-symbol ,bat-incl-lower-symbol)
                              (setq ,inv-power-symbol ,bat-incl-lower-symbol))
                             ((> ,inv-power-symbol ,bat-incl-upper-symbol)
                              (setq ,inv-power-symbol ,bat-incl-upper-symbol))))
                state-update-functions))

    (eval bat-incl-lower-expr)
    (eval bat-incl-upper-expr)

    (add-to-connections-alist inv-id bat-id)

    (if no-meter
        inverter
      (let* ((meter-id (get-comp-id))
             (meter (make-meter :id meter-id
                                :power inv-power-symbol)))
        (add-to-connections-alist meter-id inv-id)
        meter))))


;;;;;;;;;;;;;;;
;; Batteries ;;
;;;;;;;;;;;;;;;

(defmacro battery-data-maker (data-alist defaults-alist)
  (component-data-maker 'battery-data
                        data-alist
                        defaults-alist
                        '(id soc soc-upper soc-lower
                          capacity power voltage type
                          component-state relay-state
                          inclusion-lower inclusion-upper
                          exclusion-lower exclusion-upper)))

(defun make-battery (&rest plist)
  (let* ((id (or (plist-get plist :id) (get-comp-id)))
         (interval (or (plist-get plist :interval) battery-interval))
         (power (plist-get plist :power))
         (config (plist-get plist :config))
         (power-expr (when power
                       `((power . ,power)
                         (component-state . (power->component-state ,power)))))
         (soc-bounds-expr `((soc . ,(plist-get plist :soc))
                            (inclusion-lower . ,(plist-get plist :inclusion-lower))
                            (inclusion-upper . ,(plist-get plist :inclusion-upper))
                            (exclusion-lower . ,(plist-get plist :exclusion-lower))
                            (exclusion-upper . ,(plist-get plist :exclusion-upper))))
         (battery
          `((category . battery)
            (name     . ,(format "bat-%s" id))
            (id       . ,id)
            ,@power-expr
            (stream   . ,(list
                          `(interval . ,interval)
                          `(data     . ,(battery-data-maker
                                         `((id    . ,id)
                                           ,@soc-bounds-expr
                                           ,@power-expr
                                           ,@config)
                                         battery-defaults)))))))
    (add-to-components-alist battery)
    battery))


;;;;;;;;;;;;;;;
;; Inverters ;;
;;;;;;;;;;;;;;;

(defmacro inverter-data-maker (data-alist defaults-alist)
  (component-data-maker 'inverter-data
                        data-alist
                        defaults-alist
                        '(id power current voltage component-state
                          inclusion-lower inclusion-upper)))

(defun make-battery-inverter (&rest plist)
  (let* ((id (or (plist-get plist :id) (get-comp-id)))
         (interval (or (plist-get plist :interval) inverter-interval))
         (power (plist-get plist :power))
         (config (plist-get plist :config))
         (successors (plist-get plist :successors))
         (power-expr (when power
                       `((power . ,power)
                         (current . (ac-current-from-power ,power))
                         (component-state . (power->component-state ,power)))))
         (bounds-expr `((inclusion-lower . ,(plist-get plist :inclusion-lower))
                        (inclusion-upper . ,(plist-get plist :inclusion-upper))))
         (inverter
          `((category . inverter)
            (type     . battery)
            (name     . ,(format "inv-bat-%s" id))
            (id       . ,id)
            ,@power-expr
            (stream   . ,(list
                          `(interval . ,interval)
                          `(data     . ,(inverter-data-maker
                                         `((id . ,id)
                                           ,@bounds-expr
                                           ,@power-expr
                                           ,@config)
                                         inverter-defaults)))))))
    (add-to-components-alist inverter)
    (connect-successors id successors)
    inverter))


;;;;;;;;;;;;
;; Meters ;;
;;;;;;;;;;;;

(defmacro meter-data-maker (data-alist defaults-alist)
  (component-data-maker 'meter-data
                        data-alist
                        defaults-alist
                        '(id power current voltage)))



(defun make-meter (&rest plist)
  (let* ((id (or (plist-get plist :id) (get-comp-id)))
         (interval (or (plist-get plist :interval) meter-interval))
         (power (plist-get plist :power))
         (config (plist-get plist :config))
         (successors (plist-get plist :successors))
         (current-expr (if-let ((current (if power
                                             `(ac-current-from-power ,power)
                                             (make-current-expr successors)
                                             )))
                           `((current . ,current))))
         (power-expr (if-let ((power (or power
                                         (make-power-expr successors))))
                         `((power . ,power))))
         (meter
          `((category . meter)
            (name     . ,(format "meter-%s" id))
            (id       . ,id)
            ,@current-expr
            ,@power-expr
            (stream   . ,(list
                          `(interval . ,interval)
                          `(data     . ,(meter-data-maker
                                         `((id    . ,id)
                                           ,@current-expr
                                           ,@power-expr
                                           ,@config)
                                         meter-defaults)))))))
    (add-to-components-alist meter)
    (connect-successors id successors)
    meter))


;;;;;;;;;;
;; Grid ;;
;;;;;;;;;;

(defun make-grid (&rest plist)
  (let ((id (or (plist-get plist :id) (get-comp-id)))
        (successors (plist-get plist :successors))
        (rated-fuse-current (plist-get plist :rated-fuse-current))
        (grid
         `((category . grid)
           (id       . ,id)
           (name     . "grid")
           (rated-fuse-current . ,rated-fuse-current))))
    (add-to-components-alist grid)
    (connect-successors id successors)
    grid))
