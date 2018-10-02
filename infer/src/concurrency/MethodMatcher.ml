(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging

let call_matches ?(search_superclasses = true) ?(method_prefix = false)
    ?(actuals_pred = fun _ -> true) clazz methods =
  let method_matcher =
    if method_prefix then fun current_method target_method ->
      String.is_prefix current_method ~prefix:target_method
    else fun current_method target_method -> String.equal current_method target_method
  in
  let class_matcher =
    let is_target_class =
      let target = Typ.Name.Java.from_string clazz in
      fun tname -> Typ.Name.equal tname target
    in
    if search_superclasses then fun tenv classname ->
      let is_target_struct tname _ = is_target_class tname in
      PatternMatch.supertype_exists tenv is_target_struct classname
    else fun _ classname -> is_target_class classname
  in
  (fun tenv pn actuals ->
    actuals_pred actuals
    &&
    match pn with
    | Typ.Procname.Java java_pname ->
        let mthd = Typ.Procname.Java.get_method java_pname in
        List.exists methods ~f:(method_matcher mthd)
        &&
        let classname = Typ.Procname.Java.get_class_type_name java_pname in
        class_matcher tenv classname
    | _ ->
        false )
  |> Staged.stage


type t = Tenv.t -> Typ.Procname.t -> HilExp.t list -> bool

type record =
  { search_superclasses: bool option
  ; method_prefix: bool option
  ; actuals_pred: (HilExp.t list -> bool) option
  ; classname: string
  ; methods: string list }

let of_record {search_superclasses; method_prefix; actuals_pred; classname; methods} =
  call_matches ?search_superclasses ?method_prefix ?actuals_pred classname methods
  |> Staged.unstage


let default =
  { search_superclasses= Some true
  ; method_prefix= Some false
  ; actuals_pred= Some (fun _ -> true)
  ; classname= ""
  ; methods= [] }


let of_list matchers tenv pn actuals = List.exists matchers ~f:(fun m -> m tenv pn actuals)

let of_json top_json =
  let error json =
    L.(die UserError "Could not parse json matcher(s): %s" (Yojson.Basic.to_string json))
  in
  let make_matcher_from_json json =
    let parse_method_name = function `String methodname -> methodname | _ -> error json in
    let rec parse_fields assoclist acc =
      match assoclist with
      | ("search_superclasses", `Bool b) :: rest ->
          {acc with search_superclasses= Some b} |> parse_fields rest
      | ("method_prefix", `Bool b) :: rest ->
          {acc with method_prefix= Some b} |> parse_fields rest
      | ("classname", `String classname) :: rest ->
          {acc with classname} |> parse_fields rest
      | ("methods", `List methodnames) :: rest ->
          let methods = List.map methodnames ~f:parse_method_name in
          {acc with methods} |> parse_fields rest
      | [] ->
          if String.equal acc.classname "" || List.is_empty acc.methods then error json else acc
      | _ ->
          error json
    in
    (match json with `Assoc fields -> parse_fields fields default | _ -> error json) |> of_record
  in
  match top_json with
  | `List matchers_json ->
      List.map matchers_json ~f:make_matcher_from_json |> of_list
  | _ ->
      error top_json
