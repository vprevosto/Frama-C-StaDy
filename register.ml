
open Cil
open Cil_types
open Lexing

 



(* outputs the AST of a project in a file *)
let print_in_file prj filename =
  Project.on prj (fun () ->
    let out = open_out filename in
    let fmt = Format.formatter_of_out_channel out in
    Pcva_printer.pp_file fmt (Ast.get());
    flush out;
    close_out out
  ) ()





let run() =
  if Options.Enabled.get() then
    begin
      Kernel.Unicode.set false;
      (* Map locs to properties *)
      let property_id = ref 0 in
      Property_status.iter (fun property ->
	let pos1,_ = Property.location property in
	let fc_builtin = "__fc_builtin_for_normalization.i" in
	if (Filename.basename pos1.pos_fname) <> fc_builtin then
	  begin
	    Datatype.Int.Hashtbl.add
	      Prop_id.id_to_prop_tbl !property_id property;
	    Property.Hashtbl.add Prop_id.prop_to_id_tbl property !property_id;
	    property_id := !property_id + 1
	  end
      );
      Datatype.Int.Hashtbl.iter (fun prop_id prop ->
	Options.Self.feedback "loc: %a (id: %i)" 
	  Printer.pp_location (Property.location prop) prop_id
      ) Prop_id.id_to_prop_tbl;
      (* do something *)
      print_in_file (Project.current()) "toto.c"
    end






  
  
let run =
  let deps = [Ast.self; Options.Enabled.self] in
  let f, _self = State_builder.apply_once "pcva" deps run in
  f
    
let () = Db.Main.extend run
  
