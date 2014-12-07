(*
 * Copyright (C)2005-2013 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *)

open Ast
open Type
open Common

type context_infos = {
	com : Common.context;
	mutable externs : (string * bool) list;
	mutable modules : string list;
}
type context = {
	inf : context_infos;
	ch : out_channel;
	buf : Buffer.t;
	path : path;
	mutable get_sets : (string * bool,string) Hashtbl.t;
	mutable curclass : tclass;
	mutable tabs : string;
	mutable in_static : bool;
	mutable imports : (string list, (string * string option) list) Hashtbl.t;
	mutable constructor_block : bool;
}

let follow = Abstract.follow_with_abstracts

let is_var_field f =
	match f with
	| FStatic (_,f) | FInstance (_,_,f) ->
		(match f.cf_kind with Var _ | Method MethDynamic -> true | _ -> false)
	| _ ->
		false

let protect name =
	match name with
	| "mod" | "__main__" -> "_" ^ name
	| _ -> name

let rec find_name ctx name =
	let exists = ref false in
	Hashtbl.iter (fun _ names ->
		List.iter (fun (imp, exp) ->
			match imp, exp with
			| _, Some cname when cname == name ->
				exists := true;
			| cname, None when cname == name ->
				exists := true;
			| _ -> ();
		) names;
	) ctx.imports;
	if !exists then
		find_name ctx ("A" ^ name)
	else
		name

let s_path ctx path p =
	match path with
	| ([],"Int") -> "i32"
	| ([],"Float") -> "f64"
	| ([],"Dynamic") -> "Box<Dynamic>"
	| ([],"Bool") -> "bool"
	| (["haxe"],"Int32") ->
		"i32"
	| (["haxe"],"Int64") ->
		"i64"
	| (pack,actual_name) ->
		let name = ref actual_name in
		(* check if this package has imports already *)
		let others = (try Hashtbl.find ctx.imports pack with Not_found -> []) in
		(* if this type is not already in the imports *)
		if not (List.exists (fun (this_name, _) -> actual_name == this_name) others) then begin
			name := find_name ctx actual_name;
			(* append it to it *)
			Hashtbl.replace ctx.imports pack ((actual_name, if !name == actual_name then None else Some !name) :: others);
			(* add an extern *)
			begin match pack with
				| crate :: _ when not (List.exists (fun (name, _) -> crate == name) ctx.inf.externs) ->
					ctx.inf.externs <- ctx.inf.externs@[crate, false];
				| _ -> ()
			end
		end;
		!name

let reserved =
	let h = Hashtbl.create 0 in
	List.iter (fun l -> Hashtbl.add h l ())
	["abstract"; "alignof"; "as"; "be"; "box"; "break"; "const"; "continue"; "crate"; "do";
"else"; "enum"; "extern"; "false"; "final"; "fn"; "for"; "if"; "impl"; "in"; "let"; "loop";
"match"; "mod"; "move"; "mut"; "offsetof"; "once"; "override"; "priv"; "proc"; "pub"; "pure";
"ref"; "return"; "sizeof"; "static"; "self"; "struct"; "super"; "true"; "trait"; "type";
"typeof"; "unsafe"; "unsized"; "use"; "virtual"; "where"; "while"; "yield"
	];
	h

	(* "each", "label" : removed (actually allowed in locals and fields accesses) *)

let s_ident n =
	if Hashtbl.mem reserved n then "_" ^ n else n

let valid_rust_ident s =
	try
		for i = 0 to String.length s - 1 do
			match String.unsafe_get s i with
			| 'a'..'z' | 'A'..'Z' | '_' -> ()
			| '0'..'9' when i > 0 -> ()
			| _ -> raise Exit
		done;
		true
	with Exit ->
		false

let rec create_dir acc = function
	| [] -> ()
	| d :: l ->
		let dir = String.concat "/" (List.rev (d :: acc)) in
		if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
		create_dir (d :: acc) l

let init infos path =
	let dir = infos.com.file :: "src" :: fst path in
	create_dir [] dir;
	let ch = open_out (String.concat "/" dir ^ "/" ^ snd path ^ ".rs") in
	let imports = Hashtbl.create 0 in
	{
		inf = infos;
		tabs = "";
		ch = ch;
		path = path;
		buf = Buffer.create (1 lsl 14);
		in_static = false;
		imports = imports;
		curclass = null_class;
		get_sets = Hashtbl.create 0;
		constructor_block = false;
	}

