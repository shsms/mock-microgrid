(defun get-comp-id ()
  (setq comp--id--counter (+ comp--id--counter 1)))
(setq comp--id--counter 1000)


(defun power-symbol-from-id (id)
  (intern (format "component-power-%s" id)))


(defun add-to-connections-alist (id-from id-to)
  (if (not (boundp 'connections-alist))
      (setq connections-alist nil))
  (setq connections-alist (cons (cons id-from id-to)
                                connections-alist)))


(defun add-to-components-alist (alist)
  (if (not (boundp 'components-alist))
      (setq components-alist nil))
  (setq components-alist (cons alist
                               components-alist)))


(defun set-power-active (id power)
  (let* ((power-symbol (power-symbol-from-id id))
         (original-value (eval power-symbol)))
    (eval `(setq ,power-symbol power))
    (print (format "set %s from %s to %s"
                   power-symbol
                   original-value
                   (eval power-symbol)))))


(defun component-data-maker (method data-alist defaults-alist keys)
  (let ((input-alist (append (eval data-alist) (eval defaults-alist)))
        (args-alist))
    (dolist (key keys)
      (when-let ((val (alist-get key input-alist)))
          (setq args-alist (cons (cons key val) args-alist))))

    (list 'lambda '(_) `(,method ,args-alist))))
