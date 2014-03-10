
open Cil_types


let debug_builtins = Kernel.register_category "printer:builtins"

let print_var v =
  not (Cil.is_unused_builtin v) || Kernel.is_debug_key_enabled debug_builtins

(* to change a \valid to a pathcrawler_dimension *)
let rec extract_terms : term -> term * term =
  fun t ->
    let loc = t.term_loc in
    match t.term_node with
    | TLval _ -> t, Cil.lzero ~loc ()
    | TCastE (_,term)
    | TCoerce (term,_)
    | TAlignOfE term -> extract_terms term
    | TBinOp ((PlusPI|IndexPI),x,{term_node = Trange(_,Some y)}) -> x,y
    | TBinOp ((PlusPI|IndexPI),x,y) -> x,y
    | TBinOp (MinusPI,x,y) ->
      let einfo = {exp_type=t.term_type; exp_name=[]} in
      x, Cil.term_of_exp_info loc (TUnOp(Neg,y)) einfo
    | TStartOf _ -> t, Cil.lzero ~loc ()
    | TAddrOf (TVar _, TIndex _) ->
      let lv = Cil.mkTermMem t TNoOffset in
      let einfo = {exp_type=t.term_type;exp_name=[]} in
      let te = Cil.term_of_exp_info loc(TLval lv) einfo in
      extract_terms te
    | _ -> Options.Self.not_yet_implemented "term: %a" Printer.pp_term t




(* generate guards for logic vars, e.g.:
   [0 <= a <= 10; x <= b <= y]
   TODO: what is the 2nd value of the returned tuple (logic_var list) ??? *)
let rec compute_guards
    : (term*relation*logic_var*relation*term)list ->
  logic_var list ->
  predicate named ->
  ((term*relation*logic_var*relation*term)list * logic_var list) =
  fun acc vars p ->
    match p.content with
    | Pand({ content = Prel((Rlt | Rle) as r1, t11, t12) },
	   { content = Prel((Rlt | Rle) as r2, t21, t22) }) ->
      let rec terms t12 t21 = match t12.term_node, t21.term_node with
	| TLval(TVar x1, TNoOffset), TLval(TVar x2, TNoOffset) -> 
	  let v, vars = match vars with
	    | [] -> assert false
	    | v :: tl -> 
	      match v.lv_type with
	      | Ctype ty when Cil.isIntegralType ty -> v, tl
	      | Linteger -> v, tl
	      | Ltype _ as ty when Logic_const.is_boolean_type ty -> v, tl
	      | Ctype _ | Ltype _ | Lvar _ | Lreal | Larrow _ -> assert false
	  in
	  if Cil_datatype.Logic_var.equal x1 x2
	    && Cil_datatype.Logic_var.equal x1 v then
	    (t11, r1, x1, r2, t22) :: acc, vars
	  else
	    assert false
	| TLogic_coerce(_, t12), _ -> terms t12 t21 
	| _, TLogic_coerce(_, t21) -> terms t12 t21
	| TLval _, _ -> assert false
	| _, _ -> assert false
      in
      terms t12 t21
    | Pand(p1, p2) ->
      let acc, vars = compute_guards acc vars p1 in
      compute_guards acc vars p2
    | _ ->
      Options.Self.feedback "compute_guards of %a" Printer.pp_predicate_named p;
      assert false




type ext_quantifier = Max | Min | Sum | Product | NumOf




