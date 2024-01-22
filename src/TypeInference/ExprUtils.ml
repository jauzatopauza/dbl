(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Utility functions that help to build Unif expressions *)

(* Author: Piotr Polesiuk, 2023,2024 *)

open Common

(** Make function that takes parameters of given type schemes *)
let rec make_fun' schs body_f =
  match schs with
  | [] -> body_f []
  | sch :: schs ->
    let x = Var.fresh () in
    let body = make_fun' schs (fun xs -> body_f (x :: xs)) in
    { T.pos  = body.T.pos;
      T.data = T.EFn(x, sch, body)
    }

(** Make polymorphic function with given type parameters *)
let rec make_tfun tvs body =
  match tvs with
  | [] -> body
  | (_, x) :: tvs ->
    { T.pos  = body.T.pos;
      T.data = T.ETFun(x, make_tfun tvs body)
    }

(** Make function polymorphic in named parameters *)
let rec make_nfun named body =
  match named with
  | [] -> body
  | (_, x, sch) :: named ->
    { T.pos  = body.T.pos;
      T.data = T.EFn(x, sch, make_nfun named body)
    }

(** Same as make_ifun, but creates fresh variables, and pass them to
  body-generating function *)
let make_nfun' named body_f =
  let named = List.map (fun (name, sch) -> (name, Var.fresh (), sch)) named in
  make_nfun named (body_f (List.map (fun (_, x, _) -> x) named))

let rec make_tapp e tps =
  match tps with
  | [] -> e
  | tp :: tps ->
    let e =
      { T.pos  = e.T.pos;
        T.data = T.ETApp(e, tp)
      }
    in
    make_tapp e tps

let generalize env tvs2 named e tp =
  let tvs1 =
    List.fold_left
      (fun tvs (_, _, isch) -> T.Scheme.collect_uvars isch tvs)
      (T.Type.uvars tp)
      named
    |> Fun.flip T.UVar.Set.diff (Env.uvars env)
    |> T.UVar.Set.elements
    |> List.map (fun x -> (T.TNAnon, T.UVar.fix x))
  in
  let tvs = tvs1 @ tvs2 in
  let sch =
    { T.sch_targs = tvs
    ; T.sch_named = List.map (fun (name, _, sch) -> (name, sch)) named
    ; T.sch_body  = tp
    }
  in
  (make_tfun tvs (make_nfun named e), sch)

(* ========================================================================= *)

let guess_type env sub ~tinst (n, tv) =
  let tp =
    match List.assoc_opt n tinst with
    | None    -> Env.fresh_uvar env (T.TVar.kind tv)
    | Some tp -> tp
  in
  (T.Subst.add_type sub tv tp, tp)

let guess_types env ?(tinst=[]) tvars =
  List.fold_left_map (guess_type env ~tinst) T.Subst.empty tvars

(** The main instantiation function. [nset] parameter is a set of names
  currently instantiated, used to avoid infinite loops, e.g., in
  [`n : {`n : _} -> _]. *)
let rec instantiate_loop ~nset env e (sch : T.scheme) =
  let (sub, tps) = guess_types env sch.sch_targs in
  let e = make_tapp e tps in
  let named = List.map (T.NamedScheme.subst sub) sch.sch_named in
  let e = instantiate_named_params_loop ~nset env e named in
  (e, T.Type.subst sub sch.sch_body)

and instantiate_named_params_loop ~nset ?(inst=[]) env e named =
  List.fold_left (instantiate_named_param ~nset ~inst env) e named

and instantiate_named_param ~nset ~inst env (e : T.expr) (name, isch) =
  if T.Name.Set.mem name nset then
    Error.fatal (Error.looping_named_param ~pos:e.pos name)
  else match T.Name.assoc name inst, name with
  | Some arg, _ ->
    { T.pos = e.pos; T.data = T.EApp(e, arg) }
  | None, T.NImplicit iname ->
    let nset = T.Name.Set.add name nset in
    begin match Env.lookup_implicit env iname with
    | Some(x, sch, on_use) ->
      on_use e.pos;
      let (env, tvs, named, tp) = Env.open_scheme env isch in
      let arg = { T.pos = e.pos; T.data = T.EVar x } in
      let (arg, arg_tp) = instantiate_loop ~nset env arg sch in
      let arg = make_tfun tvs (make_nfun named arg) in
      if Unification.subtype env arg_tp tp then
        { T.pos = e.pos; T.data = T.EApp(e, arg) }
      else
        Error.fatal
          (Error.implicit_type_mismatch ~pos:e.pos ~env iname arg_tp tp)
    | None ->
      Error.fatal (Error.unbound_implicit ~pos:e.pos iname)
    end
  | None, T.NVar x ->
    (* TODO: we could provide freshly bound parameters here *)
    Error.fatal (Error.unbound_named_param ~pos:e.pos x)

let instantiate_named_params env e ims inst =
  instantiate_named_params_loop ~nset:T.Name.Set.empty ~inst env e ims

(* ========================================================================= *)

let ctor_func ~pos idx (info : Env.adt_info) =
  let type_of_named_targ (_, x) = T.Type.t_var x in
  let mk_var x = { T.pos = pos; T.data = T.EVar x } in
  let ctor = List.nth info.adt_ctors idx in
  let proof = make_tapp info.adt_proof
    (List.map type_of_named_targ info.adt_args) in
  make_tfun info.adt_args (
  make_tfun ctor.ctor_targs (
  make_nfun' ctor.ctor_named (fun xs1 ->
  make_fun' ctor.ctor_arg_schemes (fun xs2 ->
    let tps = List.map type_of_named_targ ctor.ctor_targs in
    let args = List.map mk_var (xs1 @ xs2) in
    { T.pos  = pos;
      T.data = T.ECtor(proof, idx, tps, args)
    }))))

(* ========================================================================= *)

let arg_match (pat : T.pattern) body tp eff =
  match pat.data with
  | PWildcard ->
    let x = Var.fresh () in
    (x, body)
  | PVar(x, _) ->
    (x, body)
  | PCtor _ ->
    let x = Var.fresh () in
    let make data = { pat with T.data = data } in
    let body = make (T.EMatch(make (T.EVar x), [(pat, body)], tp, eff)) in
    (x, body)

let rec inst_args_match ims body tp eff =
  match ims with
  | [] -> ([], body)
  | (name, pat, x_sch) :: ims ->
    let (x, body)   = arg_match pat body tp eff in
    let (ims, body) = inst_args_match ims body tp eff in
    ((name, x, x_sch) :: ims, body)
