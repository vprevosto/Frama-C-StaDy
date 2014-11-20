
let append_end l elt = List.rev_append (List.rev l) [elt]

let no_repeat l =
  let rec aux acc = function
    | [] -> acc
    | h :: t when List.mem h acc -> aux acc t
    | h :: t -> aux (h :: acc) t
  in
  aux  [] l

let fieldinfo_to_int fi =
  let rec aux cpt = function
    | {Cil_types.forig_name=s}::_ when s = fi.Cil_types.forig_name ->
      Integer.of_int cpt
    | _::t -> aux (cpt+1) t
    | _ -> assert false
  in
  aux 0 fi.Cil_types.fcomp.Cil_types.cfields

let machdep () =
  match Kernel.Machdep.get() with
  | "x86_64" -> 64
  | "x86_32" | "ppc_32" -> 32
  | "x86_16" -> 16
  | _ -> 32

let default_behavior kf =
  List.find Cil.is_default_behavior (Annotations.behaviors kf)

let typically_preds bhv =
  let is_typically (s,_,_) = s = "typically" in
  let typically = List.filter is_typically bhv.Cil_types.b_extended in
  let typically = List.map (fun (_,_,pred) -> pred) typically in
  List.fold_left List.rev_append [] typically

let to_id = Sd_states.Property_To_Id.find
let to_prop = Sd_states.Id_To_Property.find


open Cil_types


(* extract guards for logic vars, e.g.: [0 <= a <= 10; x <= b <= y] *)
let extract_guards var p =
  let merge_term x y = match (x,y) with
    | Some x, None | None, Some x -> Some x | None, None -> None
    | _ -> assert false
  in
  let merge_rel x y = match (x,y) with
    | Some x, None | None, Some x -> Some x | None, None -> None
    | _ -> assert false
  in
  let rec is_var_to_guard t = match t.term_node with
    | TLogic_coerce (_, t) -> is_var_to_guard t
    | TLval(TVar x, TNoOffset) -> Cil_datatype.Logic_var.equal x var
    | _ -> false
  in
  let rec aux p =
    match p.content with
    | Pand(p1, p2) ->
      let a,b,c,d = aux p1 and e,f,g,h = aux p2 in
      (merge_term a e), (merge_rel b f), (merge_rel c g), (merge_term d h)
    | Prel((Rlt|Rle) as r, t1, t2) when is_var_to_guard t1 ->
      None, None, Some r, Some t2
    | Prel((Rlt|Rle) as r, t1, t2) when is_var_to_guard t2 ->
      Some t1, Some r, None, None
    | Prel(Rge, t1, t2) when is_var_to_guard t1 -> Some t2, Some Rle, None, None
    | Prel(Rgt, t1, t2) when is_var_to_guard t1 -> Some t2, Some Rlt, None, None
    | Prel(Rge, t1, t2) when is_var_to_guard t2 -> None, None, Some Rle, Some t1
    | Prel(Rgt, t1, t2) when is_var_to_guard t2 -> None, None, Some Rlt, Some t1
    | _ -> None, None, None, None
  in
  let a,b,c,d = aux p in
  (Extlib.the a), (Extlib.the b), (Extlib.the c), (Extlib.the d)


let error_term t = Sd_options.Self.abort "term: %a" Sd_debug.pp_term t
let error_toffset t = Sd_options.Self.abort "toffset: %a" Sd_debug.pp_toffset t
let error_pred p = Sd_options.Self.abort "pred: %a" Sd_debug.pp_pred p


(* Extracts the varinfo of the variable and its inferred size as a term
   from a term t as \valid(t). *)
let rec extract_from_valid t =
  match t.term_node with
  | TBinOp (((PlusPI|IndexPI|MinusPI) as op),
    	    ({term_node=TCastE((TPtr _) as ty,t)} as _operand1),
    	    ({term_node=(Trange (_, Some _))} as operand2)) ->
      extract_from_valid
    	{t with term_node=TBinOp(op, {t with term_type=Ctype ty}, operand2)}
  | TBinOp((PlusPI|IndexPI),
	   ({term_node=TLval(TVar v, _)}),
	   ({term_node=
	       Trange(_,
		      Some {term_node=
			  TBinOp (MinusA, x,
				  {term_node=TConst (Integer (i, _))})})}))
      when Integer.equal i Integer.one ->
    let varinfo = Extlib.the v.lv_origin in
    varinfo, x
  | TBinOp((PlusPI|IndexPI),
	   ({term_node=TLval(TVar v, _)}),
	   ({term_node=Trange(_,Some bound)})) ->
    let varinfo = Extlib.the v.lv_origin in
    let tnode = TBinOp (PlusA, bound, Cil.lone ~loc:t.term_loc()) in
    let einfo = {exp_type=bound.term_type; exp_name=[]} in
    let term = Cil.term_of_exp_info t.term_loc tnode einfo in
    varinfo, term
  | TBinOp((PlusPI|IndexPI),
	   ({term_node=TLval(TVar v, _)}),
	   (t2 (* anything but a Trange *))) ->
    let varinfo = Extlib.the v.lv_origin in
    let tnode = TBinOp (PlusA, t2, Cil.lone ~loc:t.term_loc()) in
    let einfo = {exp_type=t2.term_type; exp_name=[]} in
    let term = Cil.term_of_exp_info t.term_loc tnode einfo in
    varinfo, term
  | TBinOp((PlusPI|IndexPI),
	   ({term_node=TLval tlval}),
	   ({term_node=
	       Trange(_,
		      Some {term_node=
			  TBinOp (MinusA, x,
				  {term_node=TConst (Integer (i, _))})})}))
      when Integer.equal i Integer.one ->
    let varinfo, _ = extract_from_valid {t with term_node=TLval tlval} in
    varinfo, x
  | TBinOp((PlusPI|IndexPI),
	   ({term_node=TLval tlval}),
	   ({term_node=Trange(_,Some bound)})) ->
    let tnode = TBinOp (PlusA, bound, Cil.lone ~loc:t.term_loc()) in
    let einfo = {exp_type=bound.term_type; exp_name=[]} in
    let term = Cil.term_of_exp_info t.term_loc tnode einfo in
    let varinfo, _ = extract_from_valid {t with term_node=TLval tlval} in
    varinfo, term
  | TLval (TVar v, TNoOffset) ->
    let varinfo = Extlib.the v.lv_origin in
    let term = Cil.lone ~loc:t.term_loc () in
    varinfo, term
  | TLval (TMem m, TNoOffset) ->
    let varinfo, _ = extract_from_valid m in
    let term = Cil.lone ~loc:t.term_loc () in
    varinfo, term
  | _ -> Sd_options.Self.debug "\\valid(%a)" Sd_debug.pp_term t; assert false


