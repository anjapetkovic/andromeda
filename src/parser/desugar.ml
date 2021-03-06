(** Conversion from sugared to desugared input syntax. The responsibilities of
   this phase is to:

    * resolve all names to levels and indices

    * check arities of constructors and operations

    Note that we do not check arities of derivations here because those are first-class
    and are not bound to specific identifiers, and so we have no way of computing them
    in the desugaring phase.

    We could consider moving arity checking of all entitites to typechecking, but then
    we need to worry about separate namespaces in which they might leave, and it would
    just induce some pointless code refactoring.
*)

(** Association tables with de Bruijn levels. *)
module Assoc :
  sig
    type 'a t
    val empty : 'a t
    val add : Name.t -> 'a -> 'a t -> 'a t
    val last : 'a t -> int
    val find : Name.t -> 'a t -> 'a option
    val include' : (Name.t -> unit) -> 'a t -> 'a t -> 'a t
    val open' : (Name.t -> unit) -> 'a t -> 'a t -> 'a t
    val export : 'a t -> 'a t
  end =
struct
  type export = Exported | NotExported

  type 'a t =
    { last : int ; assoc : ('a * export) Name.map }

  let empty = { last = 0 ; assoc = Name.map_empty }

  let add x y {last; assoc} =
    { last = last + 1 ; assoc = Name.map_add x (y, Exported) assoc }

  let redirect expo check_fresh {last; assoc} {assoc=assoc';_} =
    { last ;
      assoc = Name.map_fold (fun k (v,_) assoc -> check_fresh k ; Name.map_add k (v, expo) assoc) assoc' assoc
    }

  let include' check_fresh asc asc' = redirect Exported check_fresh asc asc'
  let open' check_fresh asc asc' = redirect NotExported check_fresh asc asc'

  let export {last; assoc} =
    { last ;
      assoc = Name.map_fold
                (fun k ve assoc ->
                  match snd ve with
                  | Exported -> Name.map_add k ve assoc
                  | NotExported -> assoc)
                assoc Name.map_empty
    }

  let last {last; _} = last

  let find x {assoc; _} =
    try
      Some (fst (Name.map_find x assoc))
    with
      Not_found -> None
end

(** Arity of a TT constructor *)
type tt_arity = int

(** Arity of an ML constructor or opertation *)
type ml_arity = int

(** Arity of an ML exception *)
type exception_arity = Nullary | Unary

(* A module has three name spaces, one for ML modules, one for ML types and the other for
   everything else. However, we keep operations, ML constructos, TT constructors, and
   values in separate lists because we need to compute their indices. All entities are
   accessed by de Bruijn levels. *)
type ml_module = {
      ml_modules : (Path.t * ml_module) Assoc.t;
      ml_types : (Path.t * ml_arity) Assoc.t;
      ml_constructors : ((Path.t * Path.level) * ml_arity) Assoc.t;
      ml_operations : (Path.t * ml_arity) Assoc.t;
      ml_exceptions : (Path.t * exception_arity) Assoc.t;
      tt_constructors : (Path.t * tt_arity) Assoc.t;
      ml_values : Path.t Assoc.t
    }

let empty_module = {
    ml_modules = Assoc.empty;
    ml_types = Assoc.empty;
    ml_constructors = Assoc.empty;
    ml_operations = Assoc.empty;
    ml_exceptions = Assoc.empty;
    tt_constructors = Assoc.empty;
    ml_values = Assoc.empty
}

(** Information about names *)
type info =
  | Bound of Path.index
  | Value of Path.t
  | TTConstructor of Path.t * tt_arity
  | MLConstructor of Path.ml_constructor * ml_arity
  | Operation of Path.t * ml_arity
  | Exception of Path.t * exception_arity

let print_info info ppf = match info with
  | Bound _ | Value _ -> Format.fprintf ppf "a value"
  | TTConstructor _ -> Format.fprintf ppf "a constructor"
  | MLConstructor _ -> Format.fprintf ppf "an ML constructor"
  | Operation _ -> Format.fprintf ppf "an operation"
  | Exception _ -> Format.fprintf ppf "an exception"

type error =
  | UnknownPath of Name.path
  | UnknownType of Name.path
  | UnknownModule of Name.path
  | NameAlreadyDeclared of Name.t * info
  | MLTypeAlreadyDeclared of Name.t
  | MLModuleAlreadyDeclared of Name.t
  | OperationExpected : Name.path * info -> error
  | InvalidPatternVariable : Name.t -> error
  | InvalidPatternName : Name.path * info -> error
  | InvalidAppliedPatternName : Name.path * info -> error
  | NonlinearPattern : Name.t -> error
  | ArityMismatch of Name.path * int * int
  | ParallelShadowing of Name.t
  | AppliedTyParam
  | RequiredModuleMissing of Name.t * string list
  | CircularRequire of Name.t list

let print_error err ppf = match err with

  | UnknownPath pth ->
     Format.fprintf ppf "unknown name %t"
       (Name.print_path pth)

  | UnknownType pth ->
     Format.fprintf ppf "unknown type %t"
       (Name.print_path pth)

  | UnknownModule pth ->
     Format.fprintf ppf "unknown ML module %t"
       (Name.print_path pth)

  | NameAlreadyDeclared (x, info) ->
     Format.fprintf ppf
       "%t is already declared as %t"
       (Name.print x)
       (print_info info)

  | MLTypeAlreadyDeclared x ->
     Format.fprintf ppf
       "%t is already a defined ML type"
       (Name.print x)

  | MLModuleAlreadyDeclared x ->
     Format.fprintf ppf
       "%t is already a defind ML module"
       (Name.print x)

  | OperationExpected (pth, info) ->
     Format.fprintf ppf "%t should be an operation but is %t"
       (Name.print_path pth)
       (print_info info)

  | InvalidPatternName (pth, info) ->
     Format.fprintf ppf "%t cannot be used in a pattern as it is %t"
       (Name.print_path pth)
       (print_info info)

  | InvalidPatternVariable x ->
     Format.fprintf ppf "%t is an invalid pattern variable, perhaps you meant ?%t"
       (Name.print x)
       (Name.print x)

  | InvalidAppliedPatternName (pth, info) ->
     Format.fprintf ppf "%t cannot be applied in a pattern as it is %t"
       (Name.print_path pth)
       (print_info info)

  | NonlinearPattern x ->
     Format.fprintf ppf "pattern variable %t appears more than once"
       (Name.print x)

  | ArityMismatch (pth, used, expected) ->
     Format.fprintf ppf "%t expects %d arguments but is used with %d"
       (Name.print_path pth)
       expected
       used

  | ParallelShadowing x ->
     Format.fprintf ppf "%t is bound more than once"
       (Name.print x)

  | AppliedTyParam ->
     Format.fprintf ppf "an ML type parameter cannot be applied"

  | RequiredModuleMissing (mdl_name, files) ->
     Format.fprintf ppf "required module %t could not be found, looked in:@\n@[<hv>%t@]"
       (Name.print mdl_name)
       (Print.sequence (fun fn ppf -> Format.fprintf ppf "%s" fn) "," files)

  | CircularRequire mdls ->
     Format.fprintf ppf "circuar module dependency (@[<hov -2>%t@])"
        (Print.sequence (Name.print ~parentheses:false) "," mdls)

exception Error of error Location.located

let error ~at err = Stdlib.raise (Error (Location.mark ~at err))

module Ctx = struct

  type t = {
      (* Partially evaluated nested modules *)
      current_modules : (Path.t option * ml_module) list ;
      ml_bound : Name.t list ; (* the locally bound values, referred to by indices *)
    }

  let empty = {
      current_modules = [(None, empty_module)] ;
      ml_bound = [];
    }

  let current_module {current_modules;_} =
    match current_modules with
    | [] -> assert false (* There should always be at least the top module *)
    | (_, mdl) :: _ -> mdl

  let update_current ctx update =
    let mk_path optpath x lvl =
      match optpath with
      | None -> Path.Direct (Path.Level (x, lvl))
      | Some p -> Path.Module (p, Path.Level (x, lvl))
    in
    match ctx.current_modules with
    | [] -> assert false
    | (optpath, mdl) :: mdls ->
       let pth, mdl = update (mk_path optpath) mdl in
       pth, { ctx with current_modules = (optpath, mdl) :: mdls }

  (* Convert a context to a module. *)
  let export_ml_module {ml_modules; ml_types; ml_constructors; ml_operations; ml_exceptions; tt_constructors; ml_values} =
    {
      ml_modules = Assoc.export ml_modules;
      ml_types = Assoc.export ml_types;
      ml_constructors = Assoc.export ml_constructors;
      ml_operations = Assoc.export ml_operations;
      ml_exceptions = Assoc.export ml_exceptions;
      tt_constructors = Assoc.export tt_constructors;
      ml_values = Assoc.export ml_values;
    }

  let push_module mdl_name ctx =
    match ctx.current_modules with
    | [] -> assert false
    | ((pth_opt, mdl) :: _) as mdls ->
       let mdl_lvl = Assoc.last mdl.ml_modules in
       let pth =
         match pth_opt with
           | None -> Path.Direct (Path.Level (mdl_name, mdl_lvl))
           | Some pth -> Path.Module (pth, Path.Level (mdl_name, mdl_lvl))
       in
       { ctx with current_modules = (Some pth, empty_module) :: mdls }

  let pop_module ctx =
    match ctx.current_modules with
    | [] | [_] -> assert false
    | (_, mdl) :: mdls ->
       let mdl = export_ml_module mdl in
       { ctx with current_modules = mdls }, mdl


  (* Lookup functions named [find_XYZ] return optional results,
     while those named [get_XYZ] require a location and either return
     a result or trigger an error. *)

  (* Find information about the given name in the given module. *)
  let find_name_in_module x mdl =
    match Assoc.find x mdl.ml_values with
    | Some pth -> Some (Value pth)
    | None ->
       begin match Assoc.find x mdl.tt_constructors with
       | Some (pth, arity) -> Some (TTConstructor (pth, arity))
       | None ->
          begin match Assoc.find x mdl.ml_operations with
          | Some (pth, arity) -> Some (Operation (pth, arity))
          | None ->
             begin match Assoc.find x mdl.ml_constructors with
             | Some (pth, arity) -> Some (MLConstructor (pth, arity))
             | None ->
                begin match Assoc.find x mdl.ml_exceptions with
                | Some (pth, arity) -> Some (Exception (pth, arity))
                | None -> None
                end
             end
          end
       end

  let find_type_in_module t mdl = Assoc.find t mdl.ml_types

  let find_module_in_module m mdl = Assoc.find m mdl.ml_modules

  (* Find information about the given name in the current context. *)
  let rec find_path
    : 'a . find:(Name.t -> ml_module -> 'a option) -> Name.path -> t -> 'a option
  = fun ~find pth ctx ->
    match pth with

    | Name.PName x ->
       find_direct ~find x ctx

    | Name.PModule (pth, x) ->
       begin match find_ml_module pth ctx with
       | Some (pth, mdl) -> find x mdl
       | None -> None
       end

  and find_direct
    : 'a . find:(Name.t -> ml_module -> 'a option) -> Name.t -> t -> 'a option
    =  fun ~find x ctx ->
       let rec search = function
         | [] -> None
         | (_, mdl) :: mdls ->
            begin match find x mdl with
            | Some _ as info -> info
            | None -> search mdls
            end
       in
       search ctx.current_modules

  and find_ml_module pth ctx = find_path ~find:find_module_in_module pth ctx

  let find_name pth ctx = find_path ~find:find_name_in_module pth ctx

  let find_ml_type pth ctx = find_path ~find:find_type_in_module pth ctx

  (* Check that the name is not bound already *)
  let check_is_fresh_name ~at x ctx =
    match find_name_in_module x (current_module ctx) with
    | None -> ()
    | Some info -> error ~at (NameAlreadyDeclared (x, info))

  (* Check that the type is not bound already *)
  let check_is_fresh_type ~at t ctx =
    match find_type_in_module t (current_module ctx) with
    | None -> ()
    | Some info -> error ~at (MLTypeAlreadyDeclared t)

  (* Check that the module is not bound already *)
  let check_is_fresh_module ~at m ctx =
    match find_module_in_module m (current_module ctx) with
    | None -> ()
    | Some _ -> error ~at (MLModuleAlreadyDeclared m)

  (* Get information about the given ML constructor. *)
  let get_ml_constructor pth ctx =
    match find_name pth ctx with
    | Some (MLConstructor (pth, arity)) -> pth, arity
    | None |Some (Bound _ | Value _ | TTConstructor _ | Operation _ | Exception _) ->
       assert false

  (* Get information about the given ML operation. *)
  let get_ml_operation op ctx =
    match find_name op ctx with
    | Some (Operation (pth, arity)) -> pth, arity
    | None | Some (Bound _ | Value _ | TTConstructor _ | MLConstructor _ | Exception _) ->
       assert false

  (* Get information about the given ML operation. *)
  let get_ml_exception exc ctx =
    match find_name exc ctx with
    | Some (Exception (pth, arity)) -> pth, arity
    | None | Some (Bound _ | Value _ | TTConstructor _ | MLConstructor _ | Operation _) ->
       assert false

  (* This will be needed if and when there is a builtin global ML value that has to be looked up. *)
  (* let get_ml_value x ctx =
   *   match find_name x ctx with
   *   | Some (Value v) -> v
   *   | None | Some (Bound _ | TTConstructor _ | MLConstructor _ | Operation _) ->
   *      assert false *)

  (* Get information about the given ML module. *)
  let get_ml_module ~at pth ctx =
    match find_ml_module pth ctx with
    | Some (pth, mdl) -> pth, mdl
    | None -> error ~at (UnknownModule pth)

  (* Get the info about a path, or fail *)
  let get_name ~at pth ctx =
    match pth with

    | Name.PName x ->
       (* check whether it is locally bound *)
       let find_index x lst =
         let rec search i = function
           | [] -> None
           | x' :: lst -> if Name.equal x x' then Some i else search (i+1) lst
         in
         search 0 lst
       in
       begin match find_index x ctx.ml_bound with
       | Some i -> Bound (Path.Index (x, i))
       | None ->
          begin match find_name pth ctx with
          | Some info -> info
          | None -> error ~at (UnknownPath pth)
          end
       end

    | Name.PModule _ ->
       begin match find_name pth ctx with
       | Some info -> info
       | None -> error ~at (UnknownPath pth)
       end

  (* Get information about the list empty list constructor *)
  let get_path_nil ctx =
    get_ml_constructor Name.Builtin.nil ctx

  let get_path_cons ctx =
    get_ml_constructor Name.Builtin.cons ctx

  (* Get the path and the arity of type named [t] *)
  let get_ml_type ~at pth ctx =
    match find_ml_type pth ctx with
    | None -> error ~at (UnknownType pth)
    | Some info ->
       info

  (* Add a module to the current module. *)
  let add_ml_module ~at m mdl ctx =
    check_is_fresh_module ~at m ctx ;
    let (), ctx =
      update_current ctx
        (fun mk_path current ->
          let lvl = Assoc.last current.ml_modules in
          let pth = mk_path m lvl in
          (), { current with ml_modules = Assoc.add m (pth, mdl) current.ml_modules } )
    in
    ctx

  let include_ml_module ~at mdl ctx =
    let (), ctx =
      update_current ctx
        (fun _ {ml_modules; ml_types; ml_constructors; ml_operations; ml_exceptions; tt_constructors; ml_values} ->
        (), { ml_modules = Assoc.include' (fun m -> check_is_fresh_module ~at m ctx) ml_modules mdl.ml_modules;
              ml_types = Assoc.include' (fun t -> check_is_fresh_type ~at t ctx) ml_types mdl.ml_types;
              ml_constructors = Assoc.include' (fun x -> check_is_fresh_name ~at x ctx) ml_constructors mdl.ml_constructors;
              ml_operations = Assoc.include' (fun x -> check_is_fresh_name ~at x ctx) ml_operations mdl.ml_operations;
              ml_exceptions = Assoc.include' (fun x -> check_is_fresh_name ~at x ctx) ml_exceptions mdl.ml_exceptions;
              tt_constructors = Assoc.include' (fun x -> check_is_fresh_name ~at x ctx) tt_constructors mdl.tt_constructors;
              ml_values = Assoc.include' (fun x -> check_is_fresh_name ~at x ctx) ml_values mdl.ml_values;
        })
    in
    ctx

  let open_ml_module ~at mdl ctx =
    let (), ctx =
      update_current ctx
        (fun _ {ml_modules; ml_types; ml_constructors; ml_operations; ml_exceptions; tt_constructors; ml_values} ->
        (), { ml_modules = Assoc.open' (fun m -> check_is_fresh_module ~at m ctx) ml_modules mdl.ml_modules;
              ml_types = Assoc.open' (fun t -> check_is_fresh_type ~at t ctx) ml_types mdl.ml_types;
              ml_constructors = Assoc.open' (fun x -> check_is_fresh_name ~at x ctx) ml_constructors mdl.ml_constructors;
              ml_operations = Assoc.open' (fun x -> check_is_fresh_name ~at x ctx) ml_operations mdl.ml_operations;
              ml_exceptions = Assoc.open' (fun x -> check_is_fresh_name ~at x ctx) ml_exceptions mdl.ml_exceptions;
              tt_constructors = Assoc.open' (fun x -> check_is_fresh_name ~at x ctx) tt_constructors mdl.tt_constructors;
              ml_values = Assoc.open' (fun x -> check_is_fresh_name ~at x ctx) ml_values mdl.ml_values;
        })
    in
    ctx

  (* Add an ML values to the current module. *)
  let add_ml_value ~at x ctx =
    check_is_fresh_name ~at x ctx ;
    let (), ctx =
      update_current ctx
        (fun mk_path current ->
          let lvl = Assoc.last current.ml_values in
          let pth = mk_path x lvl in
          (), { current with ml_values = Assoc.add x pth current.ml_values } )
    in
    ctx

  (* Add a local bound value. *)
  let add_bound x ctx =
    { ctx with ml_bound = x :: ctx.ml_bound }

  (* Add a TT constructor of given arity *)
  let add_tt_constructor ~at c arity ctx =
    check_is_fresh_name ~at c ctx ;
    update_current ctx
      (fun mk_path current ->
        let lvl = Assoc.last current.tt_constructors in
        let pth = mk_path c lvl in
        pth, { current with tt_constructors = Assoc.add c (pth, arity) current.tt_constructors } )

  (* Add an operation of given arity *)
  let add_operation ~at op arity ctx =
    check_is_fresh_name ~at op ctx ;
    update_current ctx
      (fun mk_path current ->
        let lvl = Assoc.last current.ml_operations in
        let pth = mk_path op lvl in
        pth, { current with ml_operations = Assoc.add op (pth, arity) current.ml_operations } )

  (* Add an exception of given arity *)
  let add_exception ~at exc arity ctx =
    check_is_fresh_name ~at exc ctx ;
    update_current ctx
      (fun mk_path current ->
        let lvl = Assoc.last current.ml_exceptions in
        let pth = mk_path exc lvl in
        pth, { current with ml_exceptions = Assoc.add exc (pth, arity) current.ml_exceptions } )

  (* Add a ML constructor of given arity *)
  let add_ml_constructor ~at c info ctx =
    check_is_fresh_name ~at c ctx ;
    let (), ctx =
      update_current ctx
        (fun mk_path current ->
          (), { current with ml_constructors = Assoc.add c info current.ml_constructors } )
    in
    ctx

  (* Add to the context the fact that [t] is a type constructor with given constructors and arities. *)
  let add_ml_type ~at t (arity, cs_opt) ctx  =
    check_is_fresh_type ~at t ctx ;
    let t_pth, ctx =
      update_current ctx
        (fun mk_path current ->
          let lvl = Assoc.last current.ml_types in
          let pth = mk_path t lvl in
          pth, { current with ml_types = Assoc.add t (pth, arity) current.ml_types })
    in
    match cs_opt with
    | None -> t_pth, ctx
    | Some cs ->
       begin match find_type_in_module t (current_module ctx) with
       | None -> assert false
       | Some (t_pth, _) ->
          let _, ctx =
            List.fold_left
              (fun (lvl, ctx) (c, arity) ->
                let ctx = add_ml_constructor ~at c ((t_pth, Path.Level (c, lvl)), arity) ctx in
                (lvl+1, ctx))
              (0, ctx)
              cs
          in
          t_pth, ctx
       end

end (* module Ctx *)

(* Check that the arity is the expected one. *)
let check_ml_arity ~at pth used expected =
  if used <> expected then
    error ~at (ArityMismatch (pth, used, expected))

(* Check that the arity is the expected one. *)
let check_exception_arity ~at pth used expected =
  let card = function Nullary -> 0 | Unary -> 1 in
  if used <> card expected then
    error ~at (ArityMismatch (pth, used, card expected))

(* Compute the arity of a TT constructor, given the premises of its rule. *)
let tt_arity prems = List.length prems

(* Compute the arity of a ML constructor. *)
let ml_arity = List.length

(* Compute the arity of an ML exception. *)
let ml_exception_arity = function
  | None -> Nullary
  | Some _ -> Unary

(* Check that the arity is the expected one. *)
let check_tt_arity ~at pth used expected =
  if used <> expected then
    error ~at (ArityMismatch (pth, used, expected))

(* Desugar an ML type, with the given list of known type parameters *)
let mlty ctx params ty =
  let rec mlty ({Location.it=ty';at}) =
    let ty' =
      begin match ty' with

      | Sugared.ML_Arrow (ty1, ty2) ->
         let ty1 = mlty ty1
         and ty2 = mlty ty2 in
         Desugared.ML_Arrow (ty1, ty2)

      | Sugared.ML_Handler (ty1, ty2) ->
         let ty1 = mlty ty1
         and ty2 = mlty ty2 in
         Desugared.ML_Handler (ty1, ty2)

      | Sugared.ML_Ref t ->
         let t = mlty t in
         Desugared.ML_Ref t

      | Sugared.ML_Exn ->
         Desugared.ML_Exn

      | Sugared.ML_Prod tys ->
         let tys = List.map mlty tys in
         Desugared.ML_Prod tys

      | Sugared.ML_TyApply (pth, args) ->
         begin match pth with

         | Name.PModule _ ->
            let (t_pth, expected)  = Ctx.get_ml_type ~at pth ctx in
            check_ml_arity ~at pth (List.length args) expected ;
            let args = List.map mlty args in
            Desugared.ML_Apply (t_pth, args)

         | Name.PName x ->
            (* It could be one of the bound type parameters *)
            let rec search k = function
              | [] ->
              (* It's a type name *)
              begin
                let (t_pth, expected) = Ctx.get_ml_type ~at pth ctx in
                check_ml_arity ~at pth (List.length args) expected ;
                let args = List.map mlty args in
                Desugared.ML_Apply (t_pth, args)
              end
              | None :: params -> search k params
              | Some y :: params ->
                 if Name.equal x y then
                   (* It's a type parameter *)
                   begin match args with
                   | [] -> Desugared.ML_Bound (Path.Index (x, k))
                   | _::_ -> error ~at AppliedTyParam
                   end
                 else search (k+1) params
            in
            search 0 params
         end

      | Sugared.ML_Anonymous ->
         Desugared.ML_Anonymous

      | Sugared.ML_Judgement ->
         Desugared.ML_Judgement

      | Sugared.ML_Boundary ->
         Desugared.ML_Boundary

      | Sugared.ML_Derivation ->
         Desugared.ML_Derivation

      | Sugared.ML_String -> Desugared.ML_String
      end
    in
    Location.mark ~at ty'
  in
  mlty ty

(* TODO improve locs *)
let mk_abstract ~at ys c =
  List.fold_left
    (fun c (y,u) -> Location.mark ~at (Desugared.Abstract (y,u,c)))
    c ys

let rec pattern ~toplevel ctx {Location.it=p; at} =
  let locate x = Location.mark ~at x in
  match p with
  | Sugared.Patt_Anonymous ->
     ctx, locate Desugared.Patt_Anonymous

  | Sugared.Patt_Var x ->
     let add = if toplevel then Ctx.add_ml_value ~at else Ctx.add_bound in
     let ctx = add x ctx in
     ctx, locate (Desugared.Patt_Var x)

  | Sugared.Patt_Path pth ->
     begin match pth with

     | Name.PName x ->
        begin match Ctx.find_name pth ctx with

        | None ->
           error ~at (InvalidPatternVariable x)

        | Some (MLConstructor (pth, arity)) ->
           check_ml_arity ~at (Name.PName x) 0 arity ;
           ctx, locate (Desugared.Patt_MLConstructor (pth, []))

        | Some (TTConstructor (pth, arity)) ->
           check_tt_arity ~at (Name.PName x) 0 arity ;
           ctx, locate (Desugared.Patt_TTConstructor (pth, []))

        | Some (Exception (pth, arity)) ->
           check_exception_arity ~at (Name.PName x) 0 arity ;
           ctx, locate (Desugared.Patt_MLException (pth, None))

        | Some ((Operation _ | Bound _ | Value _) as info) ->
           error ~at (InvalidPatternName (pth, info))
        end

     | Name.PModule _ ->
        begin match Ctx.get_name ~at pth ctx with

        | MLConstructor (c_pth, arity) ->
           check_ml_arity ~at pth 0 arity ;
           ctx, locate (Desugared.Patt_MLConstructor (c_pth, []))

        | TTConstructor (c_pth, arity) ->
           check_tt_arity ~at pth 0 arity ;
           ctx, locate (Desugared.Patt_TTConstructor (c_pth, []))

        | (Value _ | Operation _ | Exception _) as info ->
           error ~at (InvalidPatternName (pth, info))

        | Bound _ -> assert false

        end
     end

  | Sugared.Patt_MLAscribe (p, t) ->
     let ctx, p = pattern ~toplevel ctx p in
     let t = mlty ctx [] t in
     ctx, locate (Desugared.Patt_MLAscribe (p, t))

  | Sugared.Patt_As (p1, p2) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     ctx, locate (Desugared.Patt_As (p1, p2))

  | Sugared.Patt_Constructor (c, ps) ->
     begin match Ctx.get_name ~at c ctx with
     | MLConstructor (pth, arity) ->
        check_ml_arity ~at c (List.length ps) arity ;
        let ctx, ps = patterns ~at ~toplevel ctx ps in
        ctx, locate (Desugared.Patt_MLConstructor (pth, ps))

     | Exception (exc, arity) ->
        check_exception_arity ~at c (List.length ps) arity ;
        begin match arity, ps with
        | Nullary, [] -> ctx, locate (Desugared.Patt_MLException (exc, None))
        | Unary, [p] ->
           let ctx, p = pattern ~toplevel ctx p in
           ctx, locate (Desugared.Patt_MLException (exc, Some p))
        | Nullary, _::_ -> error ~at (ArityMismatch (c, List.length ps, 0))
        | Unary, ([] | _::_::_) -> error ~at (ArityMismatch (c, List.length ps, 1))
        end

     | TTConstructor (pth, arity) ->
        check_tt_arity ~at c (List.length ps) arity ;
        let ctx, ps = patterns ~at ~toplevel ctx ps in
        ctx, locate (Desugared.Patt_TTConstructor (pth, ps))

     | (Bound _ | Value _ | Operation _) as info ->
        error ~at (InvalidAppliedPatternName (c, info))
     end

  | Sugared.Patt_GenAtom p ->
     let ctx, p = pattern ~toplevel ctx p in
     ctx, locate (Desugared.Patt_GenAtom p)

  | Sugared.Patt_IsType p ->
     let ctx, p = pattern ~toplevel ctx p in
     ctx, locate (Desugared.Patt_IsType p)

  | Sugared.Patt_IsTerm (p1, p2) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     ctx, locate (Desugared.Patt_IsTerm (p1, p2))

  | Sugared.Patt_EqType (p1, p2) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     ctx, locate (Desugared.Patt_EqType (p1, p2))

  | Sugared.Patt_EqTerm (p1, p2, p3) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     let ctx, p3 = pattern ~toplevel ctx p3 in
     ctx, locate (Desugared.Patt_EqTerm (p1, p2, p3))

  | Sugared.Patt_BoundaryIsType ->
     ctx, locate (Desugared.Patt_BoundaryIsType)

  | Sugared.Patt_BoundaryIsTerm p ->
     let ctx, p = pattern ~toplevel ctx p in
     ctx, locate (Desugared.Patt_BoundaryIsTerm p)

  | Sugared.Patt_BoundaryEqType (p1, p2) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     ctx, locate (Desugared.Patt_BoundaryEqType (p1, p2))

  | Sugared.Patt_BoundaryEqTerm (p1, p2, p3) ->
     let ctx, p1 = pattern ~toplevel ctx p1 in
     let ctx, p2 = pattern ~toplevel ctx p2 in
     let ctx, p3 = pattern ~toplevel ctx p3 in
     ctx, locate (Desugared.Patt_BoundaryEqTerm (p1, p2, p3))

  | Sugared.Patt_Abstraction (abstr, p0) ->
     let rec fold ctx = function
       | [] -> pattern ~toplevel ctx p0
       | (xopt, popt) :: abstr ->
          let ctx, popt =
            match popt with
            | None -> ctx, locate Desugared.Patt_Anonymous
            | Some p ->
               let ctx, p = pattern ~toplevel ctx p in
               ctx, p
          in
          let ctx, xopt =
            begin
              match xopt with
              | Some x ->
                 let ctx = Ctx.add_bound x ctx in
                 ctx, Some x
              | None -> ctx, None
            end
          in
          let ctx, p = fold ctx abstr in
          ctx, locate (Desugared.Patt_Abstraction (xopt, popt, p))
     in
     fold ctx abstr

  | Sugared.Patt_List ps ->
     let nil_path, _ = Ctx.get_path_nil ctx
     and cons_path, _ = Ctx.get_path_cons ctx in
     let rec fold ~at ctx = function
       | [] -> ctx, locate (Desugared.Patt_MLConstructor (nil_path, []))
       | p :: ps ->
          let ctx, p = pattern ~toplevel ctx  p in
          let ctx, ps = fold ~at:(p.Location.at) ctx ps in
          ctx, locate (Desugared.Patt_MLConstructor (cons_path, [p ; ps]))
     in
     fold ~at ctx ps

  | Sugared.Patt_Tuple ps ->
     let ctx, ps = patterns ~at ~toplevel ctx ps in
     ctx, locate (Desugared.Patt_Tuple ps)

  | Sugared.Patt_String s ->
     ctx, locate (Desugared.Patt_String s)

and patterns ~at ~toplevel ctx ps =
  let rec fold ctx ps_out = function
    | [] ->
       ctx, List.rev ps_out
    | p :: ps ->
       let ctx, p_out = pattern ~toplevel ctx p in
       fold ctx (p_out :: ps_out) ps
  in
  fold ctx [] ps

(** Verify that a pattern is linear and that it does not bind anything
    in the given set of forbidden names. Return the set of forbidden names
    extended with the names that this pattern binds. *)

let check_linear_pattern_variable ~at ~forbidden x =
     if Name.set_mem x forbidden then
       error ~at (NonlinearPattern x)
     else
       Name.set_add x forbidden

let rec check_linear ?(forbidden=Name.set_empty) {Location.it=p';at} =
  match p' with

  | Sugared.Patt_Anonymous | Sugared.Patt_Path _ | Sugared.Patt_String _ ->
     forbidden

  | Sugared.Patt_Var x ->
     check_linear_pattern_variable ~at ~forbidden x

  | Sugared.Patt_MLAscribe (p, _) ->
     check_linear ~forbidden p

  | Sugared.Patt_As (p1, p2) ->
     let forbidden = check_linear ~forbidden p1 in
     check_linear ~forbidden p2

  | Sugared.Patt_GenAtom p ->
     check_linear ~forbidden p

  | Sugared.Patt_IsType p ->
     check_linear ~forbidden p

  | Sugared.Patt_IsTerm (p1, p2) ->
     let forbidden = check_linear ~forbidden p1 in
     check_linear ~forbidden p2

  | Sugared.Patt_EqType (p1, p2) ->
     let forbidden = check_linear ~forbidden p1 in
     check_linear ~forbidden p2

  | Sugared.Patt_EqTerm (p1, p2, p3) ->
     let forbidden = check_linear ~forbidden p1 in
     let forbidden = check_linear ~forbidden p2 in
     check_linear ~forbidden p3

  | Sugared.Patt_BoundaryIsType ->
     forbidden

  | Sugared.Patt_BoundaryIsTerm p ->
     check_linear ~forbidden p

  | Sugared.Patt_BoundaryEqType (p1, p2) ->
     let forbidden = check_linear ~forbidden p1 in
     check_linear ~forbidden p2

  | Sugared.Patt_BoundaryEqTerm (p1, p2, p3) ->
     let forbidden = check_linear ~forbidden p1 in
     let forbidden = check_linear ~forbidden p2 in
     check_linear ~forbidden p3

  | Sugared.Patt_Abstraction (args, p) ->
     let forbidden = check_linear_abstraction ~at ~forbidden args in
     check_linear ~forbidden p

  | Sugared.Patt_Constructor (_, ps)
  | Sugared.Patt_List ps
  | Sugared.Patt_Tuple ps ->
     check_linear_list ~forbidden ps

and check_linear_list ~forbidden = function
  | [] -> forbidden
  | p :: ps ->
     let forbidden = check_linear ~forbidden p in
     check_linear_list ~forbidden ps

and check_linear_abstraction ~at ~forbidden = function
  | [] -> forbidden
  | (xopt, popt) :: args ->
     let forbidden =
       match xopt with
       | None -> forbidden
       | Some x -> check_linear_pattern_variable ~at ~forbidden x
     in
     let forbidden =
       match popt with
       | None -> forbidden
       | Some p -> check_linear ~forbidden p
     in
     check_linear_abstraction ~at ~forbidden args


let rec comp ctx {Location.it=c';at} =
  let locate x = Location.mark ~at x in
  match c' with
  | Sugared.Try (c, hcs) ->
     let c = comp ctx c
     and h = handler ~at ctx hcs in
     locate (Desugared.With (h, c))

  | Sugared.With (c1, c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.With (c1, c2))

  | Sugared.Raise c ->
     let c = comp ctx c in
     locate (Desugared.Raise c)

  | Sugared.Let (lst, c) ->
     let ctx, lst = let_clauses ~at ~toplevel:false ctx lst in
     let c = comp ctx c in
     locate (Desugared.Let (lst, c))

  | Sugared.LetRec (lst, c) ->
     let ctx, lst = letrec_clauses ~at ~toplevel:false ctx lst in
     let c = comp ctx c in
     locate (Desugared.LetRec (lst, c))

  | Sugared.MLAscribe (c, sch) ->
     let c = comp ctx c in
     let sch = ml_schema ctx sch in
     locate (Desugared.MLAscribe (c, sch))

  | Sugared.Lookup c ->
     let c = comp ctx c in
     locate (Desugared.Lookup c)

  | Sugared.Ref c ->
     let c = comp ctx c in
     locate (Desugared.Ref c)

  | Sugared.Update (c1, c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.Update (c1, c2))

  | Sugared.Sequence (c1, c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.Sequence (c1, c2))


  | Sugared.Fresh (xopt, c) ->
     let c = comp ctx c in
     locate (Desugared.Fresh (xopt, c))

  | Sugared.Meta xopt ->
     locate (Desugared.Meta xopt)

   | Sugared.AbstractAtom (c1,c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.AbstractAtom (c1,c2))

  | Sugared.Match (c, cases) ->
     let c = comp ctx c
     and cases = List.map (match_case ctx) cases in
     locate (Desugared.Match (c, cases))

  | Sugared.BoundaryAscribe (c, bdry) ->
     let bdry = comp ctx bdry
     and c = comp ctx c in
     locate (Desugared.BoundaryAscribe (c, bdry))

  | Sugared.TypeAscribe (c, t) ->
     let t = comp ctx t
     and c = comp ctx c in
     locate (Desugared.TypeAscribe (c, t))

  | Sugared.EqTypeAscribe (t1, t2, c) ->
     let t1 = comp ctx t1
     and t2 = comp ctx t2
     and c = comp ctx c in
     locate (Desugared.EqTypeAscribe (t1, t2, c))

  | Sugared.EqTermAscribe (e1, e2, t, c) ->
     let e1 = comp ctx e1
     and e2 = comp ctx e2
     and t = comp ctx t
     and c = comp ctx c in
     locate  (Desugared.EqTermAscribe (e1, e2, t, c))

  | Sugared.Abstract (xs, c) ->
     let rec fold ctx ys = function
       | [] ->
          let c = comp ctx c in
          mk_abstract ~at ys c
       | (x, None) :: xs ->
          let ctx = Ctx.add_bound x ctx
          and ys = (x, None) :: ys in
          fold ctx ys xs
       | (x, Some t) :: xs ->
          let ys = (let t = comp ctx t in (x, Some t) :: ys)
          and ctx = Ctx.add_bound x ctx in
          fold ctx ys xs
     in
     fold ctx [] xs

  | Sugared.Substitute (e, cs) ->
     let e = comp ctx e in
     List.fold_left
       (fun e c ->
          let c = comp ctx c
          and at = Location.from_to at c.Location.at in
          Location.mark ~at (Desugared.Substitute (e, c)))
       e cs

  | Sugared.Derive (prems, c) ->
     let c, prems = premises ctx prems (fun ctx -> comp ctx c) in
     locate (Desugared.Derive (prems, c))

  | Sugared.RuleApply (c, cs) ->
     let c = comp ctx c in
     let cs = List.map (comp ctx) cs in
     locate (Desugared.RuleApply (c, cs))

  | Sugared.Spine (e, cs) ->
     spine ~at ctx e cs

  | Sugared.Name x ->

     begin match Ctx.get_name ~at x ctx with

     | Bound i -> locate (Desugared.Bound i)

     | Value pth -> locate (Desugared.Value pth)

     | TTConstructor (pth, arity) ->
        if arity = 0 then
          locate (Desugared.TTConstructor (pth, []))
        else
          locate (Desugared.AsDerivation pth)

     | MLConstructor (pth, arity) ->
        check_ml_arity ~at x 0 arity ;
        locate (Desugared.MLConstructor (pth, []))

     | Operation (pth, arity) ->
        check_ml_arity ~at x 0 arity ;
        locate (Desugared.Operation (pth, []))

     | Exception (pth, arity) ->
        check_exception_arity ~at x 0 arity ;
        locate (Desugared.MLException (pth, None))
     end

  | Sugared.Function (ps, c) ->
     let rec fold ctx = function
       | [] -> comp ctx c
       | p :: ps ->
          let ctx, p = pattern ~toplevel:false ctx p in
          let c = fold ctx ps in
          locate (Desugared.(Function (p, c)))
     in
     fold ctx ps

  | Sugared.Handler hcs ->
     handler ~at ctx hcs

  | Sugared.List cs ->
     let nil_path, _ = Ctx.get_path_nil ctx
     and cons_path, _ = Ctx.get_path_cons ctx in
     let rec fold ~at = function
       | [] -> locate (Desugared.MLConstructor (nil_path, []))
       | c :: cs ->
          let c = comp ctx c in
          let cs = fold ~at:(c.Location.at) cs in
          locate (Desugared.MLConstructor (cons_path, [c ; cs]))
     in
     fold ~at cs

  | Sugared.Tuple cs ->
     let lst = List.map (comp ctx) cs in
     locate (Desugared.Tuple lst)

  | Sugared.String s ->
     locate (Desugared.String s)

  | Sugared.Congruence (c1, c2, cs) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2
     and cs = List.map (comp ctx) cs in
     locate (Desugared.Congruence (c1, c2, cs))

| Sugared.Rewrite (c, cs) ->
     let c = comp ctx c
     and cs = List.map (comp ctx) cs in
     locate (Desugared.Rewrite (c, cs))

  | Sugared.Context c ->
     let c = comp ctx c in
     locate (Desugared.Context c)

  | Sugared.Occurs (c1,c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.Occurs (c1,c2))

  | Sugared.Convert (c1,c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate (Desugared.Convert (c1,c2))

  | Sugared.Natural c ->
     let c = comp ctx c in
     locate (Desugared.Natural c)

  | Sugared.MLBoundaryIsType ->
     locate Desugared.(MLBoundary BoundaryIsType)

  | Sugared.MLBoundaryIsTerm c ->
     let c = comp ctx c in
     locate Desugared.(MLBoundary (BoundaryIsTerm c))

  | Sugared.MLBoundaryEqType (c1, c2) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2 in
     locate Desugared.(MLBoundary (BoundaryEqType (c1, c2)))

  | Sugared.MLBoundaryEqTerm (c1, c2, c3) ->
     let c1 = comp ctx c1
     and c2 = comp ctx c2
     and c3 = comp ctx c3 in
     locate Desugared.(MLBoundary (BoundaryEqTerm (c1, c2, c3)))

and let_clauses ~at ~toplevel ctx lst =
  let locate x = Location.mark ~at x in
  let add = if toplevel then Ctx.add_ml_value ~at else Ctx.add_bound in
  let rec fold ctx' lst' = function
    | [] ->
       let lst' = List.rev lst' in
       ctx', lst'

    | Sugared.Let_clause_ML (xys_opt, sch, c) :: clauses ->
       let ys = (match xys_opt with None -> [] | Some (_, ys) -> ys) in
       let c = let_clause ~at ctx ys c in
       let sch = let_annotation ctx sch in
       let x, ctx' =
         begin match xys_opt with
         | None -> locate Desugared.Patt_Anonymous, ctx'
         (* XXX if x carried its location, we would use it here *)
         | Some (x, _) -> locate (Desugared.Patt_Var x), add x ctx'
         end
       in
       let lst' = Desugared.Let_clause (x, sch, c) :: lst' in
       fold ctx' lst' clauses

    | Sugared.Let_clause_tt (xopt, t, c) :: clauses ->
       let c = let_clause_tt ctx c t in
       let sch = Desugared.Let_annot_none in
       let x, ctx' =
         begin match xopt with
         | None -> locate Desugared.Patt_Anonymous, ctx'
         (* XXX if x carried its location, we would use it here *)
         | Some x -> locate (Desugared.Patt_Var x), add x ctx'
         end
       in
       let lst' = Desugared.Let_clause (x, sch, c) :: lst' in
       fold ctx' lst' clauses

    | Sugared.Let_clause_patt (pt, sch, c) :: clauses ->
       let c = comp ctx c in
       let sch = let_annotation ctx sch in
       let ctx', pt = pattern ~toplevel ctx' pt in
       let lst' = Desugared.Let_clause (pt, sch, c) :: lst' in

     fold ctx' lst' clauses
  in
  let rec check_unique forbidden = function
    | [] -> ()
    | Sugared.Let_clause_ML (Some (x, _), _, _) :: lst
    | Sugared.Let_clause_tt (Some x, _, _) :: lst ->
       if Name.set_mem x forbidden
       then error ~at (ParallelShadowing x)
       else check_unique (Name.set_add x forbidden) lst
    | Sugared.Let_clause_ML (None, _, _) :: lst
    | Sugared.Let_clause_tt (None, _, _) :: lst ->
       check_unique forbidden lst
    | Sugared.Let_clause_patt (pt, _, _) :: lst ->
       let forbidden = check_linear ~forbidden pt in
       check_unique forbidden lst
  in
  check_unique Name.set_empty lst ;
  fold ctx [] lst

and letrec_clauses ~at ~toplevel ctx lst =
  let add = if toplevel then Ctx.add_ml_value ~at else Ctx.add_bound in
  let ctx =
    List.fold_left (fun ctx (f, _, _, _, _) -> add f ctx) ctx lst
  in
  let rec fold lst' = function
    | [] ->
       let lst' = List.rev lst' in
       ctx, lst'
    | (f, p, ps, sch, c) :: xcs ->
       if List.exists (fun (g, _, _, _, _) -> Name.equal f g) xcs
       then
         error ~at (ParallelShadowing f)
       else
         let p, c = letrec_clause ~at ctx p ps c in
         let sch = let_annotation ctx sch in
         let lst' = Desugared.Letrec_clause (f, p, sch, c) :: lst' in
         fold lst' xcs
  in
  fold [] lst

and let_clause ~at ctx ps c =
  let rec fold ctx = function
    | [] ->
       comp ctx c
    | p :: ps ->
       let ctx, p = pattern ~toplevel:false ctx p in
       let c = fold ctx ps in
       Location.mark  ~at:c.Location.at (Desugared.(Function (p, c))) (* XXX improve location *)
  in
  fold ctx ps

and let_clause_tt ctx c t =
  let c = comp ctx c
  and t = comp ctx t in
  Location.mark ~at:c.Location.at (Desugared.BoundaryAscribe (c, t))

and letrec_clause ~at ctx p ps c =
  let ctx, p = pattern ~toplevel:false ctx p in
  let c = let_clause ~at ctx ps c in
  p, c


and ml_schema ctx {Location.it=Sugared.ML_Forall (params, t); at} =
  Location.mark ~at (Desugared.ML_Forall (params, mlty ctx params t))


and let_annotation ctx = function

  | Sugared.Let_annot_none ->
     Desugared.Let_annot_none

  | Sugared.Let_annot_schema sch ->
     let sch = ml_schema ctx sch in
     Desugared.Let_annot_schema sch

(* To desugar a spine [c c1 c2 ... cN], we check if [c] is an identifier, in which
   case we break the spine according to the arity of [c]. *)
and spine ~at ctx ({Location.it=c'; at=c_at} as c) cs =

  (* Auxiliary function which splits a list into two parts with k
     elements in the first part. *)
  let split_at constr arity lst =
    let rec split acc m lst =
      if m = 0 then
        List.rev acc,
        (match lst with [] -> None | _::_ -> Some lst)
      else
        match lst with
        | [] -> error ~at (ArityMismatch (constr, List.length acc, arity))
        | x :: lst -> split (x :: acc) (m - 1) lst
    in
    split [] arity lst
  in
  let head, cs =
  match c' with

  | Sugared.Name x ->
     begin match Ctx.get_name ~at x ctx with

     | Bound i ->
          Location.mark ~at:c_at (Desugared.Bound i), Some cs

     | Value pth ->
          Location.mark ~at:c_at (Desugared.Value pth), Some cs

     | TTConstructor (pth, arity) ->
          check_tt_arity ~at x (List.length cs) arity ;
          let cs', cs = split_at x arity cs in
          tt_constructor ~at ctx pth cs', cs

     | MLConstructor (pth, arity) ->
        check_ml_arity ~at x (List.length cs) arity ;
        let cs', cs = split_at x arity cs in
        ml_constructor ~at ctx pth cs', cs

     | Operation (pth, arity) ->
        (* We allow more arguments than the arity of the operation. *)
        let cs', cs = split_at x arity cs in
        operation ~at ctx pth cs', cs

     | Exception (pth, arity) ->
        begin match arity, cs with
        | Nullary, [] -> ml_exception ~at ctx pth None, None
        | Unary, [c] -> ml_exception ~at ctx pth (Some c), None
        | Nullary, _::_ -> error ~at (ArityMismatch (x, List.length cs, 0))
        | Unary, ([] | _::_::_) -> error ~at (ArityMismatch (x, List.length cs, 1))
        end
     end

    | _ -> comp ctx c, Some cs
  in
  match cs with
  | None -> head
  | Some cs ->
     let cs = List.map (comp ctx) cs in
     Location.mark ~at (Desugared.Spine (head, cs))

(* Desugar handler cases. *)
and handler ~at ctx hcs =
  (* for every case | op p => c we do op binder => match binder with | p => c end *)
  let rec fold val_cases op_cases exc_cases = function
    | [] ->
       List.rev val_cases,
       List.map (fun (op, cs) -> (op, List.rev cs)) op_cases,
       List.rev exc_cases

    | Sugared.CaseVal c :: hcs ->
       let case = match_case ctx c in
       fold (case::val_cases) op_cases exc_cases hcs

    | Sugared.CaseOp (op, case) :: hcs ->
         let (pth, case) = match_op_case ~at ctx op case in
          let my_cases = match List.assoc_opt pth op_cases with Some lst -> lst | None -> [] in
          let my_cases = case::my_cases in
          fold val_cases ((pth, my_cases) :: op_cases) exc_cases hcs

    | Sugared.CaseExc c :: hcs ->
       let case = match_case ctx c in
       fold val_cases op_cases (case :: exc_cases) hcs

  in
  let handler_val, handler_ops, handler_exc = fold [] [] [] hcs in
  Location.mark ~at Desugared.(Handler {handler_val ; handler_ops; handler_exc })

(* Desugar a match case *)
and match_case ctx (p, g, c) =
  ignore (check_linear p) ;
  let ctx, p = pattern ~toplevel:false ctx p in
  let g = when_guard ctx g
  and c = comp ctx c in
  (p, g, c)

and when_guard ctx = function
  | None -> None
  | Some c ->
     let c = comp ctx c in
     Some c


and match_op_case ~at ctx op (ps, pt, c) =
  match Ctx.get_name ~at op ctx with

  | (Bound _ | Value _ | Exception _ | TTConstructor _ | MLConstructor _) as info ->
     error ~at (OperationExpected (op, info))

  | Operation (pth, arity) ->
     check_ml_arity ~at op (List.length ps) arity ;
     let rec fold ctx qs = function
       | [] ->
          let qs = List.rev qs in
          let ctx, pt =
            begin match pt with
            | None -> ctx, None
            | Some p ->
               ignore (check_linear p) ;
               let ctx, p = pattern ~toplevel:false ctx p in
               ctx, Some p
            end
          in
          let c = comp ctx c in
          pth, (qs, pt, c)

       | p :: ps ->
          let ctx, q = pattern ~toplevel:false ctx p in
          fold ctx (q :: qs) ps
     in
     fold ctx [] ps


and ml_constructor ~at ctx x cs =
  let cs = List.map (comp ctx) cs in
  Location.mark ~at (Desugared.MLConstructor (x, cs))

and tt_constructor ~at ctx pth cs =
  let cs = List.map (comp ctx) cs in
  Location.mark ~at (Desugared.TTConstructor (pth, cs))

and operation ~at ctx x cs =
  let cs = List.map (comp ctx) cs in
  Location.mark ~at (Desugared.Operation (x, cs))

and ml_exception ~at ctx x copt =
  let c = match copt with None -> None | Some c -> Some (comp ctx c) in
  Location.mark ~at (Desugared.MLException (x, c))

and local_context :
  'a . Ctx.t -> Sugared.local_context -> (Ctx.t -> 'a) -> 'a * Desugared.local_context
= fun ctx xcs m ->
  let rec fold ctx xcs_out = function
    | [] ->
       let xcs_out = List.rev xcs_out in
       let v = m ctx in
       v, xcs_out
    | (x, c) :: xcs ->
       let c = comp ctx c in
       let ctx = Ctx.add_bound x ctx in
       fold ctx ((x,c) :: xcs_out) xcs
  in
  fold ctx [] xcs

and premise ctx {Location.it=prem;at} =
  let locate x = Location.mark ~at x in
  let Sugared.Premise (mvar, local_ctx, c) = prem in
  let bdry, local_ctx = local_context ctx local_ctx (fun ctx -> comp ctx c) in
  let mvar = (match mvar with Some mvar -> mvar | None -> Name.anonymous ()) in
  let ctx = Ctx.add_bound mvar ctx in
  ctx, locate (Desugared.Premise (mvar, local_ctx, bdry))

and premises :
  'a . Ctx.t -> Sugared.premise list -> (Ctx.t -> 'a) -> 'a * Desugared.premise list
= fun ctx prems m ->
  let rec fold ctx prems_out = function
    | [] ->
       let v = m ctx in
       let prems_out = List.rev prems_out in
       v, prems_out

    | prem :: prems ->
       let ctx, prem = premise ctx prem in
       fold ctx (prem :: prems_out) prems
  in
  fold ctx [] prems

let decl_operation ~at ctx args res =
  let args = List.map (mlty ctx []) args
  and res = mlty ctx [] res in
  args, res

let mlty_constructor ~at ctx params (c, args) =
  (c, List.map (mlty ctx params) args)

let mlty_def ~at ctx params = function

  | Sugared.ML_Alias ty ->
     let ty = mlty ctx params ty in
     Desugared.ML_Alias ty

  | Sugared.ML_Sum lst ->
     let lst = List.map (mlty_constructor ~at ctx params) lst in
     Desugared.ML_Sum lst

let mlty_info params = function

  | Sugared.ML_Alias _ -> (ml_arity params), None

  | Sugared.ML_Sum lst ->
     let cs = List.map (fun (c, args) -> (c, ml_arity args)) lst in
     (ml_arity params),
     Some cs

let mlty_defs ~at ctx defs =
  let rec fold defs_out ctx = function
    | [] -> ctx, List.rev defs_out
    | (t, (params, def)) :: defs_in ->
       let def_out = mlty_def ~at ctx params def in
       let t_pth, ctx = Ctx.add_ml_type ~at t (mlty_info params def) ctx in
       fold ((t_pth, (params, def_out)) :: defs_out) ctx defs_in
  in
  fold [] ctx defs

let mlty_rec_defs ~at ctx defs =
  (* first change the context  *)
  let defs_out, ctx =
    List.fold_left
      (fun (defs_out, ctx) (t, (params, def)) ->
        let t_pth, ctx = Ctx.add_ml_type ~at t (mlty_info params def) ctx in
        ((t_pth, (params, def)) :: defs_out, ctx))
      ([], ctx) defs
  in
  let defs_out = List.rev defs_out in
  (* check for parallel shadowing *)
  let check_shadow = function
    | [] -> ()
    | (t, _) :: defs ->
       if List.exists (fun (t', _) -> Name.equal t t') defs then
         error ~at (ParallelShadowing t)
  in
  check_shadow defs ;
  let defs_out =
    List.map (fun (t, (params, def)) -> (t, (params, mlty_def ~at ctx params def))) defs_out in
  ctx, defs_out


let rec toplevel' ctx {Location.it=cmd; at} =
  let locate1 cmd = [Location.mark ~at cmd] in

  match cmd with

  | Sugared.Rule (rname, prems, c) ->
     let arity = tt_arity prems in
     let bdry, prems =
       premises
         ctx prems
         (fun ctx -> comp ctx c)
     in
     let pth, ctx = Ctx.add_tt_constructor ~at rname arity ctx in
     (ctx, locate1 (Desugared.Rule (pth, prems, bdry)))

  | Sugared.DeclOperation (op, (args, res)) ->
     let args, res = decl_operation ~at ctx args res in
     let pth, ctx = Ctx.add_operation ~at op (ml_arity args) ctx in
     (ctx, locate1 (Desugared.DeclOperation (pth, (args, res))))

  | Sugared.DeclException (exc, tyopt) ->
     let arity, tyopt =
       match tyopt with
       | None -> Nullary, None
       | Some ty -> Unary,Some (mlty ctx [] ty)
     in
     let pth, ctx = Ctx.add_exception ~at exc (ml_exception_arity tyopt) ctx in
     (ctx, locate1 (Desugared.DeclException (pth, tyopt)))

  | Sugared.DefMLTypeAbstract (t, params) ->
     let t_pth, ctx = Ctx.add_ml_type ~at t (List.length params, None) ctx in
     (ctx, locate1 (Desugared.DefMLTypeAbstract (t_pth, params)))

  | Sugared.DefMLType defs ->
     let ctx, defs = mlty_defs ~at ctx defs in
     (ctx, locate1 (Desugared.DefMLType defs))

  | Sugared.DefMLTypeRec defs ->
     let ctx, defs = mlty_rec_defs ~at ctx defs in
     (ctx, locate1 (Desugared.DefMLTypeRec defs))

  | Sugared.DeclExternal (x, sch, s) ->
     let sch = ml_schema ctx sch in
     let ctx = Ctx.add_ml_value ~at x ctx in
     (ctx, locate1 (Desugared.DeclExternal (x, sch, s)))

  | Sugared.TopLet lst ->
     let ctx, lst = let_clauses ~at ~toplevel:true ctx lst in
     (ctx, locate1 (Desugared.TopLet lst))

  | Sugared.TopLetRec lst ->
     let ctx, lst = letrec_clauses ~at ~toplevel:true ctx lst in
     (ctx, locate1 (Desugared.TopLetRec lst))

  | Sugared.TopWith lst ->
     let lst = List.map (fun (op, case) -> match_op_case ~at ctx op case) lst in
     (ctx, locate1 (Desugared.TopWith lst))

  | Sugared.TopComputation c ->
     let c = comp ctx c in
     (ctx, locate1 (Desugared.TopComputation c))

  | Sugared.Verbosity n ->
     (ctx, locate1 (Desugared.Verbosity n))

  | Sugared.Require mdl_names ->
     (* requires are preprocessed, skip them in later stages *)
     (ctx, [])

  | Sugared.Include mdl_path ->
     let _, mdl = Ctx.get_ml_module ~at mdl_path ctx in
     let ctx = Ctx.include_ml_module ~at mdl ctx in
     (ctx, [])

  | Sugared.Open mdl_path ->
     let pth, mdl = Ctx.get_ml_module ~at mdl_path ctx in
     let ctx = Ctx.open_ml_module ~at mdl ctx in
     (ctx, locate1 (Desugared.Open pth))

  | Sugared.TopModule (x, cmds) ->
     let ctx, cmd = ml_module ~at ctx x cmds in
     (ctx, [cmd])

(* Desugar a list of top-level commands in the current context. Return the new context and
   the desugared commands. Assume all required modules have been loaded. *)
and toplevels ctx cmds =
  let ctx, cmds =
    List.fold_left
    (fun (ctx,cmds) cmd ->
      let ctx, cmds' = toplevel' ctx cmd in
      (ctx, cmds' @ cmds))
    (ctx, [])
    cmds
  in
  let cmds = List.rev cmds in
  ctx, cmds

(* Desugare the given commands as the definition of a module [m]. Return the new context,
   and the desugared module definition. Assume all required modules have been loaded. *)
and ml_module ~at ctx m cmds =
  let ctx = Ctx.push_module m ctx in
  let ctx, cmds = toplevels ctx cmds in
  let ctx, mdl = Ctx.pop_module ctx in
  let ctx = Ctx.add_ml_module ~at m mdl ctx in
  ctx, Location.mark ~at (Desugared.MLModule (m, cmds))

(* Load the modules required by the given commands, recursively. Return the new context,
   and the loaded modules. *)
let rec load_requires ~basedir ~loading ctx cmds =

  let require ~at ~loading ctx mdl_name =
    match Ctx.find_ml_module (Name.PName mdl_name) ctx with

    | Some _ ->
       (* already loaded *)
       ctx, []

    | None ->
       (* not loaded yet *)
       if List.exists (Name.equal mdl_name) loading then
         (* We are in the process of loading this module, circular dependency *)
         error ~at (CircularRequire (List.rev (mdl_name :: loading)))
       else
         let rec unique xs = function
           | [] -> List.rev xs
           | y :: ys ->
              if List.mem y xs then unique xs ys else unique (y::xs) ys
         in
         let basename = Name.module_filename mdl_name in
         let fns =
           unique []
                  (List.map
                     (fun dirname -> Filename.concat dirname basename)
                     (basedir :: (!Config.require_dirs))
                  )
         in
         match List.find_opt Sys.file_exists fns with

         | None ->
            error ~at (RequiredModuleMissing (mdl_name, fns))

         | Some fn ->
            let loading = mdl_name :: loading in
            let cmds = Lexer.read_file ?line_limit:None Parser.file fn in
            let ctx, mdls = load_requires ~loading ~basedir ctx cmds in
            let ctx, mdl = ml_module ~at ctx mdl_name cmds in
            ctx, (mdls @ [mdl])
  in

  let rec fold ~loading ctx = function
    | [] -> ctx, []

    | Location.{it=cmd; at} :: cmds ->
       begin match cmd with

       | Sugared.Require mdl_names ->
          let ctx, mdls_required =
            List.fold_left
              (fun (ctx, mdls) mdl_name ->
                let ctx, mdls' = require ~loading ~at ctx mdl_name in
                (ctx, mdls @ mdls'))
              (ctx, [])
              mdl_names
          in
          let ctx, mdls = fold ~loading ctx cmds in
          ctx, mdls_required @ mdls

       | Sugared.TopModule (_, cmds') ->
          let ctx, mdls' = fold ~loading ctx cmds' in
          let ctx, mdls = fold ~loading ctx cmds in
          ctx, mdls' @ mdls

       | Sugared.(Rule _ | DefMLTypeAbstract _ |
               DefMLType _ | DefMLTypeRec _ | DeclOperation _ | DeclException _ | DeclExternal _ |
               TopLet _ | TopLetRec _ | TopWith _ | TopComputation _ |
               Include _ | Verbosity _ | Open _) ->
          fold ~loading ctx cmds
       end
  in
  fold ~loading ctx cmds

(* Desugar commands, after loading the required modules *)
let commands ~loading ~basedir ctx cmds =
  let ctx, mdls = load_requires ~loading:[] ~basedir ctx cmds in
  let ctx, cmds = toplevels ctx cmds in
  ctx, (mdls @ cmds)

let toplevel ~basedir ctx cmd =
  commands ~loading:[] ~basedir ctx [cmd]

(** Load a file, return the list of desugared commands, including required modules. *)
let use_file ctx fn =
  let cmds = Lexer.read_file ?line_limit:None Parser.file fn in
  let basedir = Filename.dirname fn in
  commands ~loading:[] ~basedir ctx cmds

and load_ml_module ctx fn =
  let basename = Filename.basename fn in
  let dirname = Filename.dirname fn in
  let mdl_name = Name.mk_name (Filename.remove_extension basename) in
  let cmds = Lexer.read_file ?line_limit:None Parser.file fn in
  let ctx, mdls = load_requires ~loading:[mdl_name] ~basedir:dirname ctx cmds in
  let ctx, cmd = ml_module ~at:Location.unknown ctx mdl_name cmds in
  ctx, (mdls @ [cmd])

let initial_context, initial_commands =
  try
    commands ~loading:[] ~basedir:Filename.current_dir_name Ctx.empty Builtin.initial
  with
  | Error {Location.it=err;_} ->
    Print.error "Error in built-in code:@ %t.@." (print_error err) ;
    Stdlib.exit 1

module Builtin =
struct
  let bool = fst (Ctx.get_ml_type ~at:Location.unknown Name.Builtin.bool initial_context)
  let mlfalse = fst (Ctx.get_ml_constructor Name.Builtin.mlfalse initial_context)
  let mltrue = fst (Ctx.get_ml_constructor Name.Builtin.mltrue initial_context)

  let list = fst (Ctx.get_ml_type ~at:Location.unknown Name.Builtin.list initial_context)
  let nil = fst (Ctx.get_ml_constructor Name.Builtin.nil initial_context)
  let cons = fst (Ctx.get_ml_constructor Name.Builtin.cons initial_context)

  let option = fst (Ctx.get_ml_type ~at:Location.unknown Name.Builtin.option initial_context)
  let none = fst (Ctx.get_ml_constructor Name.Builtin.none initial_context)
  let some = fst (Ctx.get_ml_constructor Name.Builtin.some initial_context)

  let mlless = fst (Ctx.get_ml_constructor Name.Builtin.mlless initial_context)
  let mlequal = fst (Ctx.get_ml_constructor Name.Builtin.mlequal initial_context)
  let mlgreater = fst (Ctx.get_ml_constructor Name.Builtin.mlgreater initial_context)

  let equal_type = fst (Ctx.get_ml_operation Name.Builtin.equal_type initial_context)
  let coerce = fst (Ctx.get_ml_operation Name.Builtin.coerce initial_context)

  let eqchk_excs = fst (Ctx.get_ml_exception Name.Builtin.eqchk_excs initial_context)
end
