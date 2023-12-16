(* This file is part of DBL, released under MIT license.
 * See LICENSE for details.
 *)

(** Environment of the type inference *)

(* Author: Piotr Polesiuk, 2023 *)

open Common

module StrMap = Map.Make(String)

type t = {
  var_map : (T.var * T.scheme) StrMap.t;
    (** Information about regular variable names *)

  scope   : T.scope
    (** Scope of type variables *)
}

let empty =
  { var_map = StrMap.empty;
    scope   = T.Scope.initial
  }

let add_poly_var env x sch =
  let y = Var.fresh ~name:x () in
  { env with
    var_map = StrMap.add x (y, sch) env.var_map
  }, y

let add_mono_var env x tp =
  add_poly_var env x { sch_tvars = []; sch_body = tp }

let add_anon_tvar env kind =
  let x = T.TVar.fresh kind in
  { env with
    scope = T.Scope.add env.scope x
  }, x

let lookup_var env x =
  StrMap.find_opt x env.var_map

let uvars env =
  T.UVar.Set.empty
  |> StrMap.fold
      (fun _ (_, sch) -> T.Scheme.collect_uvars sch)
      env.var_map

let scope env = env.scope

let fresh_uvar env kind =
  T.Type.fresh_uvar ~scope:env.scope kind