(* Computes and returns a hashtable such that :
   -  var1 => inferred size for var1
   -  var2 => inferred size for var2
   -  ...
   - var n => inferred size for varn *)
let lengths_from_requires kf =
  let vi = Kernel_function.get_vi kf in
  let kf_tbl = Cil_datatype.Varinfo.Hashtbl.create 32 in
  let o = object
    inherit Visitor.frama_c_inplace
    method! vpredicate = function
    | Pvalid(_, t) | Pvalid_read(_, t) ->
      begin
	try
	  let v, term = extract_from_valid t in
	  let terms =
	    try Cil_datatype.Varinfo.Hashtbl.find kf_tbl v
	    with Not_found -> []
	  in
	  let terms = append_end terms term in
	  Cil_datatype.Varinfo.Hashtbl.replace kf_tbl v terms;
	  Cil.DoChildren
	with
	| _ -> Cil.DoChildren
      end
    | _ -> Cil.DoChildren
  end
  in
  let on_requires p =
    let p' = (new Sd_subst.subst)#pred p.ip_content [][][][] in
    ignore (Visitor.visitFramacPredicate o p')
  in
  let on_bhv _ bhv = List.iter on_requires bhv.b_requires in
  if not (Cil.is_unused_builtin vi) then
    (* TODO: handle arrays with constant size *)
    (*Globals.Vars.iter (fun vi _ -> () );*)
    Annotations.iter_behaviors on_bhv kf;
  kf_tbl

let mpz_t() =
  let ty = Sd_options.mpz_t in
  let ty = !ty in
  let ty = Extlib.the ty in
  ty


(* unused: interpreting string as precondition predicates *)
(* let type_str_precond kf pred_as_string = *)
(*   let module M = Logic_typing.Make(struct *)
(*     let is_loop() = false *)
(*     let anonCompFieldName = Cabs2cil.anonCompFieldName *)
(*     let conditionalConversion = Cabs2cil.logicConditionalConversion *)
(*     let find_macro _ = raise Not_found *)
(*     let find_var x = *)
(*       let vi = *)
(* 	try Globals.Vars.find_from_astinfo x (VLocal kf) *)
(* 	with Not_found -> *)
(* 	  try Globals.Vars.find_from_astinfo x (VFormal kf) *)
(* 	  with Not_found -> Globals.Vars.find_from_astinfo x VGlobal *)
(*       in *)
(*       Cil.cvar_to_lvar vi *)
(*     let find_enum_tag x = *)
(*       try Globals.Types.find_enum_tag x *)
(*       with Not_found -> failwith ("Unbound variable " ^ x) *)
(*     let find_type = Globals.Types.find_type *)
(*     let find_comp_field info s = Field(Cil.getCompField info s,NoOffset) *)
(*     let find_label s = Kernel_function.find_label kf s *)

(*     let remove_logic_function = Logic_env.remove_logic_function *)
(*     let remove_logic_type = Logic_env.remove_logic_type *)
(*     let remove_logic_ctor = Logic_env.remove_logic_ctor *)

(*     let add_logic_function = Logic_utils.add_logic_function *)
(*     let add_logic_type = Logic_env.add_logic_type *)
(*     let add_logic_ctor = Logic_env.add_logic_ctor *)

(*     let find_all_logic_functions = Logic_env.find_all_logic_functions *)
(*     let find_logic_type = Logic_env.find_logic_type *)
(*     let find_logic_ctor = Logic_env.find_logic_ctor *)

(*     let integral_cast ty t = *)
(*       failwith *)
(*         (Pretty_utils.sfprintf *)
(*            "term %a has type %a, but %a is expected." *)
(*            Printer.pp_term t *)
(* 	   Printer.pp_logic_type Linteger Printer.pp_typ ty) *)
(*   end) *)
(*   in *)
(*   let lenv = Logic_typing.Lenv.empty() in *)
(*   let _, lexpr = Logic_lexer.lexpr (Lexing.dummy_pos, pred_as_string) in *)
(*   M.predicate lenv lexpr *)
