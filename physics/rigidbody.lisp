(in-package #:org.shirakumo.fraf.trial)

(defclass rigidbody (physics-entity transformed-entity)
  ((rotation :initform (vec 0 0 0) :reader rotation)
   (inverse-inertia-tensor :initform (mat3) :reader inverse-inertia-tensor)
   (torque :initform (vec 0 0 0) :reader torque)
   (angular-damping :initform 0.8 :accessor angular-damping)
   (physics-primitives :initform #() :accessor physics-primitives)
   ;; Cache
   (transform-matrix :initform (mat4) :reader transform-matrix)
   (world-inverse-inertia-tensor :initform (mat3) :reader world-inverse-inertia-tensor)
   (last-frame-acceleration :initform (vec 0 0 0) :reader last-frame-acceleration)))

(defmethod shared-initialize :after ((body rigidbody) slots &key inertia-tensor physics-primitives)
  (when inertia-tensor (setf (inertia-tensor body) inertia-tensor))
  (when physics-primitives (setf (physics-primitives body) physics-primitives)))

(defmethod (setf awake-p) :after ((false null) (entity rigidbody))
  (vsetf (rotation entity) 0 0 0))

(defmethod current-motion ((entity rigidbody))
  (+ (v. (velocity entity) (velocity entity))
     (v. (rotation entity) (rotation entity))))

(defmethod (setf rotation) ((vel vec3) (entity rigidbody))
  (v<- (rotation entity) vel))

(defmethod inertia-tensor ((entity rigidbody))
  (minv (inverse-inertia-tensor entity)))

(defmethod (setf inertia-tensor) ((mat mat3) (entity rigidbody))
  (let ((inv (minv mat)))
    (replace (marr3 (inverse-inertia-tensor entity)) (marr3 inv))))

(defmethod (setf inertia-tensor) ((primitive sphere) (entity rigidbody))
  (setf (inertia-tensor entity) (sphere-tensor (mass entity) (sphere-radius primitive))))

(defmethod (setf inertia-tensor) ((primitive box) (entity rigidbody))
  (setf (inertia-tensor entity) (box-tensor (mass entity) (box-bsize primitive))))

(defmethod (setf inertia-tensor) ((primitive cylinder) (entity rigidbody))
  (setf (inertia-tensor entity) (cylinder-tensor (mass entity) (cylinder-radius primitive) (cylinder-height primitive))))

(defmethod (setf physics-primitives) ((primitive primitive) (entity rigidbody))
  (setf (physics-primitives entity) (vector primitive))
  (when (and (/= 0 (inverse-mass entity))
             (every #'zerop (marr3 (inverse-inertia-tensor entity))))
    (setf (inertia-tensor entity) primitive)))

(defmethod (setf physics-primitives) :after ((primitives vector) (entity rigidbody))
  (loop for primitive across primitives
        do (setf (primitive-entity primitive) entity)))

(defun %update-rigidbody-cache (rigidbody)
  ;; NOTE: Re-normalising the orientation here aids in stability by eliminating drift.
  (nqunit (orientation rigidbody))
  (tmat4 (tf rigidbody) (transform-matrix rigidbody))
  (compute-world-inertia-tensor (world-inverse-inertia-tensor rigidbody) (inverse-inertia-tensor rigidbody) (transform-matrix rigidbody))
  (loop for primitive across (physics-primitives rigidbody)
        do (replace (marr4 (primitive-transform primitive))
                    (marr4 (transform-matrix rigidbody)))
           (nm* (primitive-transform primitive)
                (primitive-local-transform primitive))))

(defmethod impact-local ((entity rigidbody) force point)
  ;; NOTE: The FORCE direction is in world coordinates, and the POINT is in local coordinates
  (impact entity force (t*v (tf entity) point)))

(defmethod impact ((entity rigidbody) force point)
  (let ((local (v- point (location entity))))
    (nv+ (force entity) force)
    (nv+ (torque entity) (vc local force))))

(defmethod apply-force ((force spring-force) (entity rigidbody) dt)
  (let* ((lws (t*v (tf entity) (local-offset force)))
         (ows (t*v (tf (anchor force)) (anchor-offset force)))
         (force (v- lws ows))
         (coeff (* (spring-constant force) (abs (- (vlength force) (rest-length force))))))
    (impact entity (nv* (nvunit force) (- coeff)) lws)))

(defmethod apply-force ((force bungee-force) (entity rigidbody) dt)
  (let* ((lws (t*v (tf entity) (local-offset force)))
         (ows (t*v (tf (anchor force)) (anchor-offset force)))
         (force (v- lws ows))
         (coeff (* (spring-constant force) (- (vlength force) (rest-length force)))))
    (when (<= 0.0 coeff)
      (impact entity (nv* (nvunit force) (- coeff)) lws))))

(defmethod integrate ((entity rigidbody) dt)
  (let ((last-frame-acceleration (last-frame-acceleration entity))
        (angular-acceleration (m* (world-inverse-inertia-tensor entity) (torque entity))))
    (v<- last-frame-acceleration (force entity))
    (nv* (last-frame-acceleration entity) (inverse-mass entity))
    (nv+* (velocity entity) last-frame-acceleration dt)
    (nv+* (rotation entity) angular-acceleration dt)
    (nv* (velocity entity) (expt (damping entity) dt))
    (nv* (rotation entity) (expt (angular-damping entity) dt))
    (nv+* (location entity) (velocity entity) dt)
    (nv+* (location entity) last-frame-acceleration (* 0.5 dt dt))
    (nq+* (orientation entity) (rotation entity) dt)
    (nq+* (orientation entity) angular-acceleration (* 0.5 dt dt))
    (%update-rigidbody-cache entity)
    (vsetf (torque entity) 0 0 0)
    (vsetf (force entity) 0 0 0)))

(defmethod start-frame ((entity rigidbody))
  (%update-rigidbody-cache entity))
