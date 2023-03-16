(in-package #:org.shirakumo.fraf.trial)

(defstruct (contact (:include hit))
  (to-world (mat3) :type mat3)
  (velocity (vec3 0 0 0) :type vec3)
  (desired-delta 0.0 :type single-float)
  (a-relative (vec3 0 0 0) :type vec3)
  (b-relative (vec3 0 0 0) :type vec3)
  (a-rotation-change (vec3 0 0 0) :type vec3)
  (b-rotation-change (vec3 0 0 0) :type vec3)
  (a-velocity-change (vec3 0 0 0) :type vec3)
  (b-velocity-change (vec3 0 0 0) :type vec3))

(defun hit-basis (hit &optional (basis (mat3)))
  (let ((normal (hit-normal hit))
        (tangent-0 (vec3 0 0 0))
        (tangent-1 (vec3 0 0 0)))
    (declare (dynamic-extent tangent-0 tangent-1))
    (cond ((< (abs (vy normal)) (abs (vx normal)))
           (let ((s (/ (sqrt (+ (* (vz normal) (vz normal))
                                (* (vx normal) (vx normal)))))))
             (vsetf tangent-0 (* (vz normal) s) 0.0 (- (* (vx normal) s)))
             (vsetf tangent-1
                    (* (vy normal) (vz tangent-0))
                    (- (* (vz normal) (vx tangent-0))
                       (* (vx normal) (vz tangent-0)))
                    (- (* (vy normal) (vx tangent-0))))))
          (T
           (let ((s (/ (sqrt (+ (* (vz normal) (vz normal))
                                (* (vy normal) (vy normal)))))))
             (vsetf tangent-0 0.0 (- (* (vz normal) s)) (* (vy normal) s))
             (vsetf tangent-1
                    (- (* (vy normal) (vz tangent-0))
                       (* (vz normal) (vy tangent-0)))
                    (- (* (vx normal) (vz tangent-0)))
                    (* (vx normal) (vy tangent-0))))))
    (with-fast-matref (m basis 3)
      (setf (m 0) (vx normal))
      (setf (m 1) (vx tangent-0))
      (setf (m 2) (vx tangent-1))
      (setf (m 3) (vy normal))
      (setf (m 4) (vy tangent-0))
      (setf (m 5) (vy tangent-1))
      (setf (m 6) (vz normal))
      (setf (m 7) (vz tangent-0))
      (setf (m 8) (vz tangent-1))
      basis)))

(defun local-velocity (to-world entity loc dt)
  (let ((vel (ntransform-inverse
              (nv+ (vc (rotation entity) loc)
                   (velocity entity))
              to-world))
        (acc (ntransform-inverse
              (v* (last-frame-acceleration entity) dt)
              to-world)))
    (setf (vx acc) 0.0)
    (nv+ vel acc)))

(defun desired-delta-velocity (hit velocity dt)
  (flet ((acc (entity)
           (v. (v* (last-frame-acceleration entity) dt)
               (hit-normal hit))))
    (let ((vel-from-acc (- (acc (hit-a hit))
                           (acc (hit-b hit))))
          (restitution (hit-restitution hit))
          (vx (vx velocity)))
      (when (< (abs vx) 0.25) ; Some kinda velocity limit magic number?
        (setf restitution 0.0))
      (+ (- vx) (* (- restitution) (- vx vel-from-acc))))))

(defun upgrade-hit-to-contact (hit dt)
  (let* ((to-world (hit-basis hit))
         (a-relative (v- (hit-location hit) (location (hit-a hit))))
         (b-relative (v- (hit-location hit) (location (hit-b hit))))
         (velocity (nv- (local-velocity to-world (hit-a hit) a-relative dt)
                        (local-velocity to-world (hit-b hit) b-relative dt)))
         (desired-delta (desired-delta-velocity hit velocity dt)))
    (setf (contact-to-world hit) to-world)
    (setf (contact-velocity hit) velocity)
    (setf (contact-desired-delta hit) desired-delta)
    (setf (contact-a-relative hit) a-relative)
    (setf (contact-b-relative hit) b-relative)
    (vsetf (contact-a-rotation-change hit) 0 0 0)
    (vsetf (contact-a-velocity-change hit) 0 0 0)
    (vsetf (contact-b-rotation-change hit) 0 0 0)
    (vsetf (contact-b-velocity-change hit) 0 0 0)
    hit))

(defun match-awake-state (contact)
  (let ((a (contact-a contact))
        (b (contact-b contact)))
    (when (and (/= 0 (inverse-mass a))
               (/= 0 (inverse-mass b))
               (xor (awake-p a) (awake-p b)))
      (if (awake-p a)
          (setf (awake-p b) T)
          (setf (awake-p a) T)))))

(defun frictionless-impulse (contact &optional (impulse (vec3 0 0 0)))
  (flet ((body-delta-vel (loc body)
           (let ((delta-vel (vc loc (contact-normal contact))))
             (n*m (world-inverse-inertia-tensor body) delta-vel)
             (setf delta-vel (vc delta-vel loc))
             (+ (inverse-mass body) (v. delta-vel (contact-normal contact))))))
    (vsetf impulse
           (/ (contact-desired-delta contact)
              (+ (body-delta-vel (contact-a-relative contact) (contact-a contact))
                 (body-delta-vel (contact-b-relative contact) (contact-b contact))))
           0.0
           0.0)))

(defun frictionful-impulse (contact &optional (impulse (vec3 0 0 0)))
  (flet ((delta-vel (loc inverse-inertia-tensor)
           (let* ((impulse-to-torque (mat 0 (- (vz loc)) (vy loc)
                                          (vz loc) 0 (- (vx loc))
                                          (- (vy loc)) (vx loc) 0))
                  (delta-vel-world (mcopy impulse-to-torque)))
             (nm* delta-vel-world inverse-inertia-tensor)
             (nm* delta-vel-world impulse-to-torque)
             (nm* delta-vel-world -1)
             delta-vel-world)))
    (let* ((inverse-mass (+ (inverse-mass (contact-a contact))
                            (inverse-mass (contact-a contact))))
           (delta-vel (nm+ (delta-vel (contact-a-relative contact)
                                      (world-inverse-inertia-tensor (contact-a contact)))
                           (delta-vel (contact-b-relative contact)
                                      (world-inverse-inertia-tensor (contact-b contact)))))
           (delta-velocity (nm* (mtranspose (contact-to-world contact))
                                delta-vel
                                (contact-to-world contact))))
      (with-fast-matref (m delta-velocity 3)
        (incf (m 0) inverse-mass)
        (incf (m 4) inverse-mass)
        (incf (m 8) inverse-mass))
      (vsetf impulse
             (contact-desired-delta contact)
             (- (vy (contact-velocity contact)))
             (- (vz (contact-velocity contact))))
      (let* ((impulse-matrix (minv delta-velocity))
             (impulse (n*m impulse-matrix impulse))
             (planar (sqrt (+ (* (vy impulse) (vy impulse))
                              (* (vz impulse) (vz impulse)))))
             (dynamic-friction (contact-dynamic-friction contact)))
        (when (< (* (vx impulse) (contact-static-friction contact)) planar)
          (setf (vy impulse) (/ (vy impulse) planar))
          (setf (vz impulse) (/ (vz impulse) planar))
          (setf (vx impulse) (/ (contact-desired-delta contact)
                                (+ (miref3 delta-vel 0)
                                   (* (miref3 delta-vel 1) dynamic-friction (vy impulse))
                                   (* (miref3 delta-vel 2) dynamic-friction (vz impulse)))))
          (setf (vy impulse) (* (vy impulse) dynamic-friction (vx impulse)))
          (setf (vz impulse) (* (vz impulse) dynamic-friction (vx impulse))))
        impulse))))

(defun apply-velocity-change (contact)
  (let ((impulse (vec 0 0 0)))
    (declare (dynamic-extent impulse))
    (if (and (= 0 (contact-static-friction contact))
             (= 0 (contact-dynamic-friction contact)))
        (frictionless-impulse contact impulse)
        (frictionful-impulse contact impulse))
    (n*m (contact-to-world contact) impulse)
    (let ((entity (contact-a contact))
          (velocity-change (contact-a-velocity-change contact))
          (rotation-change (contact-a-rotation-change contact)))
      (v<- rotation-change (vc (contact-a-relative contact) impulse))
      (n*m (world-inverse-inertia-tensor entity) rotation-change)
      (vsetf velocity-change 0 0 0)
      (nv+* velocity-change impulse (inverse-mass entity))
      (nv+ (velocity entity) velocity-change)
      (nv+ (rotation entity) rotation-change))
    ;; Second body needs to invert the direction.
    (let ((entity (contact-b contact))
          (velocity-change (contact-b-velocity-change contact))
          (rotation-change (contact-b-rotation-change contact)))
      (v<- rotation-change (vc impulse (contact-b-relative contact)))
      (n*m (world-inverse-inertia-tensor entity) rotation-change)
      (vsetf velocity-change 0 0 0)
      (nv+* velocity-change impulse (- (inverse-mass entity)))
      (nv+ (velocity entity) velocity-change)
      (nv+ (rotation entity) rotation-change))))

(defun apply-position-change (contact)
  (flet ((angular-inertia (entity loc)
           (v. (vc (n*m (world-inverse-inertia-tensor entity)
                        (vc loc (contact-normal contact)))
                   loc)
               (contact-normal contact)))
         (linear-inertia (entity)
           (inverse-mass entity))
         (change (entity loc angular-inertia linear-inertia total-inertia
                         angular-change linear-change)
           (let ((angular-move (* (contact-depth contact)
                                  (/ angular-inertia total-inertia)))
                 (linear-move (* (contact-depth contact)
                                 (/ linear-inertia total-inertia)))
                 (projection (v* (contact-normal contact)
                                 (- (v. loc (contact-normal contact))))))
             (nv+ projection loc)
             (let ((max (* 0.2       ; Some kinda angular limit magic.
                           (vlength projection)))
                   (total (+ angular-move linear-move)))
               (cond ((< angular-move (- max))
                      (setf angular-move (- max))
                      (setf linear-move (- total angular-move)))
                     ((< max angular-move)
                      (setf angular-move max)
                      (setf linear-move (- total angular-move))))
               (cond ((= 0 angular-move)
                      (vsetf angular-change 0 0 0))
                     (T
                      (let ((target-direction (vc loc (contact-normal contact)))
                            (inverse-tensor (world-inverse-inertia-tensor entity)))
                        (v<- angular-change (n*m inverse-tensor target-direction))
                        (nv* angular-change (/ angular-move angular-inertia)))))
               (v<- linear-change (v* (contact-normal contact) linear-move))
               (nv+ (location entity) linear-change)
               (nq+* (orientation entity) angular-change 1.0)
               (unless (awake-p entity)
                 (%update-rigidbody-cache entity))))))
    (let* ((a (contact-a contact))
           (b (contact-b contact))
           (a-angular-inertia (angular-inertia a (contact-a-relative contact)))
           (b-angular-inertia (angular-inertia b (contact-b-relative contact)))
           (a-linear-inertia (linear-inertia a))
           (b-linear-inertia (linear-inertia b))
           (total-inertia (+ a-angular-inertia b-angular-inertia
                             a-linear-inertia b-linear-inertia)))
      (unless (= 0 (inverse-mass a))
        (change a (contact-a-relative contact) a-angular-inertia a-linear-inertia total-inertia
                (contact-a-rotation-change contact) (contact-a-velocity-change contact)))
      (unless (= 0 (inverse-mass b))
        (change b (contact-b-relative contact) b-angular-inertia b-linear-inertia (- total-inertia)
                (contact-b-rotation-change contact) (contact-b-velocity-change contact))))))

(defun resolve-contacts (system contacts end dt &key (iterations 200))
  (macrolet ((do-contacts ((contact) &body body)
               `(loop for i from 0 below end
                      for ,contact = (aref contacts i)
                      do (progn ,@body)))
             (do-update (args &body body)
               `(do-contacts (other)
                  (flet ((change ,args
                           ,@body))
                    (when (eq (contact-a other) (contact-a contact))
                      (change (contact-a-rotation-change contact)
                              (contact-a-velocity-change contact)
                              (contact-a-relative other) -1))
                    (when (eq (contact-a other) (contact-b contact))
                      (change (contact-b-rotation-change contact)
                              (contact-b-velocity-change contact)
                              (contact-a-relative other) -1))
                    (when (eq (contact-b other) (contact-a contact))
                      (change (contact-a-rotation-change contact)
                              (contact-a-velocity-change contact)
                              (contact-b-relative other) +1))
                    (when (eq (contact-b other) (contact-b contact))
                      (change (contact-b-rotation-change contact)
                              (contact-b-velocity-change contact)
                              (contact-b-relative other) +1))))))
    ;; Prepare Contacts
    (do-contacts (contact)
      (upgrade-hit-to-contact contact dt))
    
    ;; Adjust Positions
    (loop repeat iterations
          for worst = (depth-eps system)
          for contact = NIL
          for contact-i = -1
          do (do-contacts (tentative)
               (when (< worst (contact-depth tentative))
                 (setf contact tentative)
                 (setf contact-i i)
                 (setf worst (contact-depth contact))))
             (unless contact (return))
             (match-awake-state contact)
             (apply-position-change contact)
             ;; We now need to fix up the contact depths.
             (do-update (rotation-change velocity-change loc sign)
               (incf (contact-depth other)
                     (* sign (v. (nv+ (vc rotation-change loc) velocity-change)
                                 (contact-normal other)))))
          finally (dbg "Adjust position overflow"))

    ;; Adjust Velocities
    (loop repeat iterations
          for worst = (velocity-eps system) ;; Some kinda epsilon.
          for contact = NIL
          for contact-i = -1
          do (do-contacts (tentative)
               (when (< worst (contact-desired-delta tentative))
                 (setf contact tentative)
                 (setf contact-i i)
                 (setf worst (contact-desired-delta contact))))
             (unless contact (return))
             (match-awake-state contact)
             (apply-velocity-change contact)
             (do-update (rotation-change velocity-change loc sign)
               (let* ((delta (v+ (vc rotation-change loc) velocity-change))
                      (tmp (ntransform-inverse delta (contact-to-world other))))
                 (nv+* (contact-velocity other) tmp (- sign))
                 (setf (contact-desired-delta other)
                       (desired-delta-velocity other (contact-velocity other) dt))))
          finally (dbg "Adjust velocity overflow"))))

(defclass rigidbody-system (physics-system)
  ((contact-data :initform (make-contact-data) :accessor contact-data)
   (velocity-eps :initform 0.01 :initarg :velocity-eps :accessor velocity-eps)
   (depth-eps :initform 0.01 :initarg :depth-eps :accessor depth-eps)))

(defmethod (setf units-per-metre) (units (system rigidbody-system))
  ;; The default we pick here is for assuming 1un = 1cm
  (call-next-method)
  (setf (velocity-eps system) (* 0.01 units))
  (setf (depth-eps system) (* 0.01 units)))

(defmethod update ((system rigidbody-system) tt dt fc)
  (call-next-method)
  (let ((objects (%objects system)))
    (let ((data (contact-data system)))
      (setf (contact-data-start data) 0)
      ;; Compute contacts
      ;; TODO: replace with something that isn't as dumb as this.
      ;;       particularly: use a spatial query structure to speed up
      ;;       the search of close objects, and then process close objects
      ;;       in batches to avoid updating contacts that are far apart
      ;;       in the resolver.
      (loop for i from 0 below (length objects)
            for a = (aref objects i)
            do (loop for j from (1+ i) below (length objects)
                     for b = (aref objects j)
                     do (loop for a-p across (physics-primitives a)
                              do (loop for b-p across (physics-primitives b)
                                       do (detect-hits a-p b-p data)))))
      ;; Resolve contacts
      (when (< 0 (contact-data-start data))
        (resolve-contacts system (contact-data-hits data) (contact-data-start data) dt)))))