let close ctx =
	let is_main = ctx.curclass.cl_path = ([], "__main__") in
	if is_main then begin
		output_string ctx.ch "#![feature(phase)]\n";
		output_string ctx.ch "#[phase(link, plugin)]\n";
		output_string ctx.ch "extern crate haxe;\n";
		List.iter (fun (crate, _) ->
			match crate with
			| "std" | "core" | "haxe" -> ();
			| _ -> output_string ctx.ch ("extern crate "^crate^";\n");
		) ctx.inf.externs;
	end;
	Hashtbl.iter (fun paths names ->
		let output_path = fun _ -> output_string ctx.ch ("use " ^ String.concat "" (List.map (fun path -> path ^ "::") paths)) in
		let last = ";\n" in
		match names with
		| [(name, None)] ->
			output_path();
			output_string ctx.ch (name ^ last)
		| [(name, Some export)] ->
			output_path();
			output_string ctx.ch (name ^ " as " ^ export ^ last)
		| names ->
			let (unexported, exported) = List.partition (fun (_, export) -> export == None) names in
			let unexported = List.map (fun (name, _) -> name) unexported in
			output_path();
			output_string ctx.ch ("{" ^ String.concat ", " unexported ^ "}" ^ last);
			List.iter (fun (name, export) ->
				output_path();
				match export with
				| Some export ->
					output_string ctx.ch (name ^ " as " ^ export ^ last);
				| _ -> ()
			) exported;
	) ctx.imports;
	if is_main then begin
		List.iter (fun name ->
			output_string ctx.ch ("mod " ^ name ^ ";\n")
		) ctx.inf.modules;
	end;
	output_string ctx.ch (Buffer.contents ctx.buf);
	close_out ctx.ch

let spr ctx s = Buffer.add_string ctx.buf s
let print ctx = Printf.kprintf (fun s -> Buffer.add_string ctx.buf s)

let unsupported p = error "This expression cannot be generated into Rust" p

let soft_newline ctx =
	print ctx "\n%s" ctx.tabs

let newline ctx =
	let rec loop p =
		match Buffer.nth ctx.buf p with
		| '}' | '{' | ':' | ';' -> soft_newline ctx
		| '\n' | '\t' | ' ' -> loop (p - 1)
		| _ -> print ctx ";\n%s" ctx.tabs
	in
	loop (Buffer.length ctx.buf - 1)

let block_newline ctx = match Buffer.nth ctx.buf (Buffer.length ctx.buf - 1) with
	| '}' -> print ctx ";\n%s" ctx.tabs
	| _ -> newline ctx

let rec concat ctx s f = function
	| [] -> ()
	| [x] -> f x
	| x :: l ->
		f x;
		spr ctx s;
		concat ctx s f l

let open_block ctx =
	let oldt = ctx.tabs in
	ctx.tabs <- "    " ^ ctx.tabs;
	(fun() -> ctx.tabs <- oldt)

let should_wrap ctx t p = match follow t with
	| TInst({cl_kind = KNormal | KExtension _ | KExpr _ | KMacroType | KGenericBuild _},_) -> true
	| TType ({t_path = [], "Null"}, _) ->
		true
	| _ -> false

