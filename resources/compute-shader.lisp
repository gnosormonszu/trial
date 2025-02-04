#|
 This file is a part of trial
 (c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(defclass compute-shader (shader-program)
  ((shader-source :initarg :source :initform (arg! :source) :accessor shader-source)
   (shaders :initform ())
   (workgroup-size :initarg :workgroup-size :initform (vec 1 1 1) :accessor workgroup-size)))

(defmethod print-object ((shader compute-shader) stream)
  (print-unreadable-object (shader stream :type T :identity T)
    (format stream "~:[~;ALLOCATED~]" (allocated-p shader))))

(defmethod allocate ((shader compute-shader))
  (let ((source (shader-source shader))
        (shdr (gl:create-shader :compute-shader))
        (prog (gl:create-program)))
    (with-cleanup-on-failure (progn (gl:delete-shader shdr)
                                    (gl:delete-program prog)
                                    (setf (data-pointer shader) NIL))
      (with-new-value-restart (source input-source) (use-source "Supply new source code directly.")
        (unless (search "#version " source)
          (setf source (format NIL "~a~%~a" (glsl-version-header *context*) source))
          (when (eql :es (profile *context*))
            (setf source (glsl-toolkit:transform source :es (version *context*)))))
        (gl:shader-source shdr source)
        (gl:compile-shader shdr)
        (unless (gl:get-shader shdr :compile-status)
          (error 'shader-compilation-error :shader shader :log (gl:get-shader-info-log shdr)))
        (v:debug :trial.asset "Compiled shader ~a: ~%~a" shader source)
        (link-program shader (list shdr))
        (gl:delete-shader shdr)
        (setf (data-pointer shader) prog)))))

(defmethod activate ((shader compute-shader))
  (call-next-method)
  (let ((size (workgroup-size shader)))
    (%gl:dispatch-compute (truncate (vx size)) (truncate (vy size)) (truncate (vz size)))))
