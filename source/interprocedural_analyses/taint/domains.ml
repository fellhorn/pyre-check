(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Domains: implements the taint representation as an abstract domain.
 * This is the data structure used to represent taint during the forward and
 * backward analysis, as well as within models.
 *
 * Most of the data structure uses generic abstract domains such as the map
 * domain, the domain product and the set domain.
 *
 * Here is a high level representation of the taint representation for `ForwardState`:
 * ForwardState: Map[
 *   key: AccessPath.Root = Variable|NamedParameter|...,
 *   value: Tree[
 *     edges: Abstract.TreeDomain.Label.t = Index of string|Field of string|...,
 *     nodes: ForwardTaint: Map[
 *       key: CallInfo = Declaration|Origin of {location; class_intervals}|CallSite of {port; path; callees; class_intervals},
 *       value: LocalTaint: Tuple[
 *         BreadcrumbSet,
 *         FirstIndexSet,
 *         FirstFieldSet,
 *         TitoPositionSet,
 *         ...,
 *         KindTaint: Map[
 *           key: Sources.t,
 *           value: Frame: Tuple[BreadcrumbSet, ViaFeatureSet, TraceLength, LeafNameSet, ...]
 *         ]
 *       ]
 *     ]
 *   ]
 * ]
 *)

open Core
open Ast
open Interprocedural

let location_to_json
    {
      Location.start = { line = start_line; column = start_column };
      stop = { line = end_line; column = end_column };
    }
    : Yojson.Safe.t
  =
  (* If the location spans multiple lines, we only return the position of the first character. *)
  `Assoc
    [
      "line", `Int start_line;
      "start", `Int start_column;
      "end", `Int (if start_line = end_line then end_column else start_column);
    ]


let location_with_module_to_json ~resolve_module_path location_with_module : Yojson.Safe.t =
  let add_path fields =
    match resolve_module_path with
    | Some resolve_module_path -> (
        (* SAPP expects filenames to be relative to the repository root.
         * When the file is outside the repository, uses `*` as the filename
         * and add the full path under the `path` key for debugging purposes. *)
        match resolve_module_path location_with_module.Location.WithModule.module_reference with
        | Some { RepositoryPath.filename = Some filename; _ } ->
            ("filename", `String filename) :: fields
        | Some { RepositoryPath.filename = None; path } ->
            ("filename", `String "*") :: ("path", `String (PyrePath.absolute path)) :: fields
        | None -> ("filename", `String "*") :: fields)
    | None -> fields
  in
  match location_to_json (Location.strip_module location_with_module) with
  | `Assoc fields -> `Assoc (add_path fields)
  | _ -> failwith "unreachable"


(* Class intervals reduce false positives by removing traces in which the taint is propagated along
   a sequence of calls in which exists a subsequence of calls where the receiver objects are
   "incompatible" with each other, in terms of not respecting the subclass relations.
 * The compatibility is checked by using class intervals. That is, each class is associated with a
   numerical interval, such that the interval inclusion relation approximates the subclass relation.
 * For the meaning of "compatibility", see examples in
   `source/interprocedural_analyses/taint/test/integration/class_interval.py`.
 * Class intervals are associated with every call site. *)
module ClassIntervals = struct
  type t = {
    (* The interval of the class that literally contains this call site *)
    caller_interval: ClassIntervalSet.t;
    (* The interval of the receiver object for this call site *)
    receiver_interval: ClassIntervalSet.t;
    (* Whether this call site is a call on `self` *)
    is_self_call: bool;
    (* Whether this call site is a call on `cls` *)
    is_cls_call: bool;
  }
  [@@deriving compare, eq]

  (* If we are not sure if a call is on `self` or `cls`, then we should treat it as a call not on
     `self` or `cls`, such that SAPP will not intersect class intervals. *)
  let top =
    {
      caller_interval = ClassIntervalSet.top;
      receiver_interval = ClassIntervalSet.top;
      is_self_call = false;
      is_cls_call = false;
    }


  let is_top { caller_interval; receiver_interval; is_self_call; is_cls_call } =
    ClassIntervalSet.is_top caller_interval
    && ClassIntervalSet.is_top receiver_interval
    && (not is_self_call)
    && not is_cls_call


  let to_json { caller_interval; receiver_interval; is_self_call; is_cls_call } =
    let list =
      (* We want SAPP to treat calls to `self` and `cls` in the same way *)
      ["is_self_call", `Bool (is_self_call || is_cls_call)]
    in
    let intervals_to_list intervals =
      let intervals = ClassIntervalSet.to_list intervals in
      List.map intervals ~f:(fun interval ->
          `Assoc
            [
              "lower", `Int (ClassInterval.lower_bound_exn interval);
              "upper", `Int (ClassInterval.upper_bound_exn interval);
            ])
    in
    let list =
      if ClassIntervalSet.is_top receiver_interval then
        list
      else (* Output for SAPP to use *)
        ("receiver_interval", `List (intervals_to_list receiver_interval)) :: list
    in
    let list =
      if ClassIntervalSet.is_empty caller_interval || ClassIntervalSet.is_top caller_interval then
        list
      else (* Output for debug purposes *)
        ("caller_interval", `List (intervals_to_list caller_interval)) :: list
    in
    list


  let pp formatter { caller_interval; receiver_interval; is_self_call; is_cls_call } =
    Format.fprintf
      formatter
      "@[[caller_interval: %a receiver_interval: %a is_self_call: %b is_cls_call: %b]@]"
      ClassIntervalSet.pp
      caller_interval
      ClassIntervalSet.pp
      receiver_interval
      is_self_call
      is_cls_call


  let show = Format.asprintf "%a" pp
end

