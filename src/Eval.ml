(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Evaluator *)

(* Author: Piotr Polesiuk, 2023,2024 *)

(** Value of the evaluator *)
type value =
  | VUnit
    (** Unit value *)

  | VNum of int
    (** Number *)

  | VStr of string
    (** String *)

  | VFn of (value -> value comp)
    (** Function *)

  | VCtor of int * value list
    (** Constructor of ADT *)

  | VLabel of UID.t
    (** Runtime label of control operator *)

(** CPS Computations *)
and 'v comp = ('v -> ans) -> ans

(** Stack frame (related to control operators) *)
and frame =
  { f_label : UID.t
  ; f_ret   : (value -> value comp)
  ; f_cont  : (value -> ans)
  }

(** Answer type: depends on stack *)
and ans = frame list -> unit

(* ========================================================================= *)
(* External functions (should be moved to other file *)

let unit_fun f = VFn (fun v cont -> cont (f ()))

let int_fun f = VFn (fun v cont ->
  match v with
  | VNum n -> cont (f n)
  | _ -> failwith "Runtime error!")

let str_fun f = VFn (fun v cont ->
  match v with
  | VStr s -> cont (f s)
  | _ -> failwith "Runtime error!")

let of_bool b =
  VCtor((if b then 1 else 0), [])

let int2_fun f = int_fun (fun x -> int_fun (f x))

let int_binop op = int2_fun (fun x y -> VNum (op x y))
let int_cmpop op = int2_fun (fun x y -> of_bool (op x y))

let str_cmpop op = str_fun (fun s1 -> str_fun (fun s2 -> of_bool (op s1 s2)))

let extern_map =
  [ "dbl_addInt",      int_binop ( + );
    "dbl_subInt",      int_binop ( - );
    "dbl_mulInt",      int_binop ( * );
    "dbl_divInt",      int_binop ( / );
    "dbl_modInt",      int_binop ( mod );
    "dbl_andInt",      int_binop ( land );
    "dbl_orInt",       int_binop ( lor );
    "dbl_xorInt",      int_binop ( lxor );
    "dbl_lslInt",      int_binop ( lsl );
    "dbl_lsrInt",      int_binop ( lsr );
    "dbl_asrInt",      int_binop ( asr );
    "dbl_eqInt",       int_cmpop ( = );
    "dbl_neqInt",      int_cmpop ( <> );
    "dbl_gtInt",       int_cmpop ( > );
    "dbl_ltInt",       int_cmpop ( < );
    "dbl_geInt",       int_cmpop ( >= );
    "dbl_leInt",       int_cmpop ( <= );
    "dbl_intToString", int_fun (fun n -> VStr (string_of_int n));
    "dbl_strCat",  str_fun (fun s1 -> str_fun (fun s2 -> VStr(s1 ^ s2)));
    "dbl_eqStr",   str_cmpop ( = );
    "dbl_neqStr",  str_cmpop ( <> );
    "dbl_gtStr",   str_cmpop ( > );
    "dbl_ltStr",   str_cmpop ( < );
    "dbl_geStr",   str_cmpop ( >= );
    "dbl_leStr",   str_cmpop ( <= );
    "dbl_strLen",  str_fun (fun s -> VNum (String.length s));
    "dbl_strGet",  str_fun (fun s -> int_fun (fun n -> VNum(Char.code s.[n])));
    "dbl_strMake", int_fun (fun n -> VStr (String.make 1 (Char.chr n)));
    "dbl_printStrLn", str_fun (fun s -> print_endline s; VUnit);
    "dbl_printStr",   str_fun (fun s -> print_string s; VUnit);
    "dbl_printInt",   int_fun (fun n -> print_int n; VUnit);
    "dbl_readLine",   unit_fun (fun () -> VStr (read_line ()));
    "dbl_exit",       int_fun exit;
  ] |> List.to_seq |> Hashtbl.of_seq

(* ========================================================================= *)

let to_string (v : value) =
  match v with
  | VUnit    -> "()"
  | VNum n   -> string_of_int n
  | VStr s   -> Printf.sprintf "\"%s\"" (String.escaped s)
  | VFn    _ -> "<fun>"
  | VCtor  _ -> "<ctor>"
  | VLabel _ -> "<label>"

module Env : sig
  type t

  val empty : t

  val extend : t -> Var.t -> value -> t

  val lookup : t -> Var.t -> value
end = struct
  type t = value Var.Map.t

  let empty = Var.Map.empty

  let extend env x v =
    Var.Map.add x v env

  let lookup env x =
    Var.Map.find x env
end

let run_stack v stack =
  match stack with
  | [] -> failwith "Runtime error"
  | f :: stack -> f.f_ret v f.f_cont stack

(** reset0 operator *)
let reset0 l comp ret cont stack =
  comp run_stack ({ f_label = l; f_ret = ret; f_cont = cont } :: stack)

let rec reify_cont gstack v cont stack =
  match gstack with
  | [] -> cont v stack
  | f :: gstack ->
    reify_cont gstack v f.f_cont
      ({ f_label = f.f_label; f_ret = f.f_ret; f_cont = cont } :: stack)

let rec grab l comp cont gstack stack =
  match stack with
  | [] -> failwith "Unhandled effect"
  | f :: stack ->
    let gstack =
      { f_label = f.f_label; f_ret = f.f_ret; f_cont = cont } :: gstack in
    let cont = f.f_cont in
    if f.f_label = l then
      comp (VFn(reify_cont gstack)) cont stack
    else
      grab l comp cont gstack stack

(** Shift0 operator *)
let shift0 l comp cont stack =
  grab l comp cont [] stack

let rec eval_expr env (e : Lang.Untyped.expr) cont =
  match e with
  | EValue v -> cont (eval_value env v)
  | ELet(x, e1, e2) ->
    eval_expr env e1 (fun v ->
    eval_expr (Env.extend env x v) e2 cont)
  | EApp(v1, v2) ->
    begin match eval_value env v1 with
    | VFn f -> f (eval_value env v2) cont
    | _ -> failwith "Runtime error!"
    end
  | EMatch(v, cls) ->
    begin match eval_value env v with
    | VCtor(n, vs) ->
      let (xs, body) = List.nth cls n in
      let env = List.fold_left2 Env.extend env xs vs in
      eval_expr env body cont
    | _ -> failwith "Runtime error!"
    end
  | ELabel(x, e) ->
    let l = UID.fresh () in
    eval_expr (Env.extend env x (VLabel l)) e cont
  | EShift(v, x, e) ->
    begin match eval_value env v with
    | VLabel l ->
      shift0 l (fun k -> eval_expr (Env.extend env x k) e) cont
    | _ -> failwith "Runtime error!"
    end
  | EReset(v, e1, x, e2) ->
    begin match eval_value env v with
    | VLabel l ->
      reset0 l (eval_expr env e1)
        (fun v -> eval_expr (Env.extend env x v) e2)
        cont
    | _ -> failwith "Runtime error!"
    end
  | ERepl func -> eval_repl env func cont
  | EReplExpr(e1, tp, e2) ->
    Printf.printf ": %s\n" tp;
    eval_expr env e1 (fun v1 ->
      Printf.printf "= %s\n" (to_string v1);
      eval_expr env e2 cont)

and eval_value env (v : Lang.Untyped.value) =
  match v with
  | VUnit  -> VUnit
  | VNum n -> VNum n
  | VStr s -> VStr s
  | VVar x -> Env.lookup env x
  | VFn(x, body) ->
    VFn(fun v -> eval_expr (Env.extend env x v) body)
  | VCtor(n, vs) ->
    VCtor(n, List.map (eval_value env) vs)
  | VExtern name ->
    begin match Hashtbl.find_opt extern_map name with
    | Some v -> v
    | None   ->
      failwith ("Runtime error: undefined external function: " ^ name)
    end

and eval_repl env func cont =
  match func () with
  | e -> eval_expr env e cont
  | exception InterpLib.Error.Fatal_error ->
    InterpLib.Error.reset ();
    (* TODO: backtrack references *)
    eval_repl env func cont

let eval_program p =
  eval_expr Env.empty p (fun _ _ -> ()) []
