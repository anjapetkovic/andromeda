(** Type-directed phase of equality checking *)

open Eqchk_common

(** The type of extensionality rules. *)
type equation =
  { ext_pattern : Patt.is_type (* the rewrite pattern to match the type of equality *)
  ; ext_rule : Nucleus.eq_term Nucleus.rule (* the associated rule *)
  }

let make_equation drv =

  (* Check that e is the bound meta-variable k *)
  let check_meta k e =
    match e with
    | Nucleus_types.(TermMeta (MetaBound j, [])) -> if j <> k then raise (EqchkError (Invalid_rule (WrongMetavariable (k, j))))
    | Nucleus_types.(TermMeta (MetaFree _, _) | TermMeta (MetaBound _, _::_) | TermBoundVar _ | TermAtom _ |
                     TermConstructor _ | TermConvert _) ->
       raise (EqchkError (Invalid_rule (BoundMetavariableExpected (k, e))))
  in

  (* Extract a type from an optional boundary *)
  let extract_type = function
    | Some (Nucleus_types.(NotAbstract (BoundaryIsTerm t))) -> t
    | Some (Nucleus_types.(Abstract _ ) as abst) -> raise (EqchkError (Invalid_rule (TermBoundaryExpectedGotAbstraction abst)))
    | Some (Nucleus_types.(NotAbstract (BoundaryIsType _ | BoundaryEqType _ | BoundaryEqTerm _ as b ))) ->
      raise (EqchkError (Invalid_rule (TermBoundaryExpected b)))
    | None ->
       raise (EqchkError (Invalid_rule (TermBoundaryNotGiven)))
  in

  (* do the main work where:
     n_ob counts leading object premises, n_eq counts trailing equality premises,
     (bdry1opt, bdry2opt) are the last two seen object premise boundaries
  *)
  let rec fold (bdry1opt, bdry2opt) n_ob n_eq = function

    | Nucleus_types.(Conclusion eq) ->
       let (Nucleus_types.EqTerm (_asmp, e1, e2, t)) = Nucleus.expose_eq_term eq in
       begin
       try (* check LHS *)
         check_meta (n_eq+1) e1
       with
         EqchkError( Invalid_rule _ ) -> raise (EqchkError (Invalid_rule (EquationLHSnotCorrect (eq, n_eq + 1))))
       end ;
       begin
       try (* check RHS *)
         check_meta n_eq e2
       with
          EqchkError ( Invalid_rule _ ) -> raise (EqchkError (Invalid_rule (EquationRHSnotCorrect (eq, n_eq))))
       end ;
       let t1 = extract_type bdry1opt in
       let t1' = Shift_meta.is_type (n_eq+2) t1
       and t2' = Shift_meta.is_type (n_eq+1) (extract_type bdry2opt) in
       (* check that types are equal *)
       if not (Alpha_equal.is_type t1' t) || not (Alpha_equal.is_type t2' t) then raise (EqchkError (Invalid_rule (TypeOfEquationMismatch (eq, t1', t2')))); ;
       let patt = Eqchk_pattern.make_is_type (n_ob-2) t1 in
       let s = head_symbol_type t1 in
       (s, patt)

    | Nucleus_types.(Premise ({meta_boundary=bdry;_} as p, drv)) ->
       if is_object_premise bdry then
         begin
           if n_eq > 0 then raise (EqchkError (Invalid_rule (ObjectPremiseAfterEqualityPremise p)));
           fold (bdry2opt, Some bdry) (n_ob + 1) n_eq drv
         end
       else
         fold (bdry1opt, bdry2opt) n_ob (n_eq + 1) drv
  in

  (* Put the derivation into the required form *)
  let drv =
    match Nucleus.as_eq_term_rule drv with
    | Some drv -> drv
    | None -> raise ( EqchkError(Invalid_rule (DerivationWrongForm drv)))
  in
  (* Collect head symbol and pattern (and verify that drv has the correct form) *)
  let s, patt = fold (None, None) 0 0 (Nucleus.expose_rule drv) in
  s, { ext_pattern = patt; ext_rule = drv }

(** Find an extensionality rule for [e1 == e2 : t], if there is one, return a rule
   application that will prove it. *)
and find ext_eqs sgn bdry =
  let (e1, e2, t) = Nucleus.invert_eq_term_boundary bdry in
  match SymbolMap.find_opt (head_symbol_type (Nucleus.expose_is_type t)) ext_eqs with
  | None -> None
  | Some lst ->
     let rec fold = function
       | [] -> None
       | {ext_pattern=patt; ext_rule=rl} :: lst ->
          begin match Eqchk_pattern.match_is_type sgn t patt with
          | None -> fold lst
          | Some args ->
             let rap = Nucleus.form_eq_term_rap sgn rl in
             let arg1 = Nucleus.(abstract_not_abstract (JudgementIsTerm e1))
             and arg2 = Nucleus.(abstract_not_abstract (JudgementIsTerm e2)) in
             try
               Some (rap_apply rap (args @ [arg1; arg2]))
             with
              | Fatal_error _ -> fold lst
          end
     in
     fold lst
