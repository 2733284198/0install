(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open General

module Q = Support.Qdom
module U = Support.Utils
module FeedAttr = Constants.FeedAttr
module AttrMap = Support.Qdom.AttrMap

type importance =
  [ `essential       (* Must select a version of the dependency *)
  | `recommended     (* Prefer to select a version, if possible *)
  | `restricts ]     (* Just adds restrictions without expressing any opinion *)

type distro_retrieval_method = {
  distro_size : Int64.t option;
  distro_install_info : (string * string);        (* In some format meaningful to the distribution *)
}

type package_state =
  [ `installed
  | `uninstalled of distro_retrieval_method ]

type package_impl = {
  package_distro : string;
  mutable package_state : package_state;
}

type cache_impl = {
  digests : Manifest.digest list;
  retrieval_methods : Q.element list;
}

type impl_type =
  [ `cache_impl of cache_impl
  | `local_impl of filepath
  | `package_impl of package_impl ]

type restriction = < to_string : string; meets_restriction : impl_type t -> bool >

and binding = Element.binding_node Element.t

and dependency = {
  dep_qdom : Element.dependency_node Element.t;
  dep_importance : importance;
  dep_iface: iface_uri;
  dep_restrictions: restriction list;
  dep_required_commands: string list;
  dep_if_os : string option;                (* The badly-named 'os' attribute *)
  dep_use : string option;                  (* Deprecated 'use' attribute *)
}

and command = {
  mutable command_qdom : Support.Qdom.element;
  command_requires : dependency list;
  command_bindings : binding list;
}

and properties = {
  attrs : AttrMap.t;
  requires : dependency list;
  bindings : binding list;
  commands : command StringMap.t;
}

and +'a t = {
  qdom : Q.element;
  props : properties;
  stability : stability_level;
  os : string option;           (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : string option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Versions.parsed_version;
  impl_type : [< impl_type] as 'a;
}

type generic_implementation = impl_type t
type distro_implementation = [ `package_impl of package_impl ] t

let parse_stability ~from_user s =
  let if_from_user l =
    if from_user then l else raise_safe "Stability '%s' not allowed here" s in
  match s with
  | "insecure" -> Insecure
  | "buggy" -> Buggy
  | "developer" -> Developer
  | "testing" -> Testing
  | "stable" -> Stable
  | "packaged" -> if_from_user Packaged
  | "preferred" -> if_from_user Preferred
  | x -> raise_safe "Unknown stability level '%s'" x

let format_stability = function
  | Insecure -> "insecure"
  | Buggy -> "buggy"
  | Developer -> "developer"
  | Testing -> "testing"
  | Stable -> "stable"
  | Packaged -> "packaged"
  | Preferred -> "preferred"

let make_command ?source_hint name ?(new_attr="path") path : command =
  let attrs = AttrMap.singleton "name" name
    |> AttrMap.add_no_ns new_attr path in
  let elem = ZI.make ?source_hint ~attrs "command" in
  {
    command_qdom = elem;
    command_requires = [];
    command_bindings = [];
  }

let make_distribtion_restriction distros =
  object
    method meets_restriction impl =
      ListLabels.exists (Str.split U.re_space distros) ~f:(fun distro ->
        match distro, impl.impl_type with
        | "0install", `package_impl _ -> false
        | "0install", `cache_impl _ -> true
        | "0install", `local_impl _ -> true
        | distro, `package_impl {package_distro;_} -> package_distro = distro
        | _ -> false
      )

    method to_string = "distribution:" ^ distros
  end

let get_attr_ex name impl =
  AttrMap.get_no_ns name impl.props.attrs |? lazy (Q.raise_elem "Missing '%s' attribute for " name impl.qdom)

let parse_version_element elem =
  let before = Element.before elem in
  let not_before = Element.not_before elem in
  let test = Versions.make_range_restriction not_before before in
  object
    method meets_restriction impl = test impl.parsed_version
    method to_string =
      match not_before, before with
      | None, None -> "no restriction!"
      | Some low, None -> "version " ^ low ^ ".."
      | None, Some high -> "version ..!" ^ high
      | Some low, Some high -> "version " ^ low ^ "..!" ^ high
  end

let make_impossible_restriction msg =
  object
    method meets_restriction _impl = false
    method to_string = Printf.sprintf "<impossible: %s>" msg
  end

let make_version_restriction expr =
  try
    let test = Versions.parse_expr expr in
    object
      method meets_restriction impl = test impl.parsed_version
      method to_string = "version " ^ expr
    end
  with Safe_exception (ex_msg, _) as ex ->
    let msg = Printf.sprintf "Can't parse version restriction '%s': %s" expr ex_msg in
    log_warning ~ex:ex "%s" msg;
    make_impossible_restriction msg

let parse_dep local_dir node =
  let dep = Element.classify_dep node in
  let iface, node =
    let raw_iface = Element.interface node in
    if U.starts_with raw_iface "." then (
      match local_dir with
      | Some dir ->
          let iface = U.normpath @@ dir +/ raw_iface in
          (iface, Element.with_interface iface node)
      | None ->
          raise_safe "Relative interface URI '%s' in non-local feed" raw_iface
    ) else (
      (raw_iface, node)
    ) in

  let commands = ref StringSet.empty in

  let restrictions = Element.restrictions node |> List.map (fun (`version child) -> parse_version_element child) in
  Element.bindings node |> List.iter (fun child ->
    let binding = Binding.parse_binding child in
    match Binding.get_command binding with
    | None -> ()
    | Some name -> commands := StringSet.add name !commands
  );

  let restrictions = match Element.version_opt node with
    | None -> restrictions
    | Some expr -> make_version_restriction expr :: restrictions
  in

  begin match dep with
  | `runner r -> commands := StringSet.add (default "run" @@ Element.command r) !commands
  | `requires _ | `restricts _ -> () end;

  let importance =
    match dep with
    | `restricts _ -> `restricts
    | `requires r | `runner r -> Element.importance r in

  let restrictions =
    match Element.distribution node with
    | Some distros -> make_distribtion_restriction distros :: restrictions
    | None -> restrictions in

  {
    dep_qdom = (node :> Element.dependency_node Element.t);
    dep_iface = iface;
    dep_restrictions = restrictions;
    dep_required_commands = StringSet.elements !commands;
    dep_importance = importance;
    dep_use = Element.use node;
    dep_if_os = Element.os node;
  }

let parse_command local_dir elem : command =
  let deps = ref [] in
  let bindings = ref [] in

  Element.command_children elem |> List.iter (function
    | #Element.dependency as d ->
        deps := parse_dep local_dir (Element.element_of_dependency d) :: !deps
    | #Element.binding as b ->
        bindings := Element.element_of_binding b :: !bindings
    | _ -> ()
  );

  {
    command_qdom = Element.as_xml elem;
    command_requires = !deps;
    command_bindings = !bindings;
  }

let is_source impl = impl.machine = Some "src"

let get_command_opt command_name impl = StringMap.find command_name impl.props.commands

let get_command_ex command_name impl : command =
  StringMap.find command_name impl.props.commands |? lazy (Q.raise_elem "Command '%s' not found in" command_name impl.qdom)

(** The list of languages provided by this implementation. *)
let get_langs impl =
  let langs =
    match AttrMap.get_no_ns "langs" impl.props.attrs with
    | Some langs -> Str.split U.re_space langs
    | None -> ["en"] in
  Support.Utils.filter_map Support.Locale.parse_lang langs

(** Is this implementation in the cache? *)
let is_available_locally config impl =
  match impl.impl_type with
  | `package_impl {package_state;_} -> package_state = `installed
  | `local_impl path -> config.system#file_exists path
  | `cache_impl {digests;_} ->
      match Stores.lookup_maybe config.system digests config.stores with
      | None -> false
      | Some _path -> true

let is_retrievable_without_network cache_impl =
  let ok_without_network elem =
    match Recipe.parse_retrieval_method elem with
    | Some recipe -> not @@ Recipe.recipe_requires_network recipe
    | None -> false in
  List.exists ok_without_network cache_impl.retrieval_methods

let get_id impl =
  let feed_url = get_attr_ex FeedAttr.from_feed impl in
  Feed_url.({feed = Feed_url.parse feed_url; id = get_attr_ex FeedAttr.id impl})