let rec type_str ctx t p =
	let str = match follow t with
	| TAbstract ({ a_impl = Some _ } as a,pl) ->
		type_str ctx (Abstract.get_underlying_type a pl) p
	| TAbstract (a,_) ->
		(match a.a_path with
		| [], "Void" -> "()"
		| [], "UInt" -> "u32"
		| [], "Int" -> "i32"
		| [], "Single" -> "f32"
		| [], "Float" -> "f64"
		| [], "Bool" -> "bool"
		| _ -> s_path ctx a.a_path p)
	| TEnum (e,_) ->
		s_path ctx e.e_path p
	| TInst ({ cl_path = [],"Array" },[pt]) ->
		"Vec<" ^ type_str ctx pt p ^ ">"
	| TInst ({ cl_path = ["rust"],"NativeArray" },[pt]) ->
		"[" ^ type_str ctx pt p ^ "]"
	| TInst (c,[pt]) when (c.cl_extern && Meta.has Meta.Native c.cl_meta) ->
		begin match Meta.get Meta.Native c.cl_meta with
			| (Meta.Native, [EConst(String path), _], _) -> s_path ctx (parse_path path) p
			| _ -> s_path ctx c.cl_path p
		end
	| TInst (c,_) ->
		(match c.cl_kind with
		| KGeneric | KGenericInstance _ | KAbstractImpl _ | KNormal -> s_path ctx c.cl_path p
		| KTypeParameter p  ->
			let (_, name) = c.cl_path in
			name
		| KExtension _ | KExpr _ | KMacroType | KGenericBuild _ -> "Dynamic")
	| TFun (args, ret) ->
		"|" ^ String.concat "," (List.map (fun (_, _, ty) ->
			type_str ctx ty p
		) args) ^ "| -> " ^ type_str ctx ret p
	| TMono r ->
		(match !r with None -> "Dynamic" | Some t -> type_str ctx t p)
	| TAnon _ ->
		"Object"
	| TDynamic _ ->
		"Dynamic"
	| TType (t,args) ->
		type_str ctx (apply_params t.t_params args t.t_type) p
	| TLazy f ->
		type_str ctx ((!f)()) p
	in
	if should_wrap ctx t p then
		"Option<" ^ str ^ ">"
	else
		str

let this ctx =
	if ctx.constructor_block then
		"this"
	else
		"self"

let generate_resources ctx =
	if Hashtbl.length ctx.inf.com.resources <> 0 then begin
		spr ctx "pub static RESOURCES: haxe::Resources = resources_package!{";
		let block = open_block ctx in
		soft_newline ctx;
		Hashtbl.iter (fun name content ->
			print ctx "\"%s\" => b\"%s\";" (s_escape name) (s_escape content);
			soft_newline ctx;
		) ctx.inf.com.resources;
		block();
		soft_newline ctx;
		spr ctx "}";
		newline ctx;
	end

let gen_constant ctx p = function
	| TInt i -> print ctx "%ldi32" i
	| TFloat s -> spr ctx s
	| TString s -> print ctx "\"%s\"" (s_escape s)
	| TBool b -> spr ctx (if b then "true" else "false")
	| TNull -> spr ctx "None"
	| TThis -> spr ctx (this ctx)
	| TSuper -> spr ctx "super"

let gen_generics ctx params p =
	if (List.length params) > 0 then begin
		spr ctx "<";
		concat ctx ", " (fun (name, t) ->
			let ty = type_str ctx t p in
			print ctx "%s: %s" name (if ty == name then "Dynamic" else ty);
		) params;
		spr ctx ">";
	end

let rec gen_call ctx e el r =
	let gen = fun e -> gen_expr ctx e true in
	match e.eexpr , el with
	| TCall (x,_) , el ->
		spr ctx "(";
		gen e;
		spr ctx ")";
		spr ctx "(";
		concat ctx ", " gen el;
		spr ctx ")";
	| TLocal( { v_name = "__rust__" } ), [ { eexpr = TConst(TString(s)) }] ->
		spr ctx s;
	| TLocal { v_name = "__as__" }, [e1;e2] ->
		gen e1;
		spr ctx " as ";
		gen e2;
	| TLocal { v_name = "__vector__" }, exprs ->
		spr ctx "[";
		concat ctx ", " gen exprs;
		spr ctx "]"
	| TLocal { v_name = "__macro__" }, { eexpr = TConst(TString(macro))}:: exprs ->
		print ctx "%s!(" macro;
		concat ctx ", " gen exprs;
		spr ctx ")"
	| _ ->
		gen e;
		spr ctx "(";
		concat ctx ", " gen el;
		spr ctx ")"

and gen_expr_no_paren ctx e is_val =
	match e.eexpr with
	| TParenthesis e -> gen_expr ctx e is_val
	| _ -> gen_expr ctx e is_val

