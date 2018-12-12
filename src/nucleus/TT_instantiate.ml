(** Instantiate *)

open Jdg_typedefs
open TT_assumption
open TT_shift
open TT_error

let rec instantiate_abstraction
  : 'a .(term -> ?lvl:bound -> 'a -> 'a) ->
        term -> ?lvl:bound -> 'a abstraction -> 'a abstraction
  = fun inst_v e0 ?(lvl=0) ->
  function
  | NotAbstract v ->
     let v = inst_v e0 ~lvl v in
     NotAbstract v

  | Abstract (x, u, abstr) ->
     let u = instantiate_type e0 ~lvl u
     and abstr = instantiate_abstraction inst_v e0 ~lvl:(lvl+1) abstr
     in
     Abstract (x, u, abstr)

and instantiate_term e0 ?(lvl=0) = function

    | TermAtom _ as e -> e (* there are no bound variables in an atom type *)

    | TermConstructor (c, args) ->
       let args = instantiate_arguments e0 ~lvl args in
       TermConstructor (c, args)

    | TermMeta (mv, args) ->
       (* there are no bound variables in the type of a meta *)
       let args = instantiate_term_arguments e0 ~lvl args in
       TermMeta (mv, args)

    | TermConvert (e, asmp, t) ->
       let e = instantiate_term e0 ~lvl e
       and asmp = instantiate_assumptions e0 ~lvl asmp
       and t = instantiate_type e0 ~lvl t in
       TermConvert (e, asmp, t)

    | TermBound k as e ->
       if k < lvl then
         e
       else begin
         (* We should only ever instantiate the highest occurring bound variable. *)
         assert (k = lvl) ;
         shift_term ~lvl:0 lvl e0
       end

and instantiate_type e0 ?(lvl=0) = function
  | TypeConstructor (c, args) ->
     let args = instantiate_arguments e0 ~lvl args in
     TypeConstructor (c, args)

  | TypeMeta (mv, args) ->
     (* there are no bound variables in the type of a meta *)
     let args = instantiate_term_arguments e0 ~lvl args in
     TypeMeta (mv, args)

and instantiate_arguments e0 ~lvl args =
  List.map (instantiate_argument e0 ~lvl) args

and instantiate_term_arguments e0 ~lvl args =
  List.map (instantiate_term e0 ~lvl) args

and instantiate_argument e0 ?(lvl=0) = function

    | ArgIsType t ->
       let t = instantiate_abstraction instantiate_type e0 ~lvl t in
       ArgIsType t

    | ArgIsTerm e ->
       let e = instantiate_abstraction instantiate_term e0 ~lvl e in
       ArgIsTerm e

    | ArgEqType asmp ->
       let asmp = instantiate_abstraction instantiate_eq_type e0 ~lvl asmp in
       ArgEqType asmp

    | ArgEqTerm asmp ->
       let asmp = instantiate_abstraction instantiate_eq_term e0 ~lvl asmp in
       ArgEqTerm asmp

and instantiate_eq_type e0 ?(lvl=0) (EqType (asmp, t1, t2)) =
  let asmp = instantiate_assumptions e0 ~lvl asmp
  and t1 = instantiate_type e0 ~lvl t1
  and t2 = instantiate_type e0 ~lvl t2 in
  EqType (asmp, t1, t2)

and instantiate_eq_term e0 ?(lvl=0) (EqTerm (asmp, e1, e2, t)) =
  let asmp = instantiate_assumptions e0 ~lvl asmp
  and e1 = instantiate_term e0 ~lvl e1
  and e2 = instantiate_term e0 ~lvl e2
  and t = instantiate_type e0 ~lvl t in
  EqTerm (asmp, e1, e2, t)

and instantiate_assumptions e0 ?(lvl=0) asmp =
  let asmp0 = assumptions_term ~lvl e0 in
  Assumption.instantiate ~lvl asmp0 asmp

let rec fully_instantiate_type ?(lvl=0) es = function
  | TypeConstructor (c, args) ->
     let args = fully_instantiate_args ~lvl es args in
     TypeConstructor (c, args)
  | TypeMeta (mv, args) ->
     let args = fully_instantiate_term_args ~lvl es args in
     (* there are no bound variables in the type of a meta *)
     TypeMeta (mv, args)

and fully_instantiate_term ?(lvl=0) es = function

  | TermAtom _ as e -> e (* there are no bound variables in an atom type *)

  | (TermBound k) as e ->
     if k < lvl then
       e
     else
       begin try
         let e = List.nth es (k - lvl)
         in shift_term ~lvl:0 lvl e
       with
         Failure _ -> error InvalidInstantiation
       end

  | TermConstructor (c, args) ->
     let args = fully_instantiate_args ~lvl es args in
     TermConstructor (c, args)

  | TermMeta (mv, args) ->
     let args = fully_instantiate_term_args ~lvl es args in
     (* there are no bound variables in the type of a meta *)
     TermMeta (mv, args)

  | TermConvert (e, asmp, t) ->
     let e = fully_instantiate_term ~lvl es e
     and asmp = fully_instantiate_assumptions ~lvl es asmp
     and t = fully_instantiate_type ~lvl es t
     in TermConvert (e, asmp, t)

and fully_instantiate_eq_type ?(lvl=0) es (EqType (asmp, t1, t2)) =
  let asmp = fully_instantiate_assumptions ~lvl es asmp
  and t1 = fully_instantiate_type ~lvl es t1
  and t2 = fully_instantiate_type ~lvl es t2
  in EqType (asmp, t1, t2)

and fully_instantiate_eq_term ?(lvl=0) es (EqTerm (asmp, e1, e2, t)) =
  let asmp = fully_instantiate_assumptions ~lvl es asmp
  and e1 = fully_instantiate_term ~lvl es e1
  and e2 = fully_instantiate_term ~lvl es e2
  and t = fully_instantiate_type ~lvl es t
  in EqTerm (asmp, e1, e2, t)


and fully_instantiate_assumptions ~lvl es asmp =
  let asmps = List.map (assumptions_term ~lvl) es in
  Assumption.fully_instantiate asmps ~lvl asmp

and fully_instantiate_args ?(lvl=0) es args =
  List.map (fully_instantiate_arg ~lvl es) args

and fully_instantiate_term_args ?(lvl=0) es args =
  List.map (fully_instantiate_term ~lvl es) args

and fully_instantiate_arg ?(lvl=0) es = function
  | ArgIsType abstr ->
     let abstr = fully_instantiate_abstraction fully_instantiate_type ~lvl es abstr in
     ArgIsType abstr

  | ArgIsTerm abstr ->
     let abstr = fully_instantiate_abstraction fully_instantiate_term ~lvl es abstr in
     ArgIsTerm abstr

  | ArgEqType abstr ->
     let abstr = fully_instantiate_abstraction fully_instantiate_eq_type ~lvl es abstr in
     ArgEqType abstr

  | ArgEqTerm abstr ->
     let abstr = fully_instantiate_abstraction fully_instantiate_eq_term ~lvl es abstr in
     ArgEqTerm abstr

and fully_instantiate_abstraction
  : 'a . (?lvl:int -> term list -> 'a -> 'a) ->
         ?lvl:int -> term list -> 'a abstraction -> 'a abstraction
  = fun inst_u ?(lvl=0) es -> function

  | NotAbstract u ->
     let u = inst_u ~lvl es u in
     NotAbstract u

  | Abstract (x, t, abstr) ->
     let t = fully_instantiate_type ~lvl es t
     and abstr = fully_instantiate_abstraction inst_u ~lvl:(lvl+1) es abstr
     in Abstract (x, t, abstr)