(* Represents the link between frames. *)
module CallInfo = struct
  let name = "call info"

  type t =
    (* User-specified taint on a model. *)
    | Declaration of {
        (* If not provided, the leaf name set is set as the callee when taint is propagated. *)
        leaf_name_provided: bool;
      }
    (* Special key to store taint-in-taint-out info (e.g, Sinks.LocalReturn) *)
    | Tito
    (* Leaf taint at the callsite of a tainted model, i.e the start or end of the trace. *)
    | Origin of {
        location: Location.WithModule.t;
        class_intervals: ClassIntervals.t;
      }
    (* Taint propagated from a call. *)
    | CallSite of {
        port: AccessPath.Root.t;
        path: AccessPath.Path.t;
        location: Location.WithModule.t;
        callees: Target.t list;
        class_intervals: ClassIntervals.t;
      }
  [@@deriving compare, equal]

  let declaration = Declaration { leaf_name_provided = false }

  let origin ?(class_intervals = ClassIntervals.top) location = Origin { location; class_intervals }

  let pp formatter = function
    | Declaration _ -> Format.fprintf formatter "Declaration"
    | Tito -> Format.fprintf formatter "Tito"
    | Origin { location; class_intervals } ->
        Format.fprintf
          formatter
          "Origin(location=%a, class_intervals=%a)"
          Location.WithModule.pp
          location
          ClassIntervals.pp
          class_intervals
    | CallSite { location; callees; port; path; class_intervals } ->
        let port = AccessPath.create port path |> AccessPath.show in
        Format.fprintf
          formatter
          "CallSite(callees=[%s], location=%a, port=%s, class_intervals=%a)"
          (String.concat ~sep:", " (List.map ~f:Target.external_name callees))
          Location.WithModule.pp
          location
          port
          ClassIntervals.pp
          class_intervals


  let show = Format.asprintf "%a" pp

  (* Whether to show a call site as an extra trace *)
  let show_as_extra_trace = function
    | Origin _
    | CallSite _ ->
        true (* These are actual call sites *)
    | Declaration _
    | Tito ->
        false


  (* Only called when emitting models before we compute the json so we can dedup *)
  let expand_overrides ~override_graph ~is_valid_callee trace =
    match trace with
    | CallSite { location; callees; port; path; class_intervals } ->
        let callees =
          OverrideGraph.SharedMemory.ReadOnly.expand_override_targets override_graph callees
          |> List.filter ~f:(fun callee -> is_valid_callee ~port ~path ~callee)
        in
        CallSite { location; callees; port; path; class_intervals }
    | _ -> trace


  (* Returns the (dictionary key * json) to emit *)
  let to_json ~resolve_module_path trace : (string * Yojson.Safe.t) list =
    let class_intervals_to_json call_info_intervals =
      if ClassIntervals.is_top call_info_intervals then
        []
      else
        ClassIntervals.to_json call_info_intervals
    in
    match trace with
    | Declaration _ -> ["declaration", `Null]
    | Tito -> ["tito", `Null]
    | Origin { location; class_intervals } ->
        let location_json = location_with_module_to_json ~resolve_module_path location in
        let class_intervals_json_list = class_intervals_to_json class_intervals in
        ("origin", location_json) :: class_intervals_json_list
    | CallSite { location; callees; port; path; class_intervals } ->
        let callee_json =
          callees |> List.map ~f:(fun callable -> `String (Target.external_name callable))
        in
        let location_json = location_with_module_to_json ~resolve_module_path location in
        let port_json = AccessPath.create port path |> AccessPath.to_json in
        let call_json =
          `Assoc ["position", location_json; "resolves_to", `List callee_json; "port", port_json]
        in
        let class_intervals_json_list = class_intervals_to_json class_intervals in
        ("call", call_json) :: class_intervals_json_list


  let strip_for_callsite = function
    | Origin { class_intervals; _ } ->
        Origin { location = Location.WithModule.any; class_intervals }
    | CallSite { port; path; location = _; callees; class_intervals } ->
        CallSite { port; path; location = Location.WithModule.any; callees; class_intervals }
    | Declaration _ -> Declaration { leaf_name_provided = false }
    | Tito -> Tito


  let replace_location ~location call_info =
    match call_info with
    | Tito
    | Declaration _ ->
        call_info
    | Origin origin -> Origin { origin with location }
    | CallSite callsite -> CallSite { callsite with location }


  let class_intervals = function
    | Origin { class_intervals; _ }
    | CallSite { class_intervals; _ } ->
        class_intervals
    | Declaration _
    | Tito ->
        ClassIntervals.top
end

module TraceLength = struct
  include Features.MakeScalarDomain (struct
    let name = "trace length"
  end)

  let increase n = if n < Int.max_value then n + 1 else n
end

(* This module represents the first hops of the extra traces that are attached to the trace frames
   in Zoncolan UI. *)
module ExtraTraceFirstHop = struct
  module T = struct
    type leaf_kind =
      | Source of Sources.t
      | Sink of Sinks.t
    [@@deriving compare]

    let show_leaf_kind = function
      | Source source -> Sources.show source
      | Sink sink -> Sinks.show sink


    let pp_leaf_kind format kind = Format.fprintf format "%s" (show_leaf_kind kind)

    type t = {
      (* The first frame of an extra trace *)
      call_info: CallInfo.t;
      (* The taint kind related with the first frame *)
      leaf_kind: leaf_kind;
      (* The text to show in the SAPP frames *)
      message: string option;
    }
    [@@deriving compare, show]

    let name = "extra trace"

    let trace_kind = function
      | Source _ -> "source"
      | Sink _ -> "sink"


    let to_json { call_info; leaf_kind; message } =
      let json =
        List.append
          (CallInfo.to_json ~resolve_module_path:None call_info)
          [
            "leaf_kind", `String (show_leaf_kind leaf_kind);
            "trace_kind", `String (trace_kind leaf_kind);
          ]
      in
      let json =
        match message with
        | Some message -> ("message", `String message) :: json
        | None -> json
      in
      `Assoc json
  end

  include T

  module Set = struct
    include Abstract.SetDomain.Make (T)

    let to_json set = elements set |> List.map ~f:(fun e -> T.to_json e)
  end
end

module IssueHandleSet = struct
  include Abstract.SetDomain.Make (IssueHandle)

  let to_json set = elements set |> List.map ~f:(fun e -> `String (IssueHandle.master_handle e))
end

(* Represents a frame, i.e a single hop between functions. *)
module Frame = struct
  module Slots = struct
    let name = "frame"

    type 'a slot =
      | Breadcrumb : Features.BreadcrumbSet.t slot
      | ViaFeature : Features.ViaFeatureSet.t slot
      | ReturnAccessPath : Features.ReturnAccessPathTree.t slot
      | TraceLength : TraceLength.t slot
      | LeafName : Features.LeafNameSet.t slot
      | FirstIndex : Features.FirstIndexSet.t slot
      | FirstField : Features.FirstFieldSet.t slot
        (* A set of issue handles attached to a triggered sink of a multi-source rule, + which
           represent issues with flows to the other partial sink label. *)
      | MultiSourceIssueHandle : IssueHandleSet.t slot

    (* Must be consistent with above variants *)
    let slots = 8

    let slot_name (type a) (slot : a slot) =
      match slot with
      | Breadcrumb -> "Breadcrumb"
      | ViaFeature -> "ViaFeature"
      | ReturnAccessPath -> "ReturnAccessPath"
      | TraceLength -> "TraceLength"
      | LeafName -> "LeafName"
      | FirstIndex -> "FirstIndex"
      | FirstField -> "FirstField"
      | MultiSourceIssueHandle -> "MultiSourceIssueHandle"


    let slot_domain (type a) (slot : a slot) =
      match slot with
      | Breadcrumb -> (module Features.BreadcrumbSet : Abstract.Domain.S with type t = a)
      | ViaFeature -> (module Features.ViaFeatureSet : Abstract.Domain.S with type t = a)
      | ReturnAccessPath ->
          (module Features.ReturnAccessPathTree : Abstract.Domain.S with type t = a)
      | TraceLength -> (module TraceLength : Abstract.Domain.S with type t = a)
      | LeafName -> (module Features.LeafNameSet : Abstract.Domain.S with type t = a)
      | FirstIndex -> (module Features.FirstIndexSet : Abstract.Domain.S with type t = a)
      | FirstField -> (module Features.FirstFieldSet : Abstract.Domain.S with type t = a)
      | MultiSourceIssueHandle -> (module IssueHandleSet : Abstract.Domain.S with type t = a)


    let strict _ = false
  end

  include Abstract.ProductDomain.Make (Slots)

  let initial =
    create
      [Part (Features.BreadcrumbSet.Self, Features.BreadcrumbSet.empty); Part (TraceLength.Self, 0)]


  let add_propagated_breadcrumb breadcrumb =
    transform Features.BreadcrumbSet.Element Add ~f:breadcrumb


  let add_propagated_breadcrumbs breadcrumbs =
    transform Features.BreadcrumbSet.Self Add ~f:breadcrumbs


  let product_pp = pp (* shadow *)

  let pp formatter = Format.fprintf formatter "Frame(%a)" product_pp

  let show = Format.asprintf "%a" pp

  let subtract to_remove ~from =
    (* Do not partially subtract slots, since this is unsound. *)
    if phys_equal to_remove from then
      bottom
    else if is_bottom to_remove then
      from
    else if less_or_equal ~left:from ~right:to_remove then
      bottom
    else
      from
end