and gen_expr ctx e is_val =
	let default_wrap = fun gen ->
		if should_wrap ctx e.etype e.epos then begin
			spr ctx "Some(";
			gen();
			spr ctx ")";
		end else
			gen();
	in
	match e.eexpr with
	| TConst c ->
		default_wrap (fun _ -> gen_constant ctx e.epos c);
	| TLocal v ->
		spr ctx (s_ident v.v_name)
	| TArray (e1,e2) ->
		default_wrap (fun _ -> 
			gen_expr ctx e1 true;
			spr ctx "[";
			gen_expr ctx e2 true;
			spr ctx "]";
		);
	| TBinop (OpAssignOp op,e1,e2) when is_val ->
		spr ctx "{";
		let block = open_block ctx in
		soft_newline ctx;
		gen_expr ctx e1 true;
		spr ctx " = ";
		gen_expr ctx e1 true;
		print ctx " %s " (s_binop op);
		gen_expr ctx e2 true;
		newline ctx;
		gen_expr ctx e1 true;
		block();
		soft_newline ctx;
		spr ctx "}";
	| TUnop ((Not | Neg | NegBits),_,e) ->
		spr ctx "!";
		gen_expr ctx e true;
	| TUnop (Decrement,_,e) ->
		let one = mk (TConst(TInt(Int32.one))) e.etype e.epos in
		let ex = mk (TBinop(OpAssignOp(OpSub), e, one)) e.etype e.epos in
		gen_expr ctx ex is_val
	| TUnop (Increment,_,e) ->
		let one = mk (TConst(TInt(Int32.one))) e.etype e.epos in
		let ex = mk (TBinop(OpAssignOp(OpAdd), e, one)) e.etype e.epos in
		gen_expr ctx ex is_val
	| TBinop (op,e1,e2) ->
		gen_expr ctx e1 true;
		print ctx " %s " (s_binop op);
		gen_expr ctx e2 true;
	| TEnumParameter (e,f,i) ->
		gen_expr ctx e true;
		print ctx ".get_params(%i)" i;
	| TField( _, FStatic({ cl_path = ([], "Math") }, { cf_name = "NaN" }) ) ->
		default_wrap (fun _ -> spr ctx "::std::f64::NAN");
	| TField( _, FStatic({ cl_path = ([], "Math") }, { cf_name = "PI" }) ) ->
		default_wrap (fun _ -> spr ctx "::std::f64::consts::PI");
	| TField( _, FStatic({ cl_path = ([], "Math") }, { cf_name = "POSITIVE_INFINITY" }) ) ->
		default_wrap (fun _ -> spr ctx "::std::f64::INFINITY");
	| TField( _, FStatic({ cl_path = ([], "Math") }, { cf_name = "NEGATIVE_INFINITY" }) ) ->
		default_wrap (fun _ -> spr ctx "::std::f64::NEG_INFINITY");
	| TField (e,s) ->
		gen_expr ctx e true;
		if should_wrap ctx e.etype e.epos then
			spr ctx ".unwrap()";
		let name = (field_name s) in
		(match follow e.etype with
		| TAnon {a_status = {contents = Statics _ | EnumStatics _}}  ->
			print ctx "::%s" (s_ident name);
		| TAnon _  ->
			print ctx "[\"%s\"]" (s_escape name);
		| _ ->
			print ctx ".%s" (s_ident name);)
	| TTypeExpr t ->
		spr ctx (s_path ctx (t_path t) e.epos)
	| TParenthesis e ->
		spr ctx "(";
		gen_expr ctx e is_val;
		spr ctx ")";
	| TMeta (_,e) ->
		gen_expr ctx e is_val
	| TReturn eo ->
		begin match eo with
		| None ->
			spr ctx "return"
		| Some e when (match follow e.etype with TEnum({ e_path = [],"Void" },[]) | TAbstract ({ a_path = [],"Void" },[]) -> true | _ -> false) ->
			print ctx "{";
			let bend = open_block ctx in
			soft_newline ctx;
			gen_expr ctx e false;
			bend();
			newline ctx;
			print ctx "}";
		| Some e ->
			spr ctx "return ";
			gen_expr ctx e true
		end
	| TBreak ->
		spr ctx "break"
	| TContinue ->
		spr ctx "continue"
	| TBlock [{eexpr = TReturn Some {eexpr = TBlock[ex]}}] when is_val && not ctx.constructor_block ->
		spr ctx "{";
		let bend = open_block ctx in
		soft_newline ctx;
		gen_expr ctx ex true;
		bend();
		soft_newline ctx;
		spr ctx "}";
	| TBlock [{eexpr = TReturn Some ex}] when is_val && not ctx.constructor_block ->
		spr ctx "{";
		let bend = open_block ctx in
		soft_newline ctx;
		gen_expr ctx ex true;
		bend();
		soft_newline ctx;
		spr ctx "}";
	| TBlock [] when is_val ->
		spr ctx "{}";
	| TBlock els when is_val && not ctx.constructor_block ->
		let rec last = function
			| x::[] -> x
			| _::xs -> last xs
			| []    -> failwith "no element" in
		let last_el = last els in
		print ctx "{";
		let bend = open_block ctx in
		List.iter (fun e -> 
			block_newline ctx;
			gen_expr ctx e (e == last_el)
		) els;
		bend();
		soft_newline ctx;
		print ctx "}";
	| TBlock el ->
		print ctx "{";
		let bend = open_block ctx in
		if ctx.constructor_block then begin
			ctx.constructor_block <- false;
			block_newline ctx;
			print ctx "let ref mut this: %s = ::std::default::Default::default()" (s_path ctx ctx.curclass.cl_path e.epos);
		end;
		List.iter (fun e -> 
			block_newline ctx;
			gen_expr ctx e false
		) el;
		bend();
		newline ctx;
		print ctx "}";
	| TFunction f ->
		spr ctx "|";
		concat ctx ", " (fun (v, c) ->
			print ctx "%s : %s" (s_ident v.v_name) (type_str ctx v.v_type e.epos)
		) f.tf_args;
		print ctx "| -> %s " (type_str ctx f.tf_type e.epos);
		gen_expr ctx f.tf_expr true;
	| TCall (v,el) ->
		gen_call ctx v el e.etype
	| TArrayDecl el ->
		default_wrap(fun _ ->
			spr ctx "vec![";
			concat ctx "," (fun el -> gen_expr ctx el true) el;
			spr ctx "]"
		);
	| TThrow e ->
		spr ctx "panic!(";
		gen_expr ctx e true;
		spr ctx ")";
	| TVar (v,eo) ->
		spr ctx "let mut ";
		print ctx "%s : %s" (s_ident v.v_name) (type_str ctx v.v_type e.epos);
		begin match eo with
		| None -> ()
		| Some e ->
			spr ctx " = ";
			gen_expr ctx e true;
		end;
		spr ctx ";"
	| TNew (c,params,el) ->
		default_wrap (fun _ ->
			print ctx "%s::new(" (s_path ctx c.cl_path e.epos);
			concat ctx "," (fun e -> gen_expr ctx e true) el;
			spr ctx ")"
		);
	| TIf (cond,e,eelse) ->
		spr ctx "if ";
		gen_expr_no_paren ctx cond true;
		spr ctx " ";
		gen_block ctx e is_val;
		begin match eelse with
		| None -> ()
		| Some e ->
			soft_newline ctx;
			spr ctx " else ";
			gen_block ctx e is_val
		end
	| TWhile (cond,e,NormalWhile) ->
		spr ctx "while ";
		gen_expr_no_paren ctx cond true;
		spr ctx " ";
		gen_block ctx e false;
	| TWhile (cond,e,DoWhile) ->
		spr ctx "loop {";
		let loop = open_block ctx in
		soft_newline ctx;
		gen_expr ctx e false;
		newline ctx;
		spr ctx "if ";
		gen_expr_no_paren ctx cond true;
		spr ctx " { break; }";
		loop();
		soft_newline ctx;
		spr ctx "}";
	| TObjectDecl fields ->
		spr ctx "object!{ ";
		let obj = open_block ctx in
		concat ctx ", " (fun (f,e) ->
			soft_newline ctx;
			print ctx "\"%s\" : " (s_escape f);
			gen_expr ctx e true;
		) fields;
		obj();
		soft_newline ctx;
		spr ctx "}"
	| TFor (v,it,e) ->
		print ctx "for %s in " (s_ident v.v_name);
		gen_expr_no_paren ctx it true;
		spr ctx " ";
		gen_block ctx e true;
	| TTry (e,catchs) ->
		spr ctx "try ";
		gen_expr ctx e is_val;
		List.iter (fun (v,e) ->
			newline ctx;
			print ctx "catch( %s : %s )" (s_ident v.v_name) (type_str ctx v.v_type e.epos);
			gen_expr ctx e is_val;
		) catchs;
	| TSwitch (e,cases,def) ->
		spr ctx "match ";
		gen_expr ctx e true;
		spr ctx " {";
		let block = open_block ctx in
		soft_newline ctx;
		concat ctx ", " (fun (el,e2) ->
			concat ctx " | " (fun e -> gen_expr ctx e true) el;
			spr ctx " => ";
			gen_expr ctx e2 is_val;
			soft_newline ctx;
		) cases;
		begin match def with
		| None -> ()
		| Some e ->
			spr ctx "_ => ";
			gen_expr ctx e is_val;
			soft_newline ctx
		end;
		block();
		soft_newline ctx;
		spr ctx "}"
	| TCast (e1,None) ->
		let s = type_str ctx e.etype e.epos in
		spr ctx "((";
		gen_expr ctx e1 true;
		print ctx ") as %s)" s
	| TCast (e1,Some t) ->
		gen_expr ctx (Codegen.default_cast ctx.inf.com e1 t e.etype e.epos) true

