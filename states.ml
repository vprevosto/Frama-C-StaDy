
module Counter_examples =
  State_builder.Hashtbl
    (Property.Hashtbl)
    (Datatype.String.Hashtbl.Make
       (Datatype.String.Hashtbl.Make
	  (* input, concrete output, symbolic output *)
	  (Datatype.Triple (Datatype.String) (Datatype.String) (Datatype.String)
    )))
    (struct
      let name = "PathCrawler.Counter_examples"
      let dependencies = [Ast.self]
      let size = 64
     end)

module Nb_test_cases = State_builder.Zero_ref
  (struct
    let name = "PathCrawler.Nb_test_cases"
    let dependencies = [Ast.self]
   end)

module All_Paths = State_builder.False_ref
  (struct
    let name = "PathCrawler.All_Paths"
    let dependencies = [Ast.self]
   end)

module Property_To_Id =
  State_builder.Hashtbl
    (Property.Hashtbl)
    (Datatype.Int)
    (struct
      let name = "Property_To_Id"
      let dependencies = [Ast.self]
      let size = 64
     end)

module Id_To_Property =
  State_builder.Hashtbl
    (Datatype.Int.Hashtbl)
    (Property)
    (struct
      let name = "Id_To_Property"
      let dependencies = [Ast.self]
      let size = 64
     end)

module Not_Translated_Predicates =
  State_builder.List_ref (Datatype.Int)
    (struct
      let name = "Not_Translated_Predicates"
      let dependencies = [Ast.self]
     end)

module Unreachable_Stmts =
  State_builder.Hashtbl
    (Datatype.Int.Hashtbl)
    (Datatype.Pair
       (Cil_datatype.Stmt)
       (Cil_datatype.Kf))
    (struct
      let name = "Unreachable_Stmts"
      let dependencies = [Ast.self]
      let size = 64
     end)

module Behavior_Reachability =
  State_builder.Hashtbl
    (Datatype.Int.Hashtbl)
    (Datatype.Triple
       (Cil_datatype.Kf)
       (Cil_datatype.Funbehavior)
       (Datatype.Bool))
    (struct
      let name = "Behavior_Reachability"
      let dependencies = [Ast.self]
      let size = 64
     end)

module Externals =
  State_builder.Hashtbl
    (Datatype.String.Hashtbl)
    (Cil_datatype.Varinfo)
    (struct
      let name = "Externals"
      let dependencies = [Ast.self]
      let size = 31
     end)