class sd_printer props terms_at_Pre () = object(self)
  inherit Printer.extensible_printer () as super

  val mutable pred_cpt = 0
  val mutable postcond = None
  val mutable dealloc = None
  val mutable result_varinfo = None
  val mutable current_function = None
  val mutable in_old_term = false
  val mutable in_old_ptr = false
  val mutable first_global = true

  (* we can only modify the property_status of the properties that have really
     been translated into pathcrawler_assert_exception *)
  val mutable translated_properties = []

  (* getter *)
  method translated_properties() = Utils.no_repeat translated_properties
    
  (* unmodified *)  
  method private in_current_function vi =
    assert (current_function = None);
    current_function <- Some vi

  (* unmodified *)
  method private out_current_function =
    assert (current_function <> None);
    current_function <- None

  (* unmodified *)
  method! private opt_funspec fmt funspec =
    if logic_printer_enabled && not (Cil.is_empty_funspec funspec) then
      Format.fprintf fmt "@[<hv 1>/*@@ %a@ */@]@\n" self#funspec funspec

  (* unmodified *)
  method private vdecl_complete fmt v =
    let display_ghost = v.vghost && not is_ghost in
    Format.fprintf fmt "@[<hov 0>%t%a;%t@]"
      (if display_ghost then fun fmt -> Format.fprintf fmt "/*@@ ghost@ "
       else ignore)
      self#vdecl v
      (if display_ghost then fun fmt -> Format.fprintf fmt "@ */" else ignore)

  (* replace a varinfo by old_varinfo, according to the terms_at_Pre hashtbl *)
  method! varinfo fmt v =
    if in_old_term then
      match current_function with
      | Some f ->
	begin
	  let prefix =
	    if (Cil.isPointerType v.vtype || Cil.isArrayType v.vtype)
	      && in_old_ptr then "old_ptr" else "old"
	  in
	  try
	    let tbl = Datatype.String.Hashtbl.find terms_at_Pre f.vname in
	    ignore (Cil_datatype.Varinfo.Hashtbl.find tbl v);
	    super#varinfo fmt {v with vname=prefix^"_"^v.vname}
	  with
	  | Not_found ->
	    Options.Self.feedback ~dkey:Options.dkey_at
	      "%s_%s not found in terms_at_Pre" prefix v.vname;
	    super#varinfo fmt v
	end
      | None -> super#varinfo fmt v
    else
      super#varinfo fmt v

  method! logic_var fmt v =
    if in_old_term then
      match current_function with
      | Some f ->
	begin
	  let prefix =
	    match v.lv_type with Ctype ty ->
	      if (Cil.isPointerType ty || Cil.isArrayType ty)
		&& in_old_ptr then "old_ptr" else "old"
	    | _ -> "old"
	  in
	  try
	    let tbl = Datatype.String.Hashtbl.find terms_at_Pre f.vname in
	    let vi = Extlib.the v.lv_origin in
	    ignore (Cil_datatype.Varinfo.Hashtbl.find tbl vi);
	    super#logic_var fmt {v with lv_name=prefix^"_"^v.lv_name}
	  with
	  | _ ->
	    Options.Self.feedback ~dkey:Options.dkey_at
	      "%s_%s not found in terms_at_Pre" prefix v.lv_name;
	    super#logic_var fmt v
	end
      | None -> super#logic_var fmt v
    else
      super#logic_var fmt v

  (* support of the litteral value of INT_MIN *)
  method! exp fmt e =
    match e.enode with
    | UnOp(Neg,{enode=Const(CInt64 (_,_,Some s))},_) when s = "2147483648" ->
      Format.fprintf fmt "(-2147483467-1)"
    | _ -> super#exp fmt e

  (* unmodified *)
  method! term fmt t = self#term_node fmt t

  method! term_node fmt t =
    match t.term_node with
    | Tat(_, StmtLabel _) ->
      if current_function <> None then
	Options.Self.warning "%a unsupported" Printer.pp_term t;
      super#term_node fmt t
    | Tat(term,LogicLabel(_,stringlabel)) ->
      if stringlabel = "Old" || stringlabel = "Pre" then
	begin
	  let is_ptr =
	    match term.term_node with TLval(TMem _,_) -> true | _ -> false in
	  if is_ptr then in_old_ptr <- true;
	  in_old_term <- true;
	  self#term fmt term;
	  if is_ptr then in_old_ptr <- false;
	  in_old_term <- false
	end
      else
	(* label Post is only encoutered in post-conditions, and \at(t,Post)
	   in a post-condition is t *)
	if stringlabel = "Post" then
	  self#term fmt term
	else
	  begin
	    if current_function <> None then
	      Options.Self.warning "%a unsupported" Printer.pp_term t;
	    super#term_node fmt t
	  end
    | _ -> super#term_node fmt t

  method private term_and_var fmt t = self#term_node_and_var fmt t

  (* \min, \max, \sum, \product and \numof *)
  method private lambda_and_var fmt li lower upper q t =
    let builtin_name = li.l_var_info.lv_name in
    let var = "__stady_term_" ^ (string_of_int pred_cpt) in
    let iter = q.lv_name in
    let kind = if builtin_name = "\\min" then Min
      else if builtin_name = "\\max" then Max
      else if builtin_name = "\\sum" then Sum
      else if builtin_name = "\\product" then Product
      else if builtin_name = "\\numof" then NumOf
      else assert false
    in
    pred_cpt <- pred_cpt + 1;
    Format.fprintf fmt "int %s = %s;@\n"
      var
      (match kind with
      | Sum | NumOf -> "0"
      | Product -> "1"
      | Min | Max -> "-1" (* undefined here *) );
    Format.fprintf fmt "{@\n";
    Format.fprintf fmt "int %s;@\n" iter;
    let low = self#term_and_var fmt lower in
    let up = self#term_and_var fmt upper in
    Format.fprintf fmt "for(%s=%s; %s <= %s; %s++) {@\n" iter low iter up iter;
    let lambda_term = self#term_and_var fmt t in
    begin
      match kind with
      | Sum -> Format.fprintf fmt "%s += %s;@\n" var lambda_term
      | NumOf -> Format.fprintf fmt "if(%s) { %s ++; }@\n" lambda_term var
      | Product -> Format.fprintf fmt "%s *= %s;@\n" var lambda_term
      | Min -> Format.fprintf fmt "if(%s < %s) { %s = %s; }@\n"
	lambda_term var var lambda_term
      | Max -> Format.fprintf fmt "if(%s > %s) { %s = %s; }@\n"
	lambda_term var var lambda_term
    end;
    Format.fprintf fmt "}@\n";
    Format.fprintf fmt "}@\n";
    var

  (* special treatment for \old terms *)
  method private term_node_and_var fmt t =
    match t.term_node with
    | Tnull -> "0"
    | TConst(Integer(i,_)) ->
      if (Integer.to_string i) = "-2147483648" then
	"(-2147483647-1)"
      else
	(Format.fprintf Format.str_formatter "%a" super#term_node t;
	 Format.flush_str_formatter())
    | Tapp (li,[],[lower;upper;{term_node=Tlambda([q],t)}]) ->
      self#lambda_and_var fmt li lower upper q t
    | Tat(_, StmtLabel _) ->
      if current_function <> None then
	Options.Self.warning "%a unsupported" Printer.pp_term t;
      Format.fprintf Format.str_formatter "%a" super#term_node t;
      Format.flush_str_formatter()
    | Tat(term,LogicLabel(_,stringlabel)) ->
      if stringlabel = "Old" || stringlabel = "Pre" then
	begin
	  let is_ptr =
	    match term.term_node with TLval(TMem _,_) -> true | _ -> false in
	  if is_ptr then in_old_ptr <- true;
	  in_old_term <- true;
	  let v = self#term_and_var fmt term in
	  if is_ptr then in_old_ptr <- false;
	  in_old_term <- false;
	  v
	end
      else
	(* label Post is only encoutered in post-conditions, and \at(t,Post)
	   in a post-condition is t *)
	if stringlabel = "Post" then
	  self#term_and_var fmt term
	else
	  begin
	    if current_function <> None then
	      Options.Self.warning "%a unsupported" Printer.pp_term t;
	    Format.fprintf Format.str_formatter "%a" super#term_node t;
	    Format.flush_str_formatter()
	  end
    | TLogic_coerce (_, t) -> self#term_and_var fmt t
    | TCoerce (t, _) -> self#term_and_var fmt t
    | TLval tlval -> self#tlval_and_var fmt tlval
    | _ ->
      Format.fprintf Format.str_formatter "%a" super#term_node t;
      Format.flush_str_formatter()
      
  method private tlval_and_var fmt (tlhost, toffset) =
    match tlhost with
    | TResult _ ->
      Format.fprintf Format.str_formatter "%a" self#term_lval (tlhost,toffset);
      Format.flush_str_formatter()
    | _ ->
      let lhost = self#term_lhost_and_var fmt tlhost in
      let offset = self#term_offset_and_var fmt toffset in
      "(" ^ lhost ^ ")" ^ offset

  method private term_lhost_and_var fmt lhost =
    match lhost with
    | TVar lv ->
      Format.fprintf Format.str_formatter "%a" self#logic_var lv;
      Format.flush_str_formatter()
    | TResult _ -> assert false
    | TMem t -> let v = self#term_and_var fmt t in "*(" ^ v ^ ")"

  method private term_offset_and_var fmt toffset =
    match toffset with
    | TNoOffset -> ""
    | TField (fi, tof) ->
      let v = self#term_offset_and_var fmt tof in
      "." ^ fi.fname ^ v
    | TModel (mi, tof) ->
      let v = self#term_offset_and_var fmt tof in
      "." ^ mi.mi_name ^ v
    | TIndex (t, tof) ->
      let t = self#term_and_var fmt t in
      let v = self#term_offset_and_var fmt tof in
      "[" ^ t ^ "]" ^ v

  (* modify result_varinfo when the function returns something *)
  method private compute_result_varinfo f =
    List.iter (fun stmt ->
      match stmt.skind with
      | Return(Some {enode = Lval(Var v,_)},_) -> result_varinfo <- Some v
      | _ -> ()
    ) f.sallstmts

  (* print the name of the return value for \result *)
  method! term_lval fmt t =
    match t with
    | (TResult _,_) ->
      begin
	match result_varinfo with
	| None -> failwith "term_lval: no result_varinfo" (* unreachable *)
	| Some v -> Format.fprintf fmt "%s" v.vname
      end
    | _ -> super#term_lval fmt t

  method private at_least_one_prop kf behaviors =
    List.fold_left (fun res b ->
      res ||
	let at_least_one res (tk,pred) =
	  res ||
	    let prop = Property.ip_of_ensures kf Kglobal b (tk,pred) in
	    List.mem prop props
	in
	List.fold_left at_least_one false b.b_post_cond
    ) false behaviors

  method private fundecl fmt f =
    Options.Self.debug ~dkey:Options.dkey_second_pass "IN fundecl";
    let was_ghost = is_ghost in
    let entry_point_name =
      Kernel_function.get_name (fst(Globals.entry_point())) in
    let kf = Globals.Functions.find_by_name f.svar.vname in
    let behaviors = Annotations.behaviors kf in
    let entering_ghost = f.svar.vghost && not was_ghost in
    self#compute_result_varinfo f;
    (* BEGIN precond (entry-point) *)
    if f.svar.vname = entry_point_name then
      begin
	let x,y,z =
	  match f.svar.vtype with TFun(_,x,y,z) -> x,y,z | _ -> assert false
	in
	Format.fprintf fmt "%a@ {@\n@[<v 2>@["
	  (self#typ
	     (Some (fun fmt ->
	       Format.fprintf fmt "%s_precond" entry_point_name)))
	  (TFun(Cil.intType,x,y,z));
	List.iter (fun b ->
	  List.iter (fun p ->
	    self#bhv_assumes_begin fmt b p.ip_loc;
	    let v = self#predicate_and_var fmt (self#subst_pred p.ip_content) in
	    Format.fprintf fmt "@[<hv>%a@[<v 2>if (!%s) return 0;@]@]"
	      (fun fmt -> self#line_directive ~forcefile:false fmt) p.ip_loc
	      v;
	    self#bhv_assumes_end fmt b
	  ) b.b_requires
	) behaviors;
	Format.fprintf fmt "return 1;@]@]@\n}@\n@\n"
      end;
    (* END precond (entry-point) *)
    Format.fprintf fmt "@[%t%a@\n@[<v 2>"
      (if entering_ghost then fun fmt -> Format.fprintf fmt "/*@@ ghost@ " 
       else ignore)
      self#vdecl f.svar;
    (* body. *)
    if entering_ghost then is_ghost <- true;
    Format.fprintf fmt "@[<h 2>{@\n";
    (* BEGIN precond (not entry-point) *)
    if f.svar.vname <> entry_point_name then
      List.iter (fun b ->
	List.iter (fun pred ->
	  let prop = Property.ip_of_requires kf Kglobal b pred in
	  if List.mem prop props then
	    let id = Prop_id.to_id prop in
	    self#bhv_assumes_begin fmt b pred.ip_loc;
	    self#pc_assert_exception
	      fmt pred.ip_content pred.ip_loc "Pre-condition!" id prop;
	    self#bhv_assumes_end fmt b
	) b.b_requires
      ) behaviors;
    (* END precond (not entry-point) *)
    (* BEGIN postcond *)
    postcond <-
      if List.length behaviors > 0 then
	if self#at_least_one_prop kf behaviors then
	  Some (fun fmt ->
	    Format.fprintf fmt "@[<h 2>{@\n";
	    List.iter (fun b ->
	      List.iter (fun (tk,pred) ->
		let prop = Property.ip_of_ensures kf Kglobal b (tk,pred) in
		if List.mem prop props then
		  let id = Prop_id.to_id prop in
		  self#bhv_assumes_begin fmt b pred.ip_loc;
		  self#pc_assert_exception
		    fmt pred.ip_content pred.ip_loc "Post-condition!" id prop;
		  self#bhv_assumes_end fmt b
	      ) b.b_post_cond
	    ) behaviors;
	    Format.fprintf fmt "@\n}@]@\n"
	  )
	else
	  None
      else
	None;
    (* END postcond *)
    (* alloc variables for \at terms *)
    let concat_indice str ind = str ^ "[" ^ ind ^ "]" in
    begin
      let rec extract_ptr_typ = function
	| TPtr(ty,_)
	| TArray(ty,_,_,_) -> extract_ptr_typ ty
	| x -> x
      in
      let rec array_to_ptr = function
	| TArray(ty,_,_,attributes) -> TPtr(array_to_ptr ty, attributes)
	| x -> x
      in
      try
	let tbl = Datatype.String.Hashtbl.find terms_at_Pre f.svar.vname in
	let iter_counter = ref 0 in
	Cil_datatype.Varinfo.Hashtbl.iter_sorted (fun v terms ->
	  Format.fprintf fmt "%a = %s;@\n"
	    (self#typ(Some(fun fmt -> Format.fprintf fmt "old_%s" v.vname)))
	    (array_to_ptr v.vtype)
	    v.vname;
	  let rec alloc_aux indices = function
	    | h :: t ->
	      let rec stars ret =function 0->ret | n -> stars (ret^"*") (n-1) in
	      let all_indices = List.fold_left concat_indice "" indices in
	      let stars =
		stars "" ((List.length terms)-(List.length indices)-1) in
	      let ty = extract_ptr_typ v.vtype in
	      let h' = self#term_and_var fmt h in
	      Format.fprintf fmt "old_ptr_%s%s = malloc((%s)*sizeof(%a%s));@\n"
		v.vname all_indices h' (self#typ None) ty stars;
	      let iterator = "__stady_iter_" ^ (string_of_int !iter_counter) in
	      Format.fprintf fmt "int %s;@\n" iterator;
	      let h' = self#term_and_var fmt h in
	      Format.fprintf fmt "for (%s = 0; %s < %s; %s++) {@\n"
		iterator iterator h' iterator;
	      iter_counter := !iter_counter + 1;
	      alloc_aux (Utils.append_end indices iterator) t;
	      Format.fprintf fmt "}@\n"
	    | [] ->
	      let all_indices = List.fold_left concat_indice "" indices in
	      Format.fprintf fmt "old_ptr_%s%s = %s%s;@\n"
		v.vname all_indices v.vname all_indices
	  in
	  if Cil.isPointerType v.vtype || Cil.isArrayType v.vtype then
	    begin
	      Format.fprintf fmt "%a;@\n"
		(self#typ(Some(fun fmt -> Format.fprintf fmt "old_ptr_%s"
		  v.vname)))
		(array_to_ptr v.vtype);
	      alloc_aux [] terms
	    end
	) tbl
      with Not_found -> ()
    end;
    dealloc <- (* dealloc variables for \at terms *)
      Some (fun fmt ->
	try
	  let tbl = Datatype.String.Hashtbl.find terms_at_Pre f.svar.vname in
	  let iter_counter = ref 0 in
	  Cil_datatype.Varinfo.Hashtbl.iter_sorted (fun v terms ->
	    let rec dealloc_aux indices = function
	      | [] -> ()
	      | _ :: [] ->
		let all_indices = List.fold_left concat_indice "" indices in
		Format.fprintf fmt "free(old_ptr_%s%s);@\n" v.vname all_indices
	      | h :: t ->
		let iterator = "__stady_iter_" ^(string_of_int !iter_counter) in
		Format.fprintf fmt "int %s;@\n" iterator;
		let h' = self#term_and_var fmt h in
		Format.fprintf fmt "for (%s = 0; %s < %s; %s++) {@\n"
		  iterator iterator h' iterator;
		let all_indices = List.fold_left concat_indice "" indices in
		iter_counter := !iter_counter + 1;
		let indices = Utils.append_end indices iterator in
		dealloc_aux indices t;
		Format.fprintf fmt "}@\n";
		Format.fprintf fmt "free(old_ptr_%s%s);@\n" v.vname all_indices
	    in
	    dealloc_aux [] terms
	  ) tbl
	with Not_found -> ()
      );
    self#block ~braces:true fmt f.sbody;
    begin
      match postcond with
      | Some post_cond -> post_cond fmt; postcond <- None
      | None -> ()
    end;
    begin
      match dealloc with
      | Some de_alloc -> de_alloc fmt; dealloc <- None
      | None -> ()
    end;
    Format.fprintf fmt "@.}";
    if entering_ghost then is_ghost <- false;
    Format.fprintf fmt "@]%t@]@."
      (if entering_ghost then fun fmt -> Format.fprintf fmt "@ */" else ignore);
    Options.Self.debug ~dkey:Options.dkey_second_pass "OUT fundecl"
  (* end of fundecl *)

  method private subst_pred p = (new Sd_subst.subst)#subst_pred p [] [] [] []

  method private bhv_assumes_begin fmt bhv loc =
    if bhv.b_assumes <> [] then
      let vars = List.map (fun a ->
	self#predicate_and_var fmt (self#subst_pred a.ip_content)
      ) bhv.b_assumes in
      Format.fprintf fmt "@[<hv>%a@[<v 2>if ("
	(fun fmt -> self#line_directive ~forcefile:false fmt) loc;
      List.iter (fun v -> Format.fprintf fmt "%s && " v) vars;
      Format.fprintf fmt "1) {@\n"
	
  method private bhv_assumes_end fmt bhv =
    if bhv.b_assumes <> [] then Format.fprintf fmt "}@\n@]@]"

  method private pc_assert_exception fmt pred loc msg id prop =
    let var = self#predicate_and_var fmt (self#subst_pred pred) in
    Format.fprintf fmt "@[<hv>%a@[<v 2>if(!%s)"
      (fun fmt -> self#line_directive ~forcefile:false fmt) loc var;
    Format.fprintf fmt "pathcrawler_assert_exception(\"%s\", %i);" msg id;
    Format.fprintf fmt "@]@]";
    translated_properties <- prop :: translated_properties

  method private bhv_guard_begin fmt behaviors loc =
    if behaviors <> [] then
      begin
	let vars = List.map (fun assumes ->
	  List.map (fun a ->
	    self#predicate_and_var fmt (self#subst_pred a.ip_content)
	  ) assumes
	) behaviors in
	Format.fprintf fmt "@[<hv>%a@[<v 2>if ("
	  (fun fmt -> self#line_directive ~forcefile:false fmt) loc;
	List.iter (fun assumes ->
	  Format.fprintf fmt "(";
	  List.iter (fun a -> Format.fprintf fmt "%s && " a) assumes;
	  Format.fprintf fmt "1 ) || "
	) vars;
	Format.fprintf fmt "0) {@\n"
      end

  method private bhv_guard_end fmt behaviors =
    if behaviors <> [] then Format.fprintf fmt "}@\n@]@]"

  method! private annotated_stmt next fmt stmt =
    Format.pp_open_hvbox fmt 2;
    self#stmt_labels fmt stmt;
    Format.pp_open_hvbox fmt 0;
    let kf = Kernel_function.find_englobing_kf stmt in
    let begin_loop = ref [] in
    let end_loop = ref [] in
    let has_code_annots = List.length (Annotations.code_annot stmt) > 0 in
    let end_contract = ref [] in
    let loc = Cil_datatype.Stmt.loc stmt in
    if has_code_annots then Format.fprintf fmt "%a@[<v 2>{@\n"
      (fun fmt -> self#line_directive ~forcefile:false fmt) loc;
    Annotations.iter_code_annot (fun _ ca ->
      let bhv_names =
	match ca.annot_content with
	| AAssert (b,_) | AStmtSpec (b,_) | AInvariant (b,_,_) -> b
	| _ -> []
      in
      let behaviors =
	List.map (fun bname ->
	  Annotations.fold_behaviors (fun _ b ret ->
	    if b.b_name = bname then b.b_assumes else ret
	  ) kf []
	) bhv_names
      in
      match ca.annot_content with
      | AStmtSpec (_,bhvs) ->
	self#bhv_guard_begin fmt behaviors loc;
	List.iter (fun b ->
	  List.iter (fun pred ->
	    let prop = Property.ip_of_requires kf (Kstmt stmt) b pred in
	    if List.mem prop props then
	      begin
		let id = Prop_id.to_id prop in
		self#bhv_assumes_begin fmt b pred.ip_loc;
		self#pc_assert_exception fmt pred.ip_content pred.ip_loc
		  "Stmt Pre-condition!" id prop;
		self#bhv_assumes_end fmt b
	      end
	  ) b.b_requires
	) bhvs.spec_behavior;
	self#bhv_guard_end fmt behaviors;
	let contract =
	  if List.length bhvs.spec_behavior > 0 then
	    if self#at_least_one_prop kf bhvs.spec_behavior then
	      Some (fun fmt ->
		Format.fprintf fmt "%a@[<v 2>{@\n"
		  (fun fmt -> self#line_directive ~forcefile:false fmt) loc;
		List.iter (fun b ->
		  List.iter (fun (tk,pred) ->
		    let prop = Property.ip_of_ensures
		      kf (Kstmt stmt) b (tk,pred) in
		    if List.mem prop props then
		      begin
			let id = Prop_id.to_id prop in
			self#bhv_assumes_begin fmt b pred.ip_loc;
			self#pc_assert_exception fmt pred.ip_content pred.ip_loc
			  "Stmt Post-condition!" id prop;
			self#bhv_assumes_end fmt b
		      end
		  ) b.b_post_cond
		) bhvs.spec_behavior;
		Format.fprintf fmt "}@\n @]"
	      )
	    else
	      None
	  else
	    None
	in
	begin
	  match contract with
	  | None -> ()
	  | Some c ->
	    let new_contract fmt =
	      self#bhv_guard_begin fmt behaviors loc;
	      c fmt;
	      self#bhv_guard_end fmt behaviors
	    in
	    end_contract := new_contract :: !end_contract
	end
      | AAssert (_,pred) ->
	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  let id = Prop_id.to_id prop in
	  self#bhv_guard_begin fmt behaviors loc;
	  self#pc_assert_exception fmt pred.content pred.loc "Assert!" id prop;
	  self#bhv_guard_end fmt behaviors
      | AInvariant (_,true,pred) ->
	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  let id = Prop_id.to_id prop in
	  let f fmt msg =
	    self#bhv_guard_begin fmt behaviors loc;
	    self#pc_assert_exception fmt pred.content pred.loc msg id prop;
	    self#bhv_guard_end fmt behaviors
	  in
	  f fmt "Loop invariant not established!";
	  end_loop :=
	    (fun fmt -> f fmt "Loop invariant not preserved!") :: !end_loop
      | AVariant (term,_) ->
	let prop = Property.ip_of_code_annot_single kf stmt ca in
	if List.mem prop props then
	  begin
	    let id = Prop_id.to_id prop in
	    let term' = self#term_and_var fmt term in
	    Format.fprintf fmt "@[<hv>%a@[<v 2>if ((%s) < 0)"
	      (fun fmt -> self#line_directive ~forcefile:false fmt) loc term';
	    Format.fprintf fmt
	      "pathcrawler_assert_exception(\"Variant non positive\",%i);" id;
	    Format.fprintf fmt "@]@]";
	    translated_properties <- prop :: translated_properties;
	    begin_loop :=
	      (fun fmt ->
		let term' = self#term_and_var fmt term in
		Format.fprintf fmt "int old_variant_%i = %s;@\n" id term')
	    :: !begin_loop;
	    end_loop :=
	      (fun fmt ->
		Format.fprintf fmt "@[<hv>%a@[<v 2>if ((old_variant_%i) < 0)"
		  (fun fmt -> self#line_directive ~forcefile:false fmt) loc id;
		Format.fprintf fmt
		  "pathcrawler_assert_exception(\"Variant non positive\",%i);"
		  id;
		Format.fprintf fmt "@]@]";
		let term' = self#term_and_var fmt term in
		Format.fprintf fmt "@[<hv>%a@[<v 2>if ((%s) >= old_variant_%i)"
		  (fun fmt -> self#line_directive ~forcefile:false fmt) loc
		  term' id;
		Format.fprintf fmt
		  "pathcrawler_assert_exception(\"Variant non decreasing\",%i);"
		  id;
		Format.fprintf fmt "@]@]";
		translated_properties <- prop :: translated_properties)
	    :: !end_loop
	  end
      | _ -> ()
    ) stmt;
    begin
      match stmt.skind with
      | Loop(_,b,l,_,_) ->
	Format.fprintf fmt "%a@[<v 2>while (1) {@\n"
	  (fun fmt -> self#line_directive fmt) l;
	List.iter (fun s -> s fmt) !begin_loop;
	Format.fprintf fmt "%a" (fun fmt -> self#block fmt) b;
	List.iter (fun s -> s fmt) !end_loop;
	Format.fprintf fmt "}@\n @]"
      | Return _ ->
	begin
	  match postcond with
	  | Some post_cond -> post_cond fmt; postcond <- None
	  | None -> ()
	end;
	begin
	  match dealloc with
	  | Some de_alloc -> de_alloc fmt; dealloc <- None
	  | None -> ()
	end;
	self#stmtkind next fmt stmt.skind
      | _ -> self#stmtkind next fmt stmt.skind
    end;
    List.iter (fun contract -> contract fmt) !end_contract;
    if has_code_annots then Format.fprintf fmt "}@\n @]";
    Format.pp_close_box fmt ();
    Format.pp_close_box fmt ()
  (* end of annotated_stmt *)

  method! global fmt g =
    if first_global then
      begin
	Format.fprintf fmt
	  "extern int pathcrawler_assert_exception(char*,int);@\n";
	Format.fprintf fmt "extern int pathcrawler_dimension(void*);@\n";
	first_global <- false
      end;
    match g with
    | GFun (fundec, l) ->
      if print_var fundec.svar then
	begin
	  self#in_current_function fundec.svar;
	  (* If the function has attributes then print a prototype because
	   * GCC cannot accept function attributes in a definition *)
	  let oldattr = fundec.svar.vattr in
	  (* Always pring the file name before function declarations *)
	  (* Prototype first *)
	  if oldattr <> [] then
	    (self#line_directive fmt l;
	     Format.fprintf fmt "%a;@\n" self#vdecl_complete fundec.svar);
	  (* Temporarily remove the function attributes *)
	  fundec.svar.vattr <- [];
	  (* Body now *)
	  self#line_directive ~forcefile:true fmt l;
	  self#fundecl fmt fundec;
	  fundec.svar.vattr <- oldattr;
	  Format.fprintf fmt "@\n";
	  self#out_current_function
	end
    | GType (typ, l) ->
      self#line_directive ~forcefile:true fmt l;
      Format.fprintf fmt "typedef %a;@\n"
	(self#typ (Some (fun fmt -> Format.fprintf fmt "%s" typ.tname)))
	typ.ttype
    | GEnumTag (enum, l) ->
      self#line_directive fmt l;
      if verbose then 
        Format.fprintf fmt "/* Following enum is equivalent to %a */@\n" 
          (self#typ None) 
          (TInt(enum.ekind,[]));
      Format.fprintf fmt "enum@[ %a {@\n%a@]@\n}%a;@\n"
	self#varname enum.ename
	(Pretty_utils.pp_list ~sep:",@\n"
	   (fun fmt item ->
	     Format.fprintf fmt "%s = %a"
	       item.einame
	       self#exp item.eival))
	enum.eitems
	self#attributes enum.eattr
    | GEnumTagDecl (enum, l) -> (* This is a declaration of a tag *)
      self#line_directive fmt l;
      Format.fprintf fmt "enum %a;@\n" self#varname enum.ename
    | GCompTag (comp, l) -> (* This is a definition of a tag *)
      let n = comp.cname in
      let su =
	if comp.cstruct then "struct"
	else "union"
      in
      let sto_mod, rest_attr = Cil.separateStorageModifiers comp.cattr in
      self#line_directive ~forcefile:true fmt l;
      Format.fprintf fmt "@[<3>%s%a %a {@\n%a@]@\n}%a;@\n"
	su
	self#attributes sto_mod
	self#varname n
	(Pretty_utils.pp_list ~sep:"@\n" self#fieldinfo)
	comp.cfields
	self#attributes rest_attr
    | GCompTagDecl (comp, l) -> (* This is a declaration of a tag *)
      self#line_directive fmt l;
      Format.fprintf fmt "%s;@\n" (Cil.compFullName comp)
    | GVar (vi, io, l) ->
      if print_var vi then begin
	self#line_directive ~forcefile:true fmt l;
        if vi.vghost then Format.fprintf fmt "/*@@ ghost@ ";
	self#vdecl fmt vi;
	(match io.init with
	  None -> ()
	| Some i ->
	  Format.fprintf fmt " = ";
	  let islong =
	    match i with
	      CompoundInit (_, il) when List.length il >= 8 -> true
	    | _ -> false
	  in
	  if islong then begin
	    self#line_directive fmt l;
	    Format.fprintf fmt "  @[@\n"
	  end;
	  self#init fmt i;
	  if islong then Format.fprintf fmt "@]");
	Format.fprintf fmt ";%t@\n" 
          (if vi.vghost then fun fmt -> Format.fprintf fmt "@ */" else ignore)
      end
    (* print global variable 'extern' declarations, and function prototypes *)
    | GVarDecl (funspec, vi, l) ->
      if print_var vi then begin
	if Cil.isFunctionType vi.vtype then self#in_current_function vi;
	self#opt_funspec fmt funspec;
	self#line_directive fmt l;
	Format.fprintf fmt "%a@\n@\n" self#vdecl_complete vi;
	if Cil.isFunctionType vi.vtype then self#out_current_function
      end
    | GAsm (s, l) ->
      self#line_directive fmt l;
      Format.fprintf fmt "__asm__(\"%s\");@\n" (Escape.escape_string s)
    | GPragma (Attr(_an, _args), _l) -> Format.fprintf fmt "@\n"
    | GPragma (AttrAnnot _, _) -> Format.fprintf fmt "@\n"
    | GAnnot (decl,l) ->
      self#line_directive fmt l;
      Format.fprintf fmt "/*@@@ %a@ */@\n" self#global_annotation decl
    | GText s  -> if s <> "//" then Format.fprintf fmt "%s@\n" s
  (* end of global *)

  (* prints a predicate and returns the name of the variable containing the
     return value *)
  method private predicate_named_and_var fmt pred_named =
    self#predicate_and_var fmt pred_named.content

  (* factorization of predicate_and_var for \exists and \forall  *)
  method private quantif_predicate_and_var ~forall fmt logic_vars hyps goal =
    if (List.length logic_vars) > 1 then
      failwith "quantification on many variables unsupported!";
    let var = "__stady_pred_" ^ (string_of_int pred_cpt) in
    let guards, vars = compute_guards [] logic_vars hyps in
    if vars <> [] then
      failwith "Unguarded variables in quantification!";
    let t1,r1,lv,r2,t2 = List.hd guards in
    let iter = lv.lv_name in
    pred_cpt <- pred_cpt + 1;
    Format.fprintf fmt "int %s = %i;@\n" var (if forall then 1 else 0);
    Format.fprintf fmt "{@\n";
    Format.fprintf fmt "int %s;@\n" iter;
    let t1' = self#term_and_var fmt t1 in
    let t2' = self#term_and_var fmt t2 in
    Format.fprintf fmt "for (%s = %s%s; %s %a %s && %s %s; %s++) {@\n"
      iter
      t1'
      (match r1 with Rlt -> "+1" | Rle -> "" | _ -> assert false)
      iter
      self#relation r2
      t2'
      (if forall then "" else "!")
      var
      iter;
    let goal_var = self#predicate_named_and_var fmt goal in 
    Format.fprintf fmt "%s = %s;@\n" var goal_var;
    Format.fprintf fmt "}@\n";
    Format.fprintf fmt "}@\n";
    var
  (* end of quantif_predicate_and_var *)

  (* prints a predicate and returns the name of the variable containing the
     return value *)
  method private predicate_and_var fmt pred =
    match pred with
    | Ptrue -> "1"
    | Pfalse -> "0"
    | Pvalid(_,term) | Pvalid_read(_,term) ->
      let x, y = extract_terms term in
      let x',y' = self#term_and_var fmt x, self#term_and_var fmt y in
      Format.fprintf Format.str_formatter
	"((%s) >= 0 && (pathcrawler_dimension(%s) > (%s)))"
	y' x' y';
      Format.flush_str_formatter()
    | Pforall(logic_vars,{content=Pimplies(hyps,goal)}) ->
      self#quantif_predicate_and_var ~forall:true fmt logic_vars hyps goal
    | Pexists(logic_vars,{content=Pand(hyps,goal)}) ->
      self#quantif_predicate_and_var ~forall:false fmt logic_vars hyps goal
    | Pforall _ -> failwith "\\forall not of the form \\forall ...; a ==> b;"
    | Pexists _ -> failwith "\\exists not of the form \\exists ...; a && b;"
    | Pnot(pred1) ->
      let pred1_var = self#predicate_named_and_var fmt pred1 in
      Format.fprintf Format.str_formatter "!(%s)" pred1_var;
      Format.flush_str_formatter()
    | Pand(pred1,pred2) ->
      let pred1_var = self#predicate_named_and_var fmt pred1 in
      let pred2_var = self#predicate_named_and_var fmt pred2 in
      Format.fprintf Format.str_formatter "(%s && %s)" pred1_var pred2_var;
      Format.flush_str_formatter()
    | Por(pred1,pred2) ->
      let pred1_var = self#predicate_named_and_var fmt pred1 in
      let pred2_var = self#predicate_named_and_var fmt pred2 in
      Format.fprintf Format.str_formatter "(%s || %s)" pred1_var pred2_var;
      Format.flush_str_formatter()
    | Pimplies(pred1,pred2) ->
      let var = "__stady_pred_" ^ (string_of_int pred_cpt) in
      pred_cpt <- pred_cpt + 1;
      Format.fprintf fmt "int %s = 1;@\n" var;
      let pred1_var = self#predicate_named_and_var fmt pred1 in
      Format.fprintf fmt "if (%s) {@\n" pred1_var;
      let pred2_var = self#predicate_named_and_var fmt pred2 in
      Format.fprintf fmt "%s = %s;@\n" var pred2_var;
      Format.fprintf fmt "}@\n";
      var
    (* TODO: not safe enough *)
    | Piff(pred1,pred2) ->
      let pred1_var = self#predicate_named_and_var fmt pred1 in
      let pred2_var = self#predicate_named_and_var fmt pred2 in
      Format.fprintf Format.str_formatter
	"( ( !(%s) || %s ) && ( !(%s) || %s ) )"
	pred1_var pred2_var pred2_var pred1_var;
      Format.flush_str_formatter()
    | Prel(rel,t1,t2) ->
      let t1', t2' = self#term_and_var fmt t1, self#term_and_var fmt t2 in
      Format.fprintf Format.str_formatter "(%s %a %s)"
	t1' self#relation rel t2';
      Format.flush_str_formatter()
    | Pat (p,_) ->
      Options.Self.warning "%a unsupported!" Printer.pp_predicate pred;
      self#predicate_named_and_var fmt p
    | _ ->
      Options.Self.warning "%a unsupported" Printer.pp_predicate pred;
      "1"
(* end of pred_and_var *)
end (* end of printer class *)
