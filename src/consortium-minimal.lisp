(in-package :consortium/minimal)

;; Filesystem coordination because images are in separate OS processes.
(defvar *registry* (merge-pathnames ".consortium/" (user-homedir-pathname)))

(defun register (name &optional (port (+ 40000 (random 100))))
  "Register this image and start micros."
  (ensure-directories-exist *registry*)
  (micros:create-server :port port :dont-close t)
  (with-open-file (s (merge-pathnames (format nil "~(~A~)" name) *registry*)
                     :direction :output :if-exists :supersede)
    (prin1 (list :name name :port port) s))
  (format t "~&[consortium] ~A on port ~A~%" name port))

(defun nodes ()
  "List all registered nodes."
  (loop for f in (directory (merge-pathnames "*" *registry*))
        collect (with-open-file (s f) (read s))))

(defun eval-at (name form)
  (uiop:not-implemented-error "replace swank with micros"))

;; (defun eval-at (name form)
;;   "Evaluate FORM at NAME."
;;   (let* ((info (find name (nodes) :key (lambda (i) (getf i :name)) :test #'string-equal))
;;          (port (getf info :port)))
;;     (micros-client:with-slime-connection (c "localhost" port)
;;       (micros-client:slime-eval form c))))