and gen_block ctx e is_val =
	soft_newline ctx;
	match e.eexpr with
	| TBlock _ ->
		gen_expr ctx e is_val
	| _ ->
		spr ctx "{";
		let block = open_block ctx in
		soft_newline ctx;
		gen_expr ctx e is_val;
		block();
		(if is_val then soft_newline else newline) ctx;
		spr ctx "}"

let is_mutable ctx e var =
	let result = ref false in
	Type.iter (fun e ->
		match e.eexpr with
		| TBinop (OpAssign, {eexpr = e}, b)
		| TBinop (OpAssignOp _, {eexpr = e}, b) -> result := true
		| _ -> ()
	) e;
	!result

let generate_field ctx static f =
	soft_newline ctx;
	ctx.in_static <- static;
	let p = ctx.curclass.cl_pos in
	match f.cf_expr, f.cf_kind with
	| Some { eexpr = TFunction fd }, Method (MethNormal | MethInline) ->
		print ctx "fn %s" (s_ident f.cf_name);
		gen_generics ctx f.cf_params p;
		spr ctx "(";
		let mapped_args = List.map (fun (v, c) ->
			s_ident v.v_name ^ " : " ^ type_str ctx v.v_type p
		) fd.tf_args in
		let self_str = if is_mutable ctx fd.tf_expr (TConst TThis) then "&mut self" else "&self" in
		concat ctx ", " (fun arg -> spr ctx arg) (if (not static) then [self_str] @ mapped_args else mapped_args);
		print ctx ") -> %s " (type_str ctx fd.tf_type p);
		gen_expr ctx fd.tf_expr true;
		newline ctx
	| _ ->
		match follow f.cf_type with
		| TFun (args,r) when (match f.cf_kind with Method MethDynamic | Var _ -> false | _ -> true) ->
			spr ctx "fn";
			gen_generics ctx f.cf_params f.cf_pos;
			spr ctx "(";
			concat ctx ", " (fun (arg,o,t) ->
				let tstr = type_str ctx t p in
				print ctx "%s : %s" arg tstr;
			) args;
			print ctx ") : %s " (type_str ctx r p);
		| _ ->
			print ctx "pub %s: %s" f.cf_name (type_str ctx f.cf_type f.cf_pos)

