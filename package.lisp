(defpackage #:lisp-mash
  (:nicknames #:metarepl.image.lisp-mash)
  (:documentation "lisp-mash main package")
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

(defpackage #:lisp-mash/mash
  (:nicknames #:metarepl.image.lisp-mash/mash #:mash)
  (:documentation "lisp-mash synced symbols")
  (:use )
  (:export))

(defpackage #:lisp-mash/minimal
  (:use #:cl)
  (:export #:register
           #:nodes
           #:eval-in))
