
type t

val make: Cil_types.varinfo -> formals:Cil_types.varinfo list ->
  locals:Cil_types.varinfo list -> Insertion.t list -> t
val pretty: Format.formatter -> t -> unit
val is_nondet: t -> bool