let generate_class ctx c =
	ctx.curclass <- c;
	let (instance_fields, instance_methods) = List.partition (fun field -> match field.cf_kind with |Var _ -> true | _ -> false) c.cl_ordered_fields in
	if not c.cl_interface then begin
		spr ctx "#[deriving(Default)]";
		soft_newline ctx;
		print ctx "pub struct %s" (snd c.cl_path);
		gen_generics ctx c.cl_params c.cl_pos;
		match instance_fields with
		| [] -> spr ctx ";";
		| _ ->
			let cl = open_block ctx in
			spr ctx " {";
			concat ctx "," (generate_field ctx false) instance_fields;
			cl();
			soft_newline ctx;
			spr ctx "}";
	end;
	newline ctx;
	if c.cl_interface then
		print ctx "pub trait %s" (snd c.cl_path)
	else begin
		spr ctx "impl";
		gen_generics ctx c.cl_params c.cl_pos;
		print ctx " %s" (snd c.cl_path);
	end;
	(match c.cl_super with
	| None -> ()
	| Some (csup,_) -> print ctx ": %s " (s_path ctx csup.cl_path c.cl_pos));
	(match c.cl_implements with
	| [] -> ()
	| l ->
		spr ctx ":";
		concat ctx ", " (fun (i,_) -> print ctx "%s" (s_path ctx i.cl_path c.cl_pos)) l);
	spr ctx " {";
	let cl = open_block ctx in
	(match c.cl_constructor with
	| None -> ()
	| Some f ->
		let f = { f with
			cf_name = "new";
			cf_public = true;
			cf_type = TFun([], TInst(c, []));
			cf_kind = Method MethNormal;
		} in
		ctx.constructor_block <- true;
		generate_field ctx false f;
	);
	List.iter (generate_field ctx false) instance_methods;
	List.iter (generate_field ctx true) c.cl_ordered_statics;
	cl();
	soft_newline ctx;
	print ctx "}";
	newline ctx