module ExportLeafNames = struct
  type t =
    | Always
    | Never
    (* Only export leaf names on leaf frames, which include `Declaration` frames (user-declared
       taint) and `Origin` frames (the first frame of a source or sink trace). *)
    | OnlyOnLeaves

  let should_export ~call_info export_leaf_names =
    match export_leaf_names, call_info with
    | Always, _ -> true
    | Never, _ -> false
    | OnlyOnLeaves, CallInfo.Declaration _ -> true
    | OnlyOnLeaves, CallInfo.Origin _ -> true
    | OnlyOnLeaves, _ -> false
end

module type TAINT_DOMAIN = sig
  include Abstract.Domain.S

  type kind [@@deriving eq]

  val kind : kind Abstract.Domain.part

  val kind_frame : (kind * Frame.t) Abstract.Domain.part

  val call_info : CallInfo.t Abstract.Domain.part

  val add_local_breadcrumb : ?add_on_tito:bool -> Features.BreadcrumbInterned.t -> t -> t

  val add_local_breadcrumbs : ?add_on_tito:bool -> Features.BreadcrumbSet.t -> t -> t

  val add_local_first_index : Abstract.TreeDomain.Label.t -> t -> t

  val add_local_first_field : string -> t -> t

  (* All breadcrumbs from all flows, accumulated with an `add`.
   * The over-under approximation is lost when accumulating. *)
  val accumulated_breadcrumbs : t -> Features.BreadcrumbSet.t

  (* All breadcrumbs from all flows, accumulated with a `join`.
   * The over-under approximation is properly preserved. *)
  val joined_breadcrumbs : t -> Features.BreadcrumbSet.t

  val first_indices : t -> Features.FirstIndexSet.t

  val first_fields : t -> Features.FirstFieldSet.t

  val via_features : t -> Features.ViaFeatureSet.t

  val transform_on_widening_collapse : t -> t

  val prune_maximum_length : TraceLength.t -> t -> t

  type kind_set

  val is_empty_kind_set : kind_set -> bool

  val sanitize_taint_kinds : kind_set -> t -> t

  val apply_sanitize_transforms
    :  taint_configuration:TaintConfiguration.Heap.t ->
    SanitizeTransformSet.t ->
    TaintTransformOperation.InsertLocation.t ->
    t ->
    t

  val apply_transforms
    :  taint_configuration:TaintConfiguration.Heap.t ->
    TaintTransforms.t ->
    TaintTransformOperation.InsertLocation.t ->
    TaintTransforms.Order.t ->
    t ->
    t

  (* Add trace info at call-site *)
  val apply_call
    :  resolution:Analysis.Resolution.t ->
    location:Location.WithModule.t ->
    callee:Target.t option ->
    arguments:Ast.Expression.Call.Argument.t list ->
    port:AccessPath.Root.t ->
    path:AccessPath.Path.t ->
    element:t ->
    is_class_method:bool ->
    is_static_method:bool ->
    call_info_intervals:ClassIntervals.t ->
    t

  (* Return the taint with only essential elements. *)
  val essential : preserve_return_access_paths:bool -> t -> t

  val to_json
    :  expand_overrides:OverrideGraph.SharedMemory.ReadOnly.t option ->
    is_valid_callee:(port:AccessPath.Root.t -> path:AccessPath.Path.t -> callee:Target.t -> bool) ->
    resolve_module_path:(Reference.t -> RepositoryPath.t option) option ->
    export_leaf_names:ExportLeafNames.t ->
    t ->
    Yojson.Safe.t

  (* For every frame, convert the may breadcrumbs into must breadcrumbs. *)
  val may_breadcrumbs_to_must : t -> t

  (* Within every local taint, join every frame with the frame in the same local taint that has the
     specified kind. *)
  val join_every_frame_with : frame_kind:kind -> t -> t

  (* Apply a transform operation for all parts under the given call info.
   * This is an optimization to avoid iterating over the whole taint. *)
  val transform_call_info
    :  CallInfo.t ->
    'a Abstract.Domain.part ->
    ([ `Transform ], 'a, 'f, 'b) Abstract.Domain.operation ->
    f:'f ->
    t ->
    t

  val add_extra_traces : extra_traces:ExtraTraceFirstHop.Set.t -> t -> t

  val transform_on_sink : t -> t

  val transform_on_hoist : t -> t
end

module type KIND_ARG = sig
  include Abstract.SetDomain.ELEMENT

  val equal : t -> t -> bool

  val show : t -> string

  val ignore_kind_at_call : t -> bool

  val apply_call : t -> t

  val discard_subkind : t -> t

  val discard_sanitize_transforms : t -> t

  val apply_sanitize_transforms
    :  taint_configuration:TaintConfiguration.Heap.t ->
    SanitizeTransformSet.t ->
    TaintTransformOperation.InsertLocation.t ->
    t ->
    t option

  val apply_transforms
    :  taint_configuration:TaintConfiguration.Heap.t ->
    TaintTransforms.t ->
    TaintTransformOperation.InsertLocation.t ->
    TaintTransforms.Order.t ->
    t ->
    t option

  val get_named_transforms : t -> TaintTransform.t list

  module Set : sig
    include Stdlib.Set.S with type elt = t

    val pp : Format.formatter -> t -> unit

    val show : t -> string

    val to_sanitize_transform_set_exn : t -> SanitizeTransformSet.t
  end
end

(* Represents a map from a taint kind (`Sources.t` or `Sinks.t`) to a frame. *)
module MakeKindTaint (Kind : KIND_ARG) = struct
  module Key = struct
    include Kind

    let absence_implicitly_maps_to_bottom = false
  end

  include Abstract.MapDomain.Make (Key) (Frame)

  let singleton kind frame = set bottom ~key:kind ~data:frame
end

(* Represents taint originating from a specific call. *)
module MakeLocalTaint (Kind : KIND_ARG) = struct
  module KindTaintDomain = MakeKindTaint (Kind)

  module Slots = struct
    let name = "local taint"

    type 'a slot =
      | Kinds : KindTaintDomain.t slot
      | TitoPosition : Features.TitoPositionSet.t slot
      | Breadcrumb : Features.BreadcrumbSet.t slot
      | FirstIndex : Features.FirstIndexSet.t slot
      | FirstField : Features.FirstFieldSet.t slot
      | ExtraTraceFirstHopSet : ExtraTraceFirstHop.Set.t slot

    (* Must be consistent with above variants *)
    let slots = 6

    let slot_name (type a) (slot : a slot) =
      match slot with
      | Kinds -> "Kinds"
      | TitoPosition -> "TitoPosition"
      | Breadcrumb -> "Breadcrumb"
      | FirstIndex -> "FirstIndex"
      | FirstField -> "FirstField"
      | ExtraTraceFirstHopSet -> "ExtraTraceFirstHopSet"


    let slot_domain (type a) (slot : a slot) =
      match slot with
      | Kinds -> (module KindTaintDomain : Abstract.Domain.S with type t = a)
      | TitoPosition -> (module Features.TitoPositionSet : Abstract.Domain.S with type t = a)
      | Breadcrumb -> (module Features.BreadcrumbSet : Abstract.Domain.S with type t = a)
      | FirstIndex -> (module Features.FirstIndexSet : Abstract.Domain.S with type t = a)
      | FirstField -> (module Features.FirstFieldSet : Abstract.Domain.S with type t = a)
      | ExtraTraceFirstHopSet -> (module ExtraTraceFirstHop.Set : Abstract.Domain.S with type t = a)


    let strict (type a) (slot : a slot) =
      match slot with
      | Kinds -> true
      | _ -> false
  end

  include Abstract.ProductDomain.Make (Slots)

  (* Warning: do NOT use `BreadcrumbSet`, `FirstFieldSet` and `FirstFieldSet` abstract parts
   * (e.g,`BreadcrumbSet.Self`, `BreadcrumbSet.Element`, etc.) since these are ambiguous.
   * They can refer to the sets in `Frame` or in `LocalTaint`. *)

  let singleton kind frame =
    (* Initialize strict slots first *)
    create [Abstract.Domain.Part (KindTaintDomain.KeyValue, (kind, frame))]
    |> update Slots.Breadcrumb Features.BreadcrumbSet.empty


  let product_pp = pp (* shadow *)

  let pp formatter = Format.fprintf formatter "LocalTaint(%a)" product_pp

  let show = Format.asprintf "%a" pp

  let subtract to_remove ~from =
    (* Do not partially subtract slots, since this is unsound. *)
    if phys_equal to_remove from then
      bottom
    else if is_bottom to_remove then
      from
    else if less_or_equal ~left:from ~right:to_remove then
      bottom
    else
      from
end

module MakeTaint (Kind : KIND_ARG) : sig
  include TAINT_DOMAIN with type kind = Kind.t and type kind_set = Kind.Set.t

  val kinds : t -> kind list

  val singleton : CallInfo.t -> Kind.t -> Frame.t -> t
end = struct
  type kind = Kind.t [@@deriving compare, eq]

  module CallInfoKey = struct
    include CallInfo

    let absence_implicitly_maps_to_bottom = true
  end

  module LocalTaintDomain = MakeLocalTaint (Kind)
  module KindTaintDomain = LocalTaintDomain.KindTaintDomain
  module Map = Abstract.MapDomain.Make (CallInfoKey) (LocalTaintDomain)
  include Map

  let singleton call_info kind frame =
    let local_taint = LocalTaintDomain.singleton kind frame in
    Map.set Map.bottom ~key:call_info ~data:local_taint


  let kind = KindTaintDomain.Key

  let kind_frame = KindTaintDomain.KeyValue

  let call_info = Map.Key

  let kinds map =
    Map.fold kind ~init:[] ~f:List.cons map |> List.dedup_and_sort ~compare:Kind.compare


  let to_json ~expand_overrides ~is_valid_callee ~resolve_module_path ~export_leaf_names taint =
    let cons_if_non_empty key list assoc =
      if List.is_empty list then
        assoc
      else
        (key, `List list) :: assoc
    in
    let open Features in
    let breadcrumbs_to_json ~breadcrumbs ~first_indices ~first_fields =
      let breadcrumb_to_json { Abstract.OverUnderSetDomain.element; in_under } breadcrumbs =
        let element = BreadcrumbInterned.unintern element in
        let json = Breadcrumb.to_json element ~on_all_paths:in_under in
        json :: breadcrumbs
      in
      let breadcrumbs =
        BreadcrumbSet.fold BreadcrumbSet.ElementAndUnder ~f:breadcrumb_to_json ~init:[] breadcrumbs
      in
      let first_index_breadcrumbs =
        first_indices
        |> FirstIndexSet.elements
        |> List.map ~f:FirstIndexInterned.unintern
        |> FirstIndex.to_json
      in
      let first_field_breadcrumbs =
        first_fields
        |> FirstFieldSet.elements
        |> List.map ~f:FirstFieldInterned.unintern
        |> FirstField.to_json
      in
      List.concat [first_index_breadcrumbs; first_field_breadcrumbs; breadcrumbs]
    in

    let trace_to_json (trace_info, local_taint) =
      let json = CallInfo.to_json ~resolve_module_path trace_info in

      let tito_positions =
        LocalTaintDomain.get LocalTaintDomain.Slots.TitoPosition local_taint
        |> TitoPositionSet.elements
        |> List.map ~f:location_to_json
      in
      let json = cons_if_non_empty "tito_positions" tito_positions json in

      let local_breadcrumbs =
        breadcrumbs_to_json
          ~breadcrumbs:(LocalTaintDomain.get LocalTaintDomain.Slots.Breadcrumb local_taint)
          ~first_indices:(LocalTaintDomain.get LocalTaintDomain.Slots.FirstIndex local_taint)
          ~first_fields:(LocalTaintDomain.get LocalTaintDomain.Slots.FirstField local_taint)
      in
      let json = cons_if_non_empty "local_features" local_breadcrumbs json in

      let add_kind (kind, frame) =
        let json = ["kind", `String (Kind.show kind)] in

        let trace_length = Frame.get Frame.Slots.TraceLength frame in
        let json =
          if trace_length = 0 then
            json
          else
            ("length", `Int trace_length) :: json
        in

        let json =
          if ExportLeafNames.should_export ~call_info:trace_info export_leaf_names then
            let leaves =
              Frame.get Frame.Slots.LeafName frame
              |> LeafNameSet.elements
              |> List.map ~f:LeafNameInterned.unintern
              |> List.map ~f:LeafName.to_json
            in
            cons_if_non_empty "leaves" leaves json
          else
            json
        in

        let return_paths =
          Frame.get Frame.Slots.ReturnAccessPath frame |> ReturnAccessPathTree.to_json
        in
        let json =
          match return_paths with
          | [] -> json
          | _ -> ("return_paths", `Assoc return_paths) :: json
        in

        let via_features =
          Frame.get Frame.Slots.ViaFeature frame
          |> ViaFeatureSet.elements
          |> List.map ~f:ViaFeature.to_json
        in
        let json = cons_if_non_empty "via_features" via_features json in

        let breadcrumbs =
          breadcrumbs_to_json
            ~breadcrumbs:(Frame.get Frame.Slots.Breadcrumb frame)
            ~first_indices:(Frame.get Frame.Slots.FirstIndex frame)
            ~first_fields:(Frame.get Frame.Slots.FirstField frame)
        in
        let json = cons_if_non_empty "features" breadcrumbs json in

        let multi_source_issue_handles =
          Frame.get Frame.Slots.MultiSourceIssueHandle frame |> IssueHandleSet.to_json
        in
        let json = cons_if_non_empty "multi_source_issue_handles" multi_source_issue_handles json in

        `Assoc json
      in
      let kinds =
        LocalTaintDomain.get LocalTaintDomain.Slots.Kinds local_taint
        |> KindTaintDomain.to_alist
        |> List.map ~f:add_kind
      in
      let json = cons_if_non_empty "kinds" kinds json in
      let extra_traces =
        LocalTaintDomain.get LocalTaintDomain.Slots.ExtraTraceFirstHopSet local_taint
        |> ExtraTraceFirstHop.Set.to_json
      in
      let json = cons_if_non_empty "extra_traces" extra_traces json in
      `Assoc json
    in
    let taint =
      match expand_overrides with
      | Some override_graph ->
          Map.transform
            Key
            Map
            ~f:(CallInfo.expand_overrides ~override_graph ~is_valid_callee)
            taint
      | None -> taint
    in
    let elements = Map.to_alist taint |> List.map ~f:trace_to_json in
    `List elements


  let add_local_breadcrumbs ?(add_on_tito = true) breadcrumbs taint =
    let apply_local_taint local_taint =
      let breadcrumbs =
        LocalTaintDomain.get LocalTaintDomain.Slots.Breadcrumb local_taint
        |> Features.BreadcrumbSet.add_set ~to_add:breadcrumbs
      in
      LocalTaintDomain.update LocalTaintDomain.Slots.Breadcrumb breadcrumbs local_taint
    in
    let apply (call_info, local_taint) =
      match call_info, add_on_tito with
      | CallInfo.Tito, false -> call_info, local_taint
      | _ -> call_info, apply_local_taint local_taint
    in
    Map.transform KeyValue Map ~f:apply taint


  let add_local_breadcrumb ?add_on_tito breadcrumb taint =
    add_local_breadcrumbs ?add_on_tito (Features.BreadcrumbSet.singleton breadcrumb) taint


  let add_local_first_index index taint =
    let apply_local_taint local_taint =
      let first_indices =
        LocalTaintDomain.get LocalTaintDomain.Slots.FirstIndex local_taint
        |> Features.FirstIndexSet.add_first index
      in
      LocalTaintDomain.update LocalTaintDomain.Slots.FirstIndex first_indices local_taint
    in
    transform LocalTaintDomain.Self Map ~f:apply_local_taint taint


  let add_local_first_field attribute taint =
    let apply_local_taint local_taint =
      let first_fields =
        LocalTaintDomain.get LocalTaintDomain.Slots.FirstField local_taint
        |> Features.FirstFieldSet.add_first attribute
      in
      LocalTaintDomain.update LocalTaintDomain.Slots.FirstField first_fields local_taint
    in
    transform LocalTaintDomain.Self Map ~f:apply_local_taint taint


  let get_features ~frame_slot ~local_slot ~bottom ~join ~sequence_join taint =
    let local_taint_features local_taint sofar =
      let frame_features frame sofar = Frame.get frame_slot frame |> join sofar in
      let features = LocalTaintDomain.fold Frame.Self local_taint ~init:bottom ~f:frame_features in
      let features = LocalTaintDomain.get local_slot local_taint |> sequence_join features in
      join sofar features
    in
    fold LocalTaintDomain.Self ~f:local_taint_features ~init:bottom taint


  let accumulated_breadcrumbs taint =
    get_features
      ~frame_slot:Frame.Slots.Breadcrumb
      ~local_slot:LocalTaintDomain.Slots.Breadcrumb
      ~bottom:Features.BreadcrumbSet.bottom
      ~join:Features.BreadcrumbSet.sequence_join
      ~sequence_join:Features.BreadcrumbSet.sequence_join
      taint


  let joined_breadcrumbs taint =
    get_features
      ~frame_slot:Frame.Slots.Breadcrumb
      ~local_slot:LocalTaintDomain.Slots.Breadcrumb
      ~bottom:Features.BreadcrumbSet.bottom
      ~join:Features.BreadcrumbSet.join
      ~sequence_join:Features.BreadcrumbSet.sequence_join
      taint


  let get_first ~frame_slot ~local_slot ~bottom ~join ~sequence_join taint =
    let local_taint_first local_taint sofar =
      let local_first = LocalTaintDomain.get local_slot local_taint in
      let frame_first frame sofar =
        Frame.get frame_slot frame |> sequence_join local_first |> join sofar
      in
      LocalTaintDomain.fold Frame.Self local_taint ~init:sofar ~f:frame_first
    in
    fold LocalTaintDomain.Self ~f:local_taint_first ~init:bottom taint


  let first_indices taint =
    get_first
      ~frame_slot:Frame.Slots.FirstIndex
      ~local_slot:LocalTaintDomain.Slots.FirstIndex
      ~bottom:Features.FirstIndexSet.bottom
      ~join:Features.FirstIndexSet.join
      ~sequence_join:Features.FirstIndexSet.sequence_join
      taint


  let first_fields taint =
    get_first
      ~frame_slot:Frame.Slots.FirstField
      ~local_slot:LocalTaintDomain.Slots.FirstField
      ~bottom:Features.FirstFieldSet.bottom
      ~join:Features.FirstFieldSet.join
      ~sequence_join:Features.FirstFieldSet.sequence_join
      taint


  let via_features taint =
    fold
      Features.ViaFeatureSet.Self
      ~f:Features.ViaFeatureSet.join
      ~init:Features.ViaFeatureSet.bottom
      taint


  let transform_call_info
      : type a b f.
        CallInfo.t ->
        a Abstract.Domain.part ->
        ([ `Transform ], a, f, b) Abstract.Domain.operation ->
        f:f ->
        t ->
        t
    =
   fun call_info part op ~f taint ->
    Map.update taint call_info ~f:(function
        | None -> LocalTaintDomain.bottom
        | Some local_taint -> LocalTaintDomain.transform part op ~f local_taint)


  let transform_on_widening_collapse taint =
    let broadening =
      Features.BreadcrumbSet.of_approximation
        [
          (* using an always-feature here would break the widening invariant: a <= a widen b *)
          { element = Features.broadening (); in_under = false };
          { element = Features.widen_broadening (); in_under = false };
        ]
    in
    taint
    |> add_local_breadcrumbs broadening
    |> transform_call_info
         CallInfo.Tito
         Features.CollapseDepth.Self
         Map
         ~f:Features.CollapseDepth.approximate


  let prune_maximum_length maximum_length =
    let filter_flow (_, frame) =
      let length = Frame.get Frame.Slots.TraceLength frame in
      TraceLength.is_bottom length || TraceLength.less_or_equal ~left:maximum_length ~right:length
    in
    transform KindTaintDomain.KeyValue Filter ~f:filter_flow


  type kind_set = Kind.Set.t

  let is_empty_kind_set = Kind.Set.is_empty

  let sanitize_taint_kinds sanitized_kinds taint =
    if Kind.Set.is_empty sanitized_kinds then
      taint
    else
      transform
        KindTaintDomain.Key
        Filter
        ~f:(fun kind ->
          let kind = kind |> Kind.discard_sanitize_transforms |> Kind.discard_subkind in
          not (Kind.Set.mem kind sanitized_kinds))
        taint


  let apply_sanitize_transforms
      ~taint_configuration
      ({ SanitizeTransformSet.sources; sinks } as transforms)
      insert_location
      taint
    =
    if SanitizeTransformSet.is_empty transforms then
      taint
    else if SanitizeTransform.SourceSet.is_all sources || SanitizeTransform.SinkSet.is_all sinks
    then
      bottom
    else
      transform
        KindTaintDomain.Key
        FilterMap
        ~f:(Kind.apply_sanitize_transforms ~taint_configuration transforms insert_location)
        taint


  let apply_transforms ~taint_configuration transforms insert_location order taint =
    if TaintTransforms.is_empty transforms then
      taint
    else
      transform
        KindTaintDomain.Key
        FilterMap
        ~f:(Kind.apply_transforms ~taint_configuration transforms insert_location order)
        taint


  let apply_class_interval
      ~callee_class_interval
      ~is_static_method
      ~is_class_method
      ~call_info_intervals:
        ({ ClassIntervals.is_self_call; is_cls_call; caller_interval; receiver_interval } as
        call_info_intervals)
      local_taint
    =
    let intersect left right =
      let new_interval = ClassIntervalSet.meet left right in
      let should_propagate =
        (* Propagate if the intersection is not empty, and there exists a descendant relation
           between left and right. The latter is useful under multi-inheritance. For example, see
           function `multi_inheritance_no_issue_one_hop` under
           `source/interprocedural_analyses/taint/test/integration/class_interval.py`. *)
        (not (ClassIntervalSet.is_empty new_interval))
        && (ClassIntervalSet.equal left new_interval || ClassIntervalSet.equal right new_interval)
      in
      new_interval, should_propagate
    in
    if is_static_method then
      (* Case A: Call static methods. The taint is unconditionally propagated from the call, which
         is the same treatment as a function call. *)
      call_info_intervals, local_taint
    else (* Case B: Call non-static methods. *)
      let new_interval, should_propagate =
        (* Decide if the taint can be propagated from the call. *)
        intersect callee_class_interval receiver_interval
      in
      if not should_propagate then
        ClassIntervals.top, LocalTaintDomain.bottom
      else if is_self_call || (is_cls_call && is_class_method) then
        (* Case B.1: Call instance methods via `self`, or class methods via `cls`. *)
        let new_interval, should_propagate =
          (* Then impose the caller's interval, because the call chain so far is still on the same
             object (i.e., `self` or `cls`). *)
          intersect new_interval caller_interval
        in
        if not should_propagate then
          ClassIntervals.top, LocalTaintDomain.bottom
        else
          { call_info_intervals with caller_interval = new_interval }, local_taint
      else
        (* Case B.2: Call instance methods on any other objects. *)
        (* Reset the interval to be the caller's interval. *)
        call_info_intervals, local_taint


  let apply_call
      ~resolution
      ~location
      ~callee
      ~arguments
      ~port
      ~path
      ~element:taint
      ~is_class_method
      ~is_static_method
      ~call_info_intervals
    =
    let callees =
      match callee with
      | Some callee -> [callee]
      | None -> []
    in
    let apply (call_info, local_taint) =
      let local_taint =
        local_taint
        |> LocalTaintDomain.transform KindTaintDomain.Key Filter ~f:(fun kind ->
               not (Kind.ignore_kind_at_call kind))
        |> LocalTaintDomain.transform KindTaintDomain.Key Map ~f:Kind.apply_call
      in
      let via_features_breadcrumbs =
        LocalTaintDomain.fold
          Features.ViaFeatureSet.Element
          ~f:Features.ViaFeatureSet.add
          ~init:Features.ViaFeatureSet.bottom
          local_taint
        |> Features.expand_via_features ~resolution ~callees ~arguments
      in
      let local_breadcrumbs = LocalTaintDomain.get LocalTaintDomain.Slots.Breadcrumb local_taint in
      let local_first_indices =
        LocalTaintDomain.get LocalTaintDomain.Slots.FirstIndex local_taint
      in
      let local_first_fields = LocalTaintDomain.get LocalTaintDomain.Slots.FirstField local_taint in
      let local_taint =
        local_taint
        |> LocalTaintDomain.update
             LocalTaintDomain.Slots.TitoPosition
             Features.TitoPositionSet.bottom
        |> LocalTaintDomain.update LocalTaintDomain.Slots.Breadcrumb via_features_breadcrumbs
        |> LocalTaintDomain.update LocalTaintDomain.Slots.FirstIndex Features.FirstIndexSet.bottom
        |> LocalTaintDomain.update LocalTaintDomain.Slots.FirstField Features.FirstFieldSet.bottom
      in
      let local_taint =
        match call_info with
        | CallInfo.Declaration _ ->
            (* Even if we allow extra traces on user models in the future, we would still want to
               propagate them to the first frame. This is because the Declaration frame is never
               shown in the Zoncolan UI. The first frame is the Origin one. *)
            local_taint
        | _ ->
            LocalTaintDomain.update
              LocalTaintDomain.Slots.ExtraTraceFirstHopSet
              ExtraTraceFirstHop.Set.bottom
              local_taint
      in
      let apply_frame frame =
        frame
        |> Frame.update Frame.Slots.ViaFeature Features.ViaFeatureSet.bottom
        |> Frame.transform
             Features.BreadcrumbSet.Self
             Map
             ~f:(Features.BreadcrumbSet.sequence_join local_breadcrumbs)
        |> Frame.transform
             Features.FirstIndexSet.Self
             Map
             ~f:(Features.FirstIndexSet.sequence_join local_first_indices)
        |> Frame.transform
             Features.FirstFieldSet.Self
             Map
             ~f:(Features.FirstFieldSet.sequence_join local_first_fields)
      in
      let local_taint = LocalTaintDomain.transform Frame.Self Map ~f:apply_frame local_taint in
      let class_intervals, local_taint =
        match callee with
        | None
        | Some (Target.Object _)
        | Some (Target.Function _) ->
            call_info_intervals, local_taint
        | Some (Target.Method _)
        | Some (Target.Override _) ->
            let class_intervals = CallInfo.class_intervals call_info in
            apply_class_interval
              ~callee_class_interval:class_intervals.ClassIntervals.caller_interval
              ~is_static_method
              ~is_class_method
              ~call_info_intervals
              local_taint
      in
      match call_info with
      | CallInfo.Origin _
      | CallInfo.CallSite _ ->
          let call_info = CallInfo.CallSite { location; callees; port; path; class_intervals } in
          let local_taint =
            local_taint |> LocalTaintDomain.transform TraceLength.Self Map ~f:TraceLength.increase
          in
          call_info, local_taint
      | CallInfo.Declaration { leaf_name_provided } ->
          let call_info = CallInfo.Origin { location; class_intervals } in
          let new_leaf_names =
            if leaf_name_provided then
              Features.LeafNameSet.bottom
            else
              let open Features in
              let make_leaf_name callee =
                let port =
                  let root =
                    match port with
                    | AccessPath.Root.LocalResult -> "return"
                    | AccessPath.Root.PositionalParameter { name; _ }
                    | AccessPath.Root.NamedParameter { name } ->
                        name
                    | AccessPath.Root.StarParameter _ -> "*"
                    | AccessPath.Root.StarStarParameter _ -> "**"
                    | AccessPath.Root.Variable _
                    | AccessPath.Root.CapturedVariable _ ->
                        failwith "unexpected port in apply_call"
                  in
                  LeafPort.Leaf { root; path }
                in
                LeafName.{ leaf = Target.external_name callee; port } |> LeafNameInterned.intern
              in
              List.map ~f:make_leaf_name callees |> Features.LeafNameSet.of_list
          in
          let local_taint =
            LocalTaintDomain.transform Features.LeafNameSet.Self Add ~f:new_leaf_names local_taint
          in
          call_info, local_taint
      | CallInfo.Tito -> failwith "cannot apply call on tito taint"
    in
    Map.transform Map.KeyValue Map ~f:apply taint


  let may_breadcrumbs_to_must taint =
    let apply_frame frame =
      Frame.transform Features.BreadcrumbSet.Self Map ~f:Features.BreadcrumbSet.over_to_under frame
    in
    Map.transform Frame.Self Map ~f:apply_frame taint


  let join_every_frame_with ~frame_kind taint =
    let apply_local_taint local_taint =
      let frame_to_join =
        let kinds = LocalTaintDomain.get LocalTaintDomain.Slots.Kinds local_taint in
        KindTaintDomain.get frame_kind kinds
      in
      if not (Frame.is_bottom frame_to_join) then
        LocalTaintDomain.transform Frame.Self Map ~f:(Frame.join frame_to_join) local_taint
      else
        local_taint
    in
    Map.transform LocalTaintDomain.Self Map ~f:apply_local_taint taint


  let essential ~preserve_return_access_paths taint =
    if not preserve_return_access_paths then
      let add kind sofar = singleton CallInfo.declaration kind Frame.initial |> join sofar in
      Map.fold kind ~f:add ~init:bottom taint
    else
      let add kind return_access_paths sofar =
        Frame.initial
        |> Frame.update Frame.Slots.ReturnAccessPath return_access_paths
        |> singleton CallInfo.declaration kind
        |> join sofar
      in
      Map.reduce
        Features.ReturnAccessPathTree.Self
        ~using:(Context (kind, Acc))
        ~f:add
        ~init:bottom
        taint


  let add_extra_traces ~extra_traces taint =
    let add_extra_traces existing_extra_traces =
      ExtraTraceFirstHop.Set.join existing_extra_traces extra_traces
    in
    let apply (call_info, local_taint) =
      match call_info with
      | CallInfo.Tito -> (* Tito taint needs no extra traces *) call_info, local_taint
      | _ ->
          let local_taint =
            LocalTaintDomain.transform
              ExtraTraceFirstHop.Set.Self
              Map
              ~f:add_extra_traces
              local_taint
          in
          call_info, local_taint
    in
    Map.transform Map.KeyValue Map ~f:apply taint


  let transform_on_sink = Fn.id

  let transform_on_hoist = Fn.id
end

module ForwardTaint = MakeTaint (struct
  include Sources
  include TaintTransformOperation.Source
end)

module BackwardTaint = MakeTaint (struct
  include Sinks
  include TaintTransformOperation.Sink
end)

module MakeTaintTree (Taint : TAINT_DOMAIN) () = struct
  module T =
    Abstract.TreeDomain.Make
      (struct
        let max_tree_depth_after_widening =
          let cache_first_call =
            lazy
              (TaintConfiguration.SharedMemory.get_global ()
              |> Option.value ~default:TaintConfiguration.Heap.default
              |> TaintConfiguration.maximum_tree_depth_after_widening)
          in
          fun () -> Lazy.force cache_first_call


        let check_invariants = TaintConfiguration.runtime_check_invariants ()
      end)
      (Taint)
      ()

  include T

  let apply_call
      ~resolution
      ~location
      ~callee
      ~arguments
      ~port
      ~is_class_method
      ~is_static_method
      ~call_info_intervals
      taint_tree
    =
    let transform_path (path, tip) =
      ( path,
        Taint.apply_call
          ~resolution
          ~location
          ~callee
          ~arguments
          ~port
          ~path
          ~element:tip
          ~is_class_method
          ~is_static_method
          ~call_info_intervals )
    in
    transform Path Map ~f:transform_path taint_tree


  let may_breadcrumbs_to_must tree = transform Taint.Self Map ~f:Taint.may_breadcrumbs_to_must tree

  let empty = bottom

  let is_empty = is_bottom

  let essential ~preserve_return_access_paths tree =
    transform Taint.Self Map ~f:(Taint.essential ~preserve_return_access_paths) tree


  let shape ~mold_with_return_access_paths ~breadcrumbs tree =
    let transform taint =
      taint
      |> Taint.add_local_breadcrumbs breadcrumbs
      |> Taint.transform_call_info
           CallInfo.Tito
           Features.CollapseDepth.Self
           Map
           ~f:Features.CollapseDepth.approximate
    in
    let shape_partitioned_tree tree =
      T.shape
        ~transform
        tree
        ~mold:(essential ~preserve_return_access_paths:mold_with_return_access_paths tree)
    in
    T.partition Taint.kind By ~f:Fn.id tree
    |> Core.Map.Poly.map ~f:shape_partitioned_tree
    |> Core.Map.Poly.fold ~init:T.bottom ~f:(fun ~key:_ ~data:left right -> T.join left right)


  let prune_maximum_length maximum_length =
    transform Taint.Self Map ~f:(Taint.prune_maximum_length maximum_length)


  let filter_by_kind ~kind taint_tree =
    taint_tree
    |> transform Taint.kind Filter ~f:(Taint.equal_kind kind)
    |> collapse ~transform:Fn.id


  let add_local_breadcrumb ?add_on_tito breadcrumb =
    transform Taint.Self Map ~f:(Taint.add_local_breadcrumb ?add_on_tito breadcrumb)


  let add_local_breadcrumbs ?(add_on_tito = true) breadcrumbs taint_tree =
    if Features.BreadcrumbSet.is_bottom breadcrumbs || Features.BreadcrumbSet.is_empty breadcrumbs
    then
      taint_tree
    else
      transform Taint.Self Map ~f:(Taint.add_local_breadcrumbs ~add_on_tito breadcrumbs) taint_tree


  let add_local_type_breadcrumbs ~resolution ~expression taint =
    let open Ast in
    match expression.Node.value with
    | Expression.Expression.Name (Expression.Name.Identifier _) ->
        (* Add scalar breadcrumbs only for variables, for performance reasons *)
        let type_breadcrumbs =
          let type_ =
            Interprocedural.CallResolution.resolve_ignoring_untracked ~resolution expression
          in
          Features.type_breadcrumbs_from_annotation
            ~resolution:(Analysis.Resolution.global_resolution resolution)
            (Some type_)
        in
        add_local_breadcrumbs type_breadcrumbs taint
    | _ -> taint


  let add_local_first_index index = transform Taint.Self Map ~f:(Taint.add_local_first_index index)

  let add_local_first_field attribute =
    transform Taint.Self Map ~f:(Taint.add_local_first_field attribute)


  let accumulated_breadcrumbs taint_tree =
    let gather_breadcrumbs taint sofar =
      Taint.accumulated_breadcrumbs taint |> Features.BreadcrumbSet.add_set ~to_add:sofar
    in
    fold Taint.Self ~f:gather_breadcrumbs ~init:Features.BreadcrumbSet.bottom taint_tree


  let joined_breadcrumbs taint_tree =
    let gather_breadcrumbs taint sofar =
      Taint.accumulated_breadcrumbs taint |> Features.BreadcrumbSet.join sofar
    in
    fold Taint.Self ~f:gather_breadcrumbs ~init:Features.BreadcrumbSet.bottom taint_tree


  let add_via_features via_features taint_tree =
    if Features.ViaFeatureSet.is_bottom via_features then
      taint_tree
    else
      transform Features.ViaFeatureSet.Self Add ~f:via_features taint_tree


  let sanitize_taint_kinds sanitized_kinds taint =
    if Taint.is_empty_kind_set sanitized_kinds then
      taint
    else
      transform Taint.Self Map ~f:(Taint.sanitize_taint_kinds sanitized_kinds) taint


  let apply_sanitize_transforms
      ~taint_configuration
      ({ SanitizeTransformSet.sources; sinks } as transforms)
      insert_location
      taint
    =
    if SanitizeTransformSet.is_empty transforms then
      taint
    else if SanitizeTransform.SourceSet.is_all sources || SanitizeTransform.SinkSet.is_all sinks
    then
      bottom
    else
      transform
        Taint.Self
        Map
        ~f:(Taint.apply_sanitize_transforms ~taint_configuration transforms insert_location)
        taint


  let apply_transforms ~taint_configuration transforms order insert_location taint =
    if TaintTransforms.is_empty transforms then
      taint
    else
      transform
        Taint.Self
        Map
        ~f:(Taint.apply_transforms ~taint_configuration transforms order insert_location)
        taint


  let collapse ~breadcrumbs taint =
    let transform taint =
      taint
      |> Taint.add_local_breadcrumbs breadcrumbs
      |> Taint.transform_call_info
           CallInfo.Tito
           Features.CollapseDepth.Self
           Map
           ~f:Features.CollapseDepth.approximate
    in
    T.collapse ~transform taint


  let collapse_to ~breadcrumbs ~depth taint =
    let transform taint =
      taint
      |> Taint.add_local_breadcrumbs breadcrumbs
      |> Taint.transform_call_info
           CallInfo.Tito
           Features.CollapseDepth.Self
           Map
           ~f:Features.CollapseDepth.approximate
    in
    T.collapse_to ~transform ~depth taint


  let limit_to ~breadcrumbs ~width taint =
    let transform taint =
      taint
      |> Taint.add_local_breadcrumbs breadcrumbs
      |> Taint.transform_call_info
           CallInfo.Tito
           Features.CollapseDepth.Self
           Map
           ~f:Features.CollapseDepth.approximate
    in
    T.limit_to ~transform ~width taint


  let transform_call_info
      : type a b f.
        CallInfo.t ->
        a Abstract.Domain.part ->
        ([ `Transform ], a, f, b) Abstract.Domain.operation ->
        f:f ->
        t ->
        t
    =
   fun call_info part op ~f taint ->
    transform Taint.Self Map ~f:(Taint.transform_call_info call_info part op ~f) taint
end

module MakeTaintEnvironment (Taint : TAINT_DOMAIN) () = struct
  module Tree = MakeTaintTree (Taint) ()

  include
    Abstract.MapDomain.Make
      (struct
        let name = "env"

        include AccessPath.Root

        let absence_implicitly_maps_to_bottom = true
      end)
      (Tree)

  let to_json ~expand_overrides ~is_valid_callee ~resolve_module_path ~export_leaf_names environment
    =
    let element_to_json json_list (root, tree) =
      let path_to_json (path, tip) json_list =
        let port = AccessPath.create root path |> AccessPath.to_json in
        ( path,
          [
            "port", port;
            ( "taint",
              Taint.to_json
                ~expand_overrides
                ~is_valid_callee
                ~resolve_module_path
                ~export_leaf_names
                tip );
          ] )
        :: json_list
      in
      let ports =
        Tree.fold Tree.Path ~f:path_to_json tree ~init:[]
        |> List.dedup_and_sort ~compare:(fun (p1, _) (p2, _) -> AccessPath.Path.compare p1 p2)
        |> List.rev_map ~f:(fun (_, fields) -> `Assoc fields)
      in
      List.rev_append ports json_list
    in
    let paths = to_alist environment |> List.fold ~f:element_to_json ~init:[] in
    `List paths


  let assign ?(weak = false) ~root ~path subtree environment =
    let assign_tree = function
      | None -> Tree.assign ~weak ~tree:Tree.bottom path ~subtree
      | Some tree -> Tree.assign ~weak ~tree path ~subtree
    in
    update environment root ~f:assign_tree


  let read_tree_raw
      ?(transform_non_leaves = fun _ e -> e)
      ?(use_precise_labels = false)
      ~root
      ~path
      environment
    =
    match get_opt root environment with
    | None -> Taint.bottom, Tree.bottom
    | Some tree -> Tree.read_raw ~transform_non_leaves ~use_precise_labels path tree


  let read ?(transform_non_leaves = fun _ e -> e) ~root ~path environment =
    match get_opt root environment with
    | None -> Tree.bottom
    | Some tree -> Tree.read ~transform_non_leaves path tree


  let empty = bottom

  let is_empty = is_bottom

  let roots environment = fold Key ~f:List.cons ~init:[] environment

  let may_breadcrumbs_to_must = transform Taint.Self Map ~f:Taint.may_breadcrumbs_to_must

  let join_every_frame_with ~frame_kind =
    transform Taint.Self Map ~f:(Taint.join_every_frame_with ~frame_kind)


  let add_local_breadcrumb breadcrumb =
    transform Taint.Self Map ~f:(Taint.add_local_breadcrumb breadcrumb)


  let add_local_breadcrumbs breadcrumbs taint_tree =
    if Features.BreadcrumbSet.is_bottom breadcrumbs || Features.BreadcrumbSet.is_empty breadcrumbs
    then
      taint_tree
    else
      transform Taint.Self Map ~f:(Taint.add_local_breadcrumbs breadcrumbs) taint_tree


  let add_via_features via_features taint_tree =
    if Features.ViaFeatureSet.is_bottom via_features then
      taint_tree
    else
      transform Features.ViaFeatureSet.Self Add ~f:via_features taint_tree


  let extract_features_to_attach ~root ~attach_to_kind taint =
    let taint =
      read ~root ~path:[] taint
      |> Tree.transform Taint.call_info Filter ~f:(CallInfo.equal CallInfo.declaration)
      |> Tree.transform Taint.kind Filter ~f:(Taint.equal_kind attach_to_kind)
      |> Tree.collapse ~breadcrumbs:Features.BreadcrumbSet.empty
    in
    let breadcrumbs = Taint.joined_breadcrumbs taint in
    let breadcrumbs =
      if AccessPath.Root.is_captured_variable root then
        Features.BreadcrumbSet.add (Features.captured_variable ()) breadcrumbs
      else
        breadcrumbs
    in
    breadcrumbs, Taint.via_features taint


  let sanitize_taint_kinds sanitized_kinds taint =
    if Taint.is_empty_kind_set sanitized_kinds then
      taint
    else
      transform Taint.Self Map ~f:(Taint.sanitize_taint_kinds sanitized_kinds) taint


  let apply_sanitizers
      ?(sanitize_source = false)
      ?(sanitize_sink = false)
      ?(sanitize_tito = false)
      ?(ignore_if_sanitize_all = false)
      ?(insert_location = TaintTransformOperation.InsertLocation.Front)
      ?parameter
      ~sanitizer:{ Sanitize.sources; sinks; tito }
      ~taint_configuration
      taint
    =
    let apply ~sanitizers taint =
      if SanitizeTransformSet.is_empty sanitizers then
        taint
      else if ignore_if_sanitize_all && SanitizeTransformSet.is_all sanitizers then
        (* Not yet support sanitizing all kinds in some situations *)
        taint
      else
        match parameter with
        | Some parameter ->
            let apply_taint_transforms = function
              | None -> Tree.bottom
              | Some taint_tree ->
                  Tree.apply_sanitize_transforms
                    ~taint_configuration
                    sanitizers
                    insert_location
                    taint_tree
            in
            update taint parameter ~f:apply_taint_transforms
        | None ->
            transform
              Taint.Self
              Map
              ~f:(Taint.apply_sanitize_transforms ~taint_configuration sanitizers insert_location)
              taint
    in
    let source_sanitizers =
      if sanitize_source then
        SanitizeTransformSet.from_sources sources
      else
        SanitizeTransformSet.empty
    in
    let sink_sanitizers =
      if sanitize_sink then
        SanitizeTransformSet.from_sinks sinks
      else
        SanitizeTransformSet.empty
    in
    let tito_sanitizers = if sanitize_tito then tito else SanitizeTransformSet.empty in
    let sanitizers =
      source_sanitizers
      |> SanitizeTransformSet.join sink_sanitizers
      |> SanitizeTransformSet.join tito_sanitizers
    in
    apply ~sanitizers taint
end

(** Used to infer which sources reach the exit points of a function. *)
module ForwardState = MakeTaintEnvironment (ForwardTaint) ()

(** Used to infer which sinks are reached from parameters, as well as the taint-in-taint-out (TITO)
    using the special LocalReturn sink. *)
module BackwardState = MakeTaintEnvironment (BackwardTaint) ()

let local_return_frame ~output_path ~collapse_depth =
  Frame.create
    [
      Part (TraceLength.Self, 0);
      Part (Features.ReturnAccessPathTree.Path, (output_path, collapse_depth));
      Part (Features.BreadcrumbSet.Self, Features.BreadcrumbSet.empty);
    ]


(* Special sink as it needs the return access path *)
let local_return_taint ~output_path ~collapse_depth =
  BackwardTaint.singleton
    CallInfo.Tito
    Sinks.LocalReturn
    (local_return_frame ~output_path ~collapse_depth)


module SinkTreeWithHandle = struct
  type t = {
    sink_tree: BackwardState.Tree.t;
    handle: IssueHandle.Sink.t;
  }

  let filter_bottom sink_tree_with_identifiers =
    List.filter
      ~f:(fun { sink_tree; _ } -> not (BackwardState.Tree.is_bottom sink_tree))
      sink_tree_with_identifiers


  (* Discard handles, join sink trees into a single tree. *)
  let join sink_tree_with_identifiers =
    List.fold
      ~init:BackwardState.Tree.bottom
      ~f:(fun sofar { sink_tree; _ } -> BackwardState.Tree.join sofar sink_tree)
      sink_tree_with_identifiers
end
