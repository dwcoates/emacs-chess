;;; chess-ply.el --- Routines for manipulating chess plies

;; Copyright (C) 2002, 2004, 2008, 2014  Free Software Foundation, Inc.

;; Author: John Wiegley <johnw@gnu.org>
;; Maintainer: Mario Lang <mlang@delysid.org>
;; Keywords: games

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A ply is the differential between two positions.  Or, it is the
;; coordinate transformations applied to one position in order to
;; arrive at the following position.  It is also informally called "a
;; move".
;;
;; A ply is represented in Lisp using a cons cell of the form:
;;
;;   (BASE-POSITION .
;;    (FROM-COORD1 TO-COORD1 [FROM-COORD2 TO-COORD2] [KEYWORDS]))
;;
;; The KEYWORDS indicate special actions that are not really chess
;; moves:
;;
;;   :promote PIECE     ; promote pawn to PIECE on arrival
;;   :resign            ; a resignation causes the game to end
;;   :stalemate
;;   :repetition
;;   :perpetual
;;   :check             ; check is announced
;;   :checkmate
;;   :draw              ; a draw was offered and accepted
;;   :draw-offered      ; a draw was offered but not accepted
;;
;; A ply may be represented in ASCII by printing the FEN string of the
;; base position, and then printing the positional transformation in
;; algebraic notation.  Since the starting position is usually known,
;; the FEN string is optional.  A ply may be represented graphically
;; by moving the chess piece(s) involved.  It may be rendered verbally
;; by voicing which piece is to move, where it will move to, and what
;; will happen a result of the move (piece capture, check, etc).
;;
;; Plies may be sent over network connections, postal mail, e-mail,
;; etc., so long as the current position is maintained at both sides.
;; Transmitting the base position's FEN string along with the ply
;; offers a form of confirmation during the course of a game.

;;; Code:

(eval-when-compile (require 'cl-lib))

(require 'chess-pos)

(defgroup chess-ply nil
  "Routines for manipulating chess plies."
  :group 'chess)

(defsubst chess-ply-pos (ply)
  "Returns the base position associated with PLY."
  (cl-assert (listp ply))
  (car ply))

(defsubst chess-ply-set-pos (ply position)
  "Set the base position of PLY."
  (cl-assert (listp ply))
  (cl-assert (vectorp position))
  (setcar ply position))

(defsubst chess-ply-changes (ply)
  (cl-assert (listp ply))
  (cdr ply))

(defsubst chess-ply-set-changes (ply changes)
  (cl-assert (listp ply))
  (cl-assert (listp changes))
  (setcdr ply changes))

(defun chess-ply-any-keyword (ply &rest keywords)
  (cl-assert (listp ply))
  (catch 'found
    (dolist (keyword keywords)
      (if (memq keyword (chess-ply-changes ply))
	  (throw 'found keyword)))))

(defun chess-ply-keyword (ply keyword)
  (cl-assert (listp ply))
  (cl-assert (symbolp keyword))
  (let ((item (memq keyword (chess-ply-changes ply))))
    (if item
	(if (eq item (last (chess-ply-changes ply)))
	    t
	  (cadr item)))))

(defun chess-ply-set-keyword (ply keyword &optional value)
  (cl-assert (listp ply))
  (cl-assert (symbolp keyword))
  (let* ((changes (chess-ply-changes ply))
	 (item (memq keyword changes)))
    (if item
	(if value
	    (setcar (cdr item) value))
      (nconc changes (if value
			 (list keyword value)
		       (list keyword))))
    value))

(defsubst chess-ply-source (ply)
  "Returns the source square index value of PLY."
  (cl-assert (listp ply))
  (let ((changes (chess-ply-changes ply)))
    (and (listp changes) (not (symbolp (car changes)))
	 (car changes))))

(defsubst chess-ply-target (ply)
  "Returns the target square index value of PLY."
  (cl-assert (listp ply))
  (let ((changes (chess-ply-changes ply)))
    (and (listp changes) (not (symbolp (car changes)))
	 (cadr changes))))

(defsubst chess-ply-next-pos (ply)
  (cl-assert (listp ply))
  (or (chess-ply-keyword ply :next-pos)
      (let ((position (apply 'chess-pos-move
			     (chess-pos-copy (chess-ply-pos ply))
			     (chess-ply-changes ply))))
	(chess-pos-set-preceding-ply position ply)
	(chess-ply-set-keyword ply :next-pos position))))

(defconst chess-piece-name-table
  '(("queen"  . ?q)
    ("rook"   . ?r)
    ("knight" . ?n)
    ("bishop" . ?b)))

(defun chess-ply-castling-changes (position &optional long king-index)
  "Create castling changes; this function supports Fischer Random castling."
  (cl-assert (vectorp position))
  (let* ((color (if king-index (< (chess-pos-piece position king-index) ?a)
                  (chess-pos-side-to-move position)))
	 (king (or king-index (chess-pos-king-index position color)))
	 (rook (chess-pos-can-castle position (if color
						  (if long ?Q ?K)
						(if long ?q ?k))))
	 (bias (if long -1 1)) pos)
    (when rook
      (setq pos (chess-incr-index king 0 bias))
      (while (and pos (not (equal pos rook))
		  (chess-pos-piece-p position pos ? )
		  (or (and long (< (chess-index-file pos) 2))
		      (chess-pos-legal-candidates
		       position color pos (list king))))
	(setq pos (chess-incr-index pos 0 bias)))
      (if (equal pos rook)
	  (list king (chess-rf-to-index (if color 7 0) (if long 2 6))
		rook (chess-rf-to-index (if color 7 0) (if long 3 5))
		(if long :long-castle :castle))))))

(chess-message-catalog 'english
  '((ambiguous-promotion . "Promotion without :promote keyword")))

(defvar chess-ply-checking-mate nil)

(defsubst chess-ply-create* (position)
  (cl-assert (vectorp position))
  (list position))

(defconst promotion-options
  '((?q ?Q "[q]ueen")
    (?r ?R "(r)ook")
    (?b ?B "(b)ishop")
    (?n ?N "k(n)ight")))

(defun ask-promotion (white)
  (let ((prompts (mapcar (lambda (x) (nth 2 x)) promotion-options))
        (choices (append '(?\n ?\r) (mapcar (lambda (x) (car x)) promotion-options))))
    (nth (if white 1 0)
         (or 
          (assoc
           (read-char-choice (concat "Promote to: " (mapconcat 'identity prompts " ") " ? ")
                             choices t) promotion-options)
          (car promotion-options)))))

(defun chess-ply-create (position &optional valid-p &rest changes)
  "Create a ply from the given POSITION by applying the supplied CHANGES.
This function will guarantee the resulting ply is legal, and will also
annotate the ply with :check or other modifiers as necessary.  It will
also extend castling, and will prompt for a promotion piece.

Note: Do not pass in the rook move if CHANGES represents a castling
maneuver."
  (cl-assert (vectorp position))
  (let ((ply (cons position changes)))
    (if (integerp (car changes))
      (let* ((color (< (chess-pos-piece position (car changes)) ?a))
             (is-pre-move (not (eq color (chess-pos-side-to-move position))))
             piece)
        ;; validate that `changes' can be legally applied to the given
        ;; position
        (if (or valid-p
                (chess-legal-plies position :index (car changes)
                                   :target (cadr changes)))
          (unless chess-ply-checking-mate
            (setq piece (chess-pos-piece position (car changes)))
            ;; is this a castling maneuver?
            (if (and (= piece (if color ?K ?k))
                     (not (or (memq :castle changes)
                              (memq :long-castle changes))))
                (let* ((target (cadr changes))
                       (file (chess-index-file target))
                       (long (= 2 file))
                       new-changes)
                  (if (and (or (and (= file 6)
                                    (chess-pos-can-castle position
                                                          (if color ?K ?k)))
                               (and long
                                    (chess-pos-can-castle position
                                                          (if color ?Q ?q))))
                           (setq new-changes
                                 (chess-ply-castling-changes position long
                                                             (car changes))))
                      (setcdr ply new-changes)))

              (when (eq piece (if color ?P ?p))
                ;; is this a pawn move to the ultimate rank?  if so, check
                ;; that the :promote keyword is present.
                (when (and (not (memq :promote changes))
                           (= (if color 0 7)
                              (chess-index-rank (cadr changes))))
                  (let ((promo (if is-pre-move (nth (if color 1 0) (car promotion-options))
                                 (ask-promotion color))))
                    (nconc changes (list :promote promo))
                    (setq ply (cons position changes))))

                ;; is this an en-passant capture?
                (when (let ((ep (chess-pos-en-passant position)))
                        (when ep
                          (eq ep (funcall (if color #'+ #'-) (cadr changes) 8))))
                  (nconc changes (list :en-passant)))))

            ;; we must determine whether this ply results in a check,
            ;; checkmate or stalemate
            (unless (or chess-pos-always-white
                        (memq :check changes)
                        (memq :checkmate changes)
                        (memq :stalemate changes))
              (let* ((chess-ply-checking-mate t)
                     ;; jww (2002-04-17): this is a memory waste?
                     (next-pos (chess-ply-next-pos ply))
                     (next-color (not color))
                     (king (chess-pos-king-index next-pos next-color))
                     (in-check (catch 'in-check
                                 (chess-search-position next-pos king color t t))))
                ;; first, see if the moves leaves the king in check.
                ;; This is tested by seeing if any of the opponent's
                ;; pieces can reach the king in the position that will
                ;; result from this ply.  If the king is in check, we
                ;; will then test for checkmate by seeing if any of his
                ;; subjects can move or not.  That test will also
                ;; confirm stalemate for us.
                (if (or in-check
                        (null (chess-legal-plies next-pos :any :index king)))
                    ;; is the opponent's king in check/mate or stalemate
                    ;; now, as a result of the changes?
                    (if (chess-legal-plies next-pos :any :color next-color)
                        (if in-check
                            (nconc changes (list (chess-pos-set-status
                                                  next-pos :check))))
                      (nconc changes (list (chess-pos-set-status
                                            next-pos
                                            (if in-check
                                                :checkmate
                                              :stalemate)))))))))
	(setq ply nil))))
    ;; return the annotated ply
    ply))

(defsubst chess-ply-final-p (ply)
  "Return non-nil if this is the last ply of a game/variation."
  (or (chess-ply-any-keyword ply :drawn :perpetual :repetition
			     :flag-fell :resign :aborted)
      (chess-ply-any-keyword (chess-pos-preceding-ply
			      (chess-ply-pos ply)) :stalemate :checkmate)))

(defvar chess-ply-throw-if-any nil)

(defmacro chess-ply--add (rank-adj file-adj &optional pos)
  "This is totally a shortcut."
  `(let ((target (or ,pos (chess-incr-index candidate ,rank-adj ,file-adj))))
    (if (and (or (not specific-target)
		 (= target specific-target))
	     (chess-pos-legal-candidates position color target
					 (list candidate)))
	(if chess-ply-throw-if-any
	    (throw 'any-found t)
	  (let ((promotion (and (chess-pos-piece-p position candidate
						   (if color ?P ?p))
				(= (chess-index-rank target)
				   (if color 0 7)))))
	    (if promotion
		(dolist (promote '(?Q ?R ?B ?N))
		  (let ((ply (chess-ply-create position t candidate target
					       :promote promote)))
		    (when ply (push ply plies))))
	      (let ((ply (chess-ply-create position t candidate target)))
		(when ply (push ply plies)))))))))

(defun chess-legal-plies (position &rest keywords)
  "Return a list of all legal plies in POSITION.
KEYWORDS allowed are:

  :any   return t if any piece can move at all
  :color <t or nil>
  :piece <piece character>
  :file <number 0 to 7> [can only be used if :piece is present]
  :index <coordinate index>
  :target <specific target index>
  :candidates <list of inddices>

These will constrain the plies generated to those matching the above
criteria.

NOTE: All of the returned plies will reference the same copy of the
position object passed in."
  (cl-assert (vectorp position))
  (cond
   ((null keywords)
    (let ((plies (list t)))
      (dolist (p '(?P ?R ?N ?B ?K ?Q ?p ?r ?n ?b ?k ?q))
	(nconc plies (chess-legal-plies position :piece p)))
      (cdr plies)))
   ((memq :any keywords)
    (let ((chess-ply-throw-if-any t))
      (catch 'any-found
	(apply 'chess-legal-plies position (delq :any keywords)))))
   ((memq :color keywords)
    (let ((plies (list t)))
      (dolist (p (apply #'chess-pos-search* position (if (cadr (memq :color keywords))
							 '(?P ?N ?B ?R ?Q ?K)
						       '(?p ?n ?b ?r ?q ?k))))
	(when (cdr p)
	  (nconc plies (chess-legal-plies position
					  :piece (car p) :candidates (cdr p)))))
      (cdr plies)))
   (t
    (let* ((piece (cadr (memq :piece keywords)))
	   (color (if piece (< piece ?a)
                    (if (memq :index keywords)
                        (< (chess-pos-piece position
                                            (cadr (memq :index keywords))) ?a)
                      (chess-pos-side-to-move position))))
           (not-my-turn (not (eq color (chess-pos-side-to-move position))))
	   (specific-target (cadr (memq :target keywords)))
	   (test-piece
	    (upcase (or piece
			(chess-pos-piece position
					 (cadr (memq :index keywords))))))
	   (ep (when (eq test-piece ?P) (chess-pos-en-passant position)))
	   pos plies file)
      ;; since we're looking for moves of a particular piece, do a
      ;; more focused search
      (dolist (candidate
	       (cond
		((cadr (memq :candidates keywords))
		 (cadr (memq :candidates keywords)))
		((setq pos (cadr (memq :index keywords)))
		 (list pos))
		((setq file (cadr (memq :file keywords)))
		 (let (candidates)
		   (dotimes (rank 8)
		     (setq pos (chess-rf-to-index rank file))
		     (if (chess-pos-piece-p position pos piece)
			 (push pos candidates)))
		   candidates))
		(t
		 (chess-pos-search position piece))))
	(cond
	 ;; pawn movement, which is diagonal 1 when taking, but forward
	 ;; 1 or 2 when moving (the most complex piece, actually)
	 ((= test-piece ?P)
	  (let* ((ahead (chess-next-index candidate (if color
							chess-direction-north
						      chess-direction-south)))
		 (2ahead (when ahead (chess-next-index ahead (if color
								 chess-direction-north
							chess-direction-south)))))
	    (when (chess-pos-piece-p position ahead ? )
	      (chess-ply--add nil nil ahead)
	      (if (and (= (if color 6 1) (chess-index-rank candidate))
		       2ahead (chess-pos-piece-p position 2ahead ? ))
		  (chess-ply--add nil nil 2ahead)))
	    (when (setq pos (chess-next-index candidate
					      (if color
						  chess-direction-northeast
						chess-direction-southwest)))
	      (if (or not-my-turn (chess-pos-piece-p position pos (not color)))
		  (chess-ply--add nil nil pos)
		;; check for en passant capture toward kingside
		(when (and ep (= ep (funcall (if color #'+ #'-) pos 8)))
		  (chess-ply--add nil nil pos))))
	    (when (setq pos (chess-next-index candidate
					      (if color
						  chess-direction-northwest
						chess-direction-southeast)))
	      (if (or not-my-turn (chess-pos-piece-p position pos (not color)))
		  (chess-ply--add nil nil pos)
		;; check for en passant capture toward queenside
		(when (and ep (eq ep (funcall (if color #'+ #'-) pos 8)))
		  (chess-ply--add nil nil pos))))))

	 ;; the rook, bishop and queen are the easiest; just look along
	 ;; rank and file and/or diagonal for the nearest pieces!
	 ((memq test-piece '(?R ?B ?Q))
	  (dolist (dir (cond
			((= test-piece ?R) chess-rook-directions)
			((= test-piece ?B) chess-bishop-directions)
			((= test-piece ?Q) chess-queen-directions)))
	    (setq pos (chess-next-index candidate dir))
	    (while pos
	      (if (chess-pos-piece-p position pos ? )
		  (progn
		    (chess-ply--add nil nil pos)
		    (setq pos (chess-next-index pos dir)))
		(if (or not-my-turn (chess-pos-piece-p position pos (not color)))
		    (chess-ply--add nil nil pos))
		(setq pos nil)))))
         
	 ;; the king is a trivial case of the queen, except when castling
	 ((= test-piece ?K)
	  (dolist (dir chess-king-directions)
	    (setq pos (chess-next-index candidate dir))
	    (if (and pos (or not-my-turn
                             (chess-pos-piece-p position pos ? )
			     (chess-pos-piece-p position pos (not color))))
		(chess-ply--add nil nil pos)))

	  (unless (chess-search-position position candidate (not color) nil t)
	    (if (chess-pos-can-castle position (if color ?K ?k))
		(let ((changes (chess-ply-castling-changes position nil
							   candidate)))
		  (if changes
		      (if chess-ply-throw-if-any
			  (throw 'any-found t)
                        (if (or (not specific-target)
                                (= specific-target (cadr changes)))
                            (push (cons position changes) plies))))))

	    (if (chess-pos-can-castle position (if color ?Q ?q))
		(let ((changes (chess-ply-castling-changes position t
							   candidate)))
		  (if changes
		      (if chess-ply-throw-if-any
                          (throw 'any-found t)
                        (if (or (not specific-target)
                                (= specific-target (cadr changes)))
                            (push (cons position changes) plies))))))))

	 ;; the knight is a zesty little piece; there may be more than
	 ;; one, but at only one possible square in each direction
	 ((= test-piece ?N)
	  (dolist (dir chess-knight-directions)
	    ;; up the current file
	    (if (and (setq pos (chess-next-index candidate dir))
		     (or not-my-turn
                         (chess-pos-piece-p position pos ? )
			 (chess-pos-piece-p position pos (not color))))
		(chess-ply--add nil nil pos))))

	 (t (chess-error 'piece-unrecognized))))

      plies))))

(provide 'chess-ply)

;;; chess-ply.el ends here