let generate_main ctx =
	ctx.curclass <- { null_class with cl_path = [],"__main__" };
	generate_resources ctx;
	print ctx "pub fn main() {";
	let fl = open_block ctx in
	newline ctx;
	(match ctx.inf.com.main with
	| Some main ->
		gen_expr ctx main false
	| _ -> ());
	fl();
	newline ctx;
	print ctx "}";
	newline ctx

let generate_enum ctx e =
	print ctx "pub enum %s" (snd e.e_path);
	gen_generics ctx e.e_params e.e_pos;
	spr ctx " {";
	let cl = open_block ctx in
	PMap.iter (fun _ c ->
		soft_newline ctx;
		spr ctx c.ef_name;
		gen_generics ctx c.ef_params c.ef_pos;
		match c.ef_type with
		| TFun (args,_) ->
			if (List.length args) > 0 then begin
				spr ctx "(";
				concat ctx ", " (fun (_,_,t) ->
					spr ctx (type_str ctx t c.ef_pos);
				) args;
				spr ctx ")";
			end;
		| _ ->
			();
		spr ctx ",";
	) e.e_constrs;
	cl();
	soft_newline ctx;
	print ctx "}";
	soft_newline ctx

let is_bin com =
	match com.main with
	| Some _ -> true
	| None -> false

let generate_cargo infos =
	let dir = infos.com.file in
	create_dir [] [dir];
	let ch = open_out (dir ^ "/Cargo.toml") in
	output_string ch
("[package]
	name = \"haxe_project\"
	version = \"0.0.1\"
	authors = [\"This guy\"]

[" ^ (if is_bin infos.com then "[bin]" else "lib") ^ "]
	name = \"main\"
	path = \"src/__main__.rs\"

[dependencies]
");
	List.iter (fun (crate, cargo) ->
		if cargo then
			output_string ch (crate^" = \"*\";\n");
	) infos.externs;
	close_out ch

let add_module infos path =
	match path with
	| (pack :: _, _) when not (List.mem pack infos.modules) ->
		infos.modules <- [pack] @ infos.modules
	| ([], name) when not (List.mem name infos.modules) ->
		infos.modules <- [name] @ infos.modules
	| _ -> ()

let generate com =
	let infos = {
		com = com;
		externs = [];
		modules = [];
	} in
	List.iter (fun t ->
		match t with
		| TClassDecl c ->
			let c = (match c.cl_path with
				| (pack,name) -> { c with cl_path = (pack,protect name) }
			) in
			if not c.cl_extern then begin
				add_module infos c.cl_path;
				let ctx = init infos c.cl_path in
				generate_class ctx c;
				close ctx;
			end;
		| TEnumDecl e ->
			let pack,name = e.e_path in
			let e = { e with e_path = (pack,protect name) } in
			if not e.e_extern then
				add_module infos e.e_path;
				let ctx = init infos e.e_path in
				generate_enum ctx e;
				close ctx
		| _ ->
			()
	) com.types;
	let ctx = init infos ([],"__main__") in
	generate_main ctx;
	close ctx;
	generate_cargo infos;
    let old_dir = Sys.getcwd() in
    Sys.chdir com.file;
	if com.run_command "cargo build" <> 0 then failwith "Build failed";
	Sys.chdir old_dir