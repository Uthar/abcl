;;; disassemble.lisp
;;;
;;; Copyright (C) 2005 Peter Graves
;;; $Id$
;;;
;;; This program is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU General Public License
;;; as published by the Free Software Foundation; either version 2
;;; of the License, or (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software
;;; Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
;;;
;;; As a special exception, the copyright holders of this library give you
;;; permission to link this library with independent modules to produce an
;;; executable, regardless of the license terms of these independent
;;; modules, and to copy and distribute the resulting executable under
;;; terms of your choice, provided that you also meet, for each linked
;;; independent module, the terms and conditions of the license of that
;;; module.  An independent module is a module which is not derived from
;;; or based on this library.  If you modify this library, you may extend
;;; this exception to your version of the library, but you are not
;;; obligated to do so.  If you do not wish to do so, delete this
;;; exception statement from your version.

(in-package :system)
(require :clos)

(defvar *disassembler-function* nil
  "The currently used function for CL:DISASSEMBLE.  

Available disassemblers are configured by pushing a strategy to SYSTEM:*DISASSEMBLERS*.  

SYSTEM:CHOOSE-DISASSEMBLER selects a current strategy from this list .")

(defvar *disassemblers*
  `((:system-javap . disassemble-class-bytes))
  "Methods of invoking CL:DISASSEMBLE consisting of a enumeration of (keyword function) pairs

The pairs (keyword function) contain a keyword identifying this
particulat disassembler, and a symbol designating function takes a
object to disassemble.

Use SYS:CHOOSE-DISASSEMBLER to install a given disassembler as the one
used by CL:DISASSEMBLE.  Additional disassemblers/decompilers are
packaged in the ABCL-INTROSPECT contrib.

The intial default is :javap using the javap command line tool which
is part of the Java Developement Kit.
")

(defun choose-disassembler (&optional name)
  "Report current disassembler that would be used by CL:DISASSEMBLE

With optional keyword NAME, select the associated disassembler from
SYS:*DISASSEMBLERS*."
  (flet ((sane-disassembler-p (disassembler)
           (and disassembler
                (fboundp disassembler))))
    (setf *disassembler-function*
          (if name
              (let ((disassembler (cdr (assoc name *disassemblers*))))
                (if (sane-disassembler-p disassembler)
                    disassembler
                    (error "Disassembler ~a doesn't appear to work." name)))
              (if (sane-disassembler-p *disassembler-function*)
                  *disassembler-function*
                  ;; simplest strategy: choose the first working one
                  (loop
                    :for (nil . disassembler) in *disassemblers*
                    :when (sane-disassembler-p disassembler)
                      :do (return disassembler)
                    :finally (warn "Can't find suitable disassembler.")))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro with-open ((name value) &body body)
    `(let ((,name ,value))
       (unwind-protect
           (progn ,@body)
         (java:jcall-raw "close" ,name)))))

(defun read-byte-array-from-stream (stream)
  (let ((buffer (java:jnew-array (java:jclass "byte") 4096)))
    (with-open (output (java:jnew "java.io.ByteArrayOutputStream"))
      (loop
        for length = (java:jcall "read" stream buffer)
        until (eql length -1)
        do (java:jcall-raw "write" output buffer 0 length))
      (java:jcall-raw "flush" output)
      (java:jcall-raw "toByteArray" output))))

(defun class-resource-path (class)
  (format NIL "~A.class" (substitute #\/ #\. (java:jcall "getName" class))))

(defun class-bytes (class)
  (with-open (stream (java:jcall-raw
                      "getResourceAsStream"
                      (java:jcall-raw "getClassLoader" class)
                      (class-resource-path class)))
    (read-byte-array-from-stream stream)))

(defun disassemble-bytes (bytes)
  "Disassemble jvm code BYTES returning a string."
  (funcall (or *disassembler-function* (choose-disassembler))
           bytes))

(defun disassemble-function (arg)
  (let ((function (cond ((java::java-object-p arg) 
                         (cond ((java::jinstance-of-p arg "java.lang.Class")
                                arg)
                               ((java::jinstance-of-p arg "java.lang.reflect.Method")
                                (java::jmethod-declaring-class arg))
                               ))
                        ((functionp arg)
                         arg)
                        ((symbolp arg)
                         (or (macro-function arg) (symbol-function arg)))
                        (t arg))))
    (when (typep function 'generic-function)
      (setf function (mop::funcallable-instance-function function)))
    ;; use isInstance instead of jinstance-of-p
    ;; because the latter checked java-object-p
    ;; which fails since its a lisp object
    (when (and (java:jcall "isInstance"  (java:jclass "org.armedbear.lisp.Closure") function)
               (not (java:jcall "isInstance"  (java:jclass "org.armedbear.lisp.CompiledClosure") function)))
      (return-from disassemble-function 
        (with-output-to-string (s)
          (format s "Not a compiled function: ~%")
          (pprint (java:jcall "getBody" function) s))))
    (let ((bytes (or (and (java:jcall "isInstance" (java:jclass "org.armedbear.lisp.Function") function)
                          (ignore-errors (getf (function-plist function))) 'class-bytes)
                     (and (java:jcall "isInstance" (java:jclass "org.armedbear.lisp.CompiledClosure") function)
                          (equalp (java::jcall "getName" (java::jobject-class 
                                                          (java:jcall "getClassLoader" (java::jcall "getClass" function))))
                                  "org.armedbear.lisp.FaslClassLoader")
                          (fasl-compiled-closure-class-bytes function)))))
      ;; we've got bytes here then we've covered the case that the disassembler already handled
      ;; If not then we've either got a primitive (in function) or we got passed a method object as arg.
      (if bytes
          (disassemble-bytes bytes)
          (let ((class (if (java:java-object-p function) function (java:jcall "getClass" function))))
            (let ((classloader (java:jcall "getClassLoader" class)))
              (if (or (java:jinstance-of-p classloader "org.armedbear.lisp.MemoryClassLoader")
                      (java:jinstance-of-p classloader "org.armedbear.lisp.FaslClassLoader"))
                  (disassemble-bytes 
                   (java:jcall "getFunctionClassBytes" classloader class))
                  (disassemble-bytes
                   (read-byte-array-from-stream
                    (java:jcall-raw
                     "getResourceAsStream"
                     (java:jcall-raw "getClassLoader" class)
                     (class-resource-path class)))))))))))

(defparameter +propertyList+ 
  (load-time-value
   (let ((it (find "propertyList" (java::jcall "getDeclaredFields" (java::jclass "org.armedbear.lisp.Function")) :key (lambda(e)(java::jcall "getName" e)) :test 'equal)))
     (java::jcall "setAccessible" it t)
     it)))

(defun function-plist (function)
  (java::jcall "get" +propertylist+ function))

(defun (setf function-plist) (new function)
  (java::jcall "set" +propertylist+ function new))

;; PITA. make loadedFrom public
;;; TODO Java9 work out a sensible story to preserve existing values if required
(defun get-loaded-from (function)
  (let* ((jfield (find "loadedFrom" (java:jcall "getDeclaredFields" (java:jclass "org.armedbear.lisp.Function")) 
                       :key 'java:jfield-name :test 'equal)))
    (java:jcall "setAccessible" jfield java:+true+)
    (java:jcall "get" jfield function)))

(defun set-loaded-from (function value)
  (let* ((jfield (find "loadedFrom" (java:jcall "getDeclaredFields" (java:jclass "org.armedbear.lisp.Function")) 
                       :key 'java:jfield-name :test 'equal)))
    (java:jcall "setAccessible" jfield java:+true+)
    (java:jcall "set" jfield function value)))

;; because getFunctionClassBytes gets a null pointer exception
(defun fasl-compiled-closure-class-bytes (function)
  (let* ((loaded-from (get-loaded-from function))
         (class-name (subseq (java:jcall "getName" (java:jcall "getClass" function)) (length "org.armedbear.lisp.")))
         (url (if (not (eq (pathname-device loaded-from) :unspecific))
                  ;; we're loading from a jar
                  (java:jnew "java.net.URL" 
                             (namestring (make-pathname :directory (pathname-directory loaded-from)
                                                               :device (pathname-device loaded-from)
                                                               :name class-name :type "cls")))
                  ;; we're loading from a fasl file
                  (java:jnew "java.net.URL" (namestring (make-pathname :device (list loaded-from)
                                                                       :name class-name :type "cls"))))))
    (read-byte-array-from-stream (java:jcall "openStream" url))))

;; closure bindings
;; (get-java-field (elt (#"get" (elt (#"getFields" (#"getClass" #'foo)) 0) #'foo) 0) "value")

(defun disassemble (arg)
  (print-lines-with-prefix (disassemble-function arg)))

(defun print-lines-with-prefix (string)
  (with-input-from-string (stream string)
    (loop
      (let ((line (read-line stream nil)))
        (unless line (return))
        (write-string "; ")
        (write-string line)
        (terpri)))))

