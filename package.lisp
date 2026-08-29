(defpackage #:consortium
  (:nicknames #:metarepl.image.consortium)
  (:documentation "consortium main package")
  (:use #:cl)
  ;;                                       ; &&&
  ;; (:shadow &&&)
  ;;                                       ; shadowing other symbols, declares dominant function
  ;; (:shadowing-import-from #:cmd #:current-directory)
  ;;                                       ; specific symbol import to this package, encouraged
  ;; (:import-from #:uiop
  ;;               #:subdirectories #:directory-files :getcwd)
  ;;                                       ; rename package and or function, nick original-name
  ;; (:local-nicknames (#:jzon #:com.inuoe.jzon))
  ;; ;; #:str #:cmd #:file-finder

  (:export #:register-image
           #:unregister-image
           #:nodes
           #:eval-in
           #:broadcast
           #:sync-all
           #:import-remote-symbols
           #:*registry-path*))

(defpackage #:consortium/sync
  (:documentation "synced symbols")
  (:use )
  (:export))

(defpackage #:consortium/minimal
  (:use #:cl)
  (:export #:register
           #:nodes
           #:eval-in))
