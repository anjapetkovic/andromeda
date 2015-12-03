(** Sets of assumptions *)

type t

val empty : t

val singleton : Name.atom -> t

(** [add_free x a] adds [x] to the assumptions [a] *)
val add_free : Name.atom -> t -> t

val union : t -> t -> t

(** [instantiate l lvl a] where [l] is [a0 ... an]
    replaces bound variable [lvl+k] by the assumptions [ak] for k<=n,
    by lvl+k-n for k>n and leaves k<lvl unchanged*)
val instantiate : t list -> int -> t -> t

(** [abstract a lvl l] where [l] is [x0 ... xn]
    replaces the free variables [x0 ... xn] by the bound variables [lvl ... lvl+n] respectively. *)
val abstract : Name.atom list -> int -> t -> t

(** If [a] has no bound assumptions, [as_atom_set a] returns the set of free assumptions.
    Otherwise it raises an Error.impossible. *)
val as_atom_set : loc:Location.t -> t -> Name.AtomSet.t

