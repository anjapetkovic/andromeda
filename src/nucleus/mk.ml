open Nucleus_types

let fresh_atom x t =
  let x = Nonce.create x in
  { atom_nonce = x; atom_type = t }

let atom a = TermAtom a

let free_meta x abstr =
  let n = Nonce.create x in
  { meta_nonce =  n ; meta_boundary = abstr }

let bound k = TermBoundVar k

let type_constructor c args = TypeConstructor (c, args)

let type_meta m args = TypeMeta (m, args)

let term_constructor c args = TermConstructor (c, args)

let term_meta m args = TermMeta (m, args)

(** Make a term conversion, failing if a nested conversion would arise. *)
let term_convert_panic e asmp t =
  match e with
  | TermConvert _ -> assert false
  | _ -> TermConvert (e, asmp, t)

(** Make a term conversion, joining together a nested term conversion *without* checking types. *)
let term_convert_join e asmp t =
  match e with
  | TermConvert (e', asmp', t') ->
     let asmp'' = Assumption.(union (union asmp' asmp) (of_is_type ~lvl:0 t)) in
     TermConvert (e', asmp'', t)

  | _ -> TermConvert (e, asmp, t)

let arg_is_type t = JudgementIsType t
let arg_is_term e = JudgementIsTerm e
let arg_eq_type s = JudgementEqType s
let arg_eq_term s = JudgementEqTerm s

let eq_type asmp t1 t2 = EqType (asmp, t1, t2)

let eq_type_meta mv t1 t2 =
  let asmp =
    match mv with
    | MetaFree mv -> Assumption.add_free_meta mv.meta_nonce mv.meta_boundary Assumption.empty
    | MetaBound k -> Assumption.add_bound_meta k Assumption.empty
  in
  eq_type asmp t1 t2

let eq_term asmp e1 e2 t = EqTerm (asmp, e1, e2, t)

let eq_term_meta mv e1 e2 t =
  let asmp =
    match mv with
    | MetaFree mv -> Assumption.add_free_meta mv.meta_nonce mv.meta_boundary Assumption.empty
    | MetaBound k -> Assumption.add_bound_meta k Assumption.empty
  in
  eq_term asmp e1 e2 t

let not_abstract e = NotAbstract e

let abstract x t abstr = Abstract (x, t, abstr)
