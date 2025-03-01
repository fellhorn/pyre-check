(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* UnannotatedGlobalEnvironment(UGE): layer of the environment stack
 * - upstream: AstEnvironment
 * - downstream: EmptyStubEnvironment
 *
 * It is responsible for taking preprocessed Ast data, breaking it
 * into chunks, and storing it for use in later analysis stages.
 * Almost all downstream logic depends only on data in the UGE, rather
 * than on raw sources.
 *
 * It is also responsible for "resolving exports", which means dealing
 * with name aliases introduced by imports, for example that here:
 * ```
 * # my_module.py
 * from foo import bar as baz
 *
 * # other_module.py
 * from my_module import baz
 * ```
 * the name `baz` in `my_module` actually refers to `foo.bar`.
 *
 * This name alias handling of unannotated globals is not the same as
 * TypeAlias handling, which is what AliasEnvironment does.
 *
 * This is one of the most complicated layers of the environment stack
 * from a data flow perspective because instead of being a single cache
 * table it consists of several separate tables:
 * - one for FunctionDefinitionTable, which are the preprocessed Asts of
 *   function bodies (including module and class toplevels)
 * - one for ClassSummaryTable, which are data structures that concisely
 *   represent some simple facts about a class that come from skimming
 *   the class body and constructor.
 * - one for UnannotatedGlobalTable, which represent the various global
 *   names (including global variables, functions, classes, and imports)
 *   exposed by a model.
 * - a set of KeyTrackers, which are needed because there's no API to
 *   list all shared memory keys so we have to store a one-to-many
 *   record of all the functions / classes / globals per module that
 *   we rely on to, e.g., run type check over all functions.
 *
 * The tables all have to be managed together because all of them
 * are populated from a single computation of a preprocessed Ast,
 * which is an expensive operation we want to do just once per module.
 *)

open Core
open Pyre
open Ast
open Statement
open SharedMemoryKeys

module ModuleComponents = struct
  type t = {
    module_metadata: Ast.Module.t;
    class_summaries: (Ast.Identifier.t * ClassSummary.t Ast.Node.t) list;
    unannotated_globals: UnannotatedGlobal.Collector.Result.t list;
    function_definitions: (Ast.Reference.t * FunctionDefinition.t) list;
  }

  let class_summaries_of_source ({ Source.module_path = { ModulePath.qualifier; _ }; _ } as source) =
    (* TODO (T57944324): Support checking classes that are nested inside function bodies *)
    let module ClassCollector = Visit.MakeStatementVisitor (struct
      type t = Class.t Node.t list

      let visit_children _ = true

      let statement _ sofar = function
        | { Node.location; value = Statement.Class definition } ->
            { Node.location; value = definition } :: sofar
        | _ -> sofar
    end)
    in
    let classes = ClassCollector.visit [] source in
    let classes =
      match Reference.as_list qualifier with
      | [] -> classes @ MissingFromStubs.missing_builtin_classes
      | ["typing"] -> classes @ MissingFromStubs.missing_typing_classes
      | ["typing_extensions"] -> classes @ MissingFromStubs.missing_typing_extensions_classes
      | _ -> classes
    in
    let definition_to_summary { Node.location; value = { Class.name; _ } as definition } =
      let primitive = Reference.show name in
      let definition =
        match primitive with
        | "type" ->
            let value =
              Type.expression
                (Type.parametric "typing.Generic" [Single (Type.variable "typing._T")])
            in
            { definition with Class.base_arguments = [{ name = None; value }] }
        | _ -> definition
      in
      primitive, { Node.location; value = ClassSummary.create ~qualifier definition }
    in
    List.map classes ~f:definition_to_summary


  let function_definitions_of_source ({ Source.module_path; _ } as source) =
    match ModulePath.should_type_check module_path with
    | false ->
        (* Do not collect function bodies for external sources as they won't get type checked *)
        []
    | true -> FunctionDefinition.collect_defines source


  let unannotated_globals_of_source
      ({ Source.module_path = { ModulePath.qualifier; _ }; _ } as source)
    =
    let merge_defines unannotated_globals_alist =
      let not_defines, defines =
        List.partition_map unannotated_globals_alist ~f:(function
            | { UnannotatedGlobal.Collector.Result.name; unannotated_global = Define defines } ->
                Either.Second (name, defines)
            | x -> Either.First x)
      in
      let add_to_map sofar (name, defines) =
        let merge_with_existing to_merge = function
          | None -> Some to_merge
          | Some existing -> Some (to_merge @ existing)
        in
        Map.change sofar name ~f:(merge_with_existing defines)
      in
      List.fold defines ~f:add_to_map ~init:Identifier.Map.empty
      |> Map.to_alist
      |> List.map ~f:(fun (name, defines) ->
             {
               UnannotatedGlobal.Collector.Result.name;
               unannotated_global = Define (List.rev defines);
             })
      |> fun defines -> List.append defines not_defines
    in
    let drop_classes unannotated_globals =
      let is_not_class = function
        | { UnannotatedGlobal.Collector.Result.unannotated_global = Class; _ } -> false
        | _ -> true
      in
      List.filter unannotated_globals ~f:is_not_class
    in
    let globals = UnannotatedGlobal.Collector.from_source source |> merge_defines |> drop_classes in
    let globals =
      match Reference.as_list qualifier with
      | [] -> globals @ MissingFromStubs.missing_builtin_globals
      | _ -> globals
    in
    globals


  let of_source source =
    {
      module_metadata = Ast.Module.create source;
      class_summaries = class_summaries_of_source source;
      unannotated_globals = unannotated_globals_of_source source;
      function_definitions = function_definitions_of_source source;
    }


  let implicit_module () =
    {
      module_metadata = Ast.Module.create_implicit ();
      class_summaries = [];
      unannotated_globals = [];
      function_definitions = [];
    }
end

module IncomingDataComputation = struct
  module Queries = struct
    type t = {
      is_qualifier_tracked: Ast.Reference.t -> bool;
      processed_source_of_qualifier: Ast.Reference.t -> Ast.Source.t option;
    }
  end

  let module_components Queries.{ is_qualifier_tracked; processed_source_of_qualifier } qualifier =
    match processed_source_of_qualifier qualifier with
    | Some source -> Some (ModuleComponents.of_source source)
    | None ->
        if is_qualifier_tracked qualifier then
          Some (ModuleComponents.implicit_module ())
        else
          None
end

module OutgoingDataComputation = struct
  module Queries = struct
    type t = {
      class_exists: string -> bool;
      all_classes: unit -> Type.Primitive.t list;
      all_unannotated_globals: unit -> Reference.t list;
      get_define_names: Reference.t -> Reference.t list;
      get_class_summary: string -> ClassSummary.t Node.t option;
      get_unannotated_global: Reference.t -> UnannotatedGlobal.t option;
      get_function_definition: Reference.t -> FunctionDefinition.t option;
      get_module_metadata: Reference.t -> Module.t option;
      module_exists: Reference.t -> bool;
    }
  end

  let all_classes Queries.{ all_classes; _ } = all_classes ()

  let all_unannotated_globals Queries.{ all_unannotated_globals; _ } = all_unannotated_globals ()

  let get_define_names Queries.{ get_define_names; _ } = get_define_names

  let get_module_metadata Queries.{ get_module_metadata; _ } = get_module_metadata

  let module_exists Queries.{ module_exists; _ } = module_exists

  let get_class_summary Queries.{ get_class_summary; _ } = get_class_summary

  let class_exists Queries.{ class_exists; _ } = class_exists

  let get_function_definition Queries.{ get_function_definition; _ } = get_function_definition

  let get_unannotated_global Queries.{ get_unannotated_global; _ } = get_unannotated_global

  let get_define_body Queries.{ get_function_definition; _ } name =
    get_function_definition name >>= fun { FunctionDefinition.body; _ } -> body


  let primitive_name annotation =
    let primitive, _ = Type.split annotation in
    Type.primitive_name primitive


  let is_protocol Queries.{ get_class_summary; _ } annotation =
    primitive_name annotation
    >>= get_class_summary
    >>| Node.value
    >>| ClassSummary.is_protocol
    |> Option.value ~default:false


  let legacy_resolve_exports Queries.{ get_module_metadata; _ } reference =
    (* Resolve exports. Fixpoint is necessary due to export/module name conflicts: P59503092 *)
    let widening_threshold = 25 in
    let rec resolve_exports_fixpoint ~reference ~visited ~count =
      if Set.mem visited reference || count > widening_threshold then
        reference
      else
        let rec resolve_exports ~lead ~tail =
          match tail with
          | head :: tail -> (
              let incremented_lead = lead @ [head] in
              if Option.is_some (get_module_metadata (Reference.create_from_list incremented_lead))
              then
                resolve_exports ~lead:incremented_lead ~tail
              else
                get_module_metadata (Reference.create_from_list lead)
                >>= (fun definition ->
                      Module.legacy_aliased_export definition (Reference.create head))
                >>| (fun export -> Reference.combine export (Reference.create_from_list tail))
                |> function
                | Some reference -> reference
                | None -> resolve_exports ~lead:(lead @ [head]) ~tail)
          | _ -> reference
        in
        match Reference.as_list reference with
        | head :: tail ->
            let exported_reference = resolve_exports ~lead:[head] ~tail in
            if Reference.is_strict_prefix ~prefix:reference exported_reference then
              reference
            else
              resolve_exports_fixpoint
                ~reference:exported_reference
                ~visited:(Set.add visited reference)
                ~count:(count + 1)
        | _ -> reference
    in
    resolve_exports_fixpoint ~reference ~visited:Reference.Set.empty ~count:0


  let resolve_exports Queries.{ get_module_metadata; _ } ?(from = Reference.empty) reference =
    let module ResolveExportItem = struct
      module T = struct
        type t = {
          current_module: Reference.t;
          name: Identifier.t;
        }
        [@@deriving sexp, compare, hash]
      end

      include T
      include Hashable.Make (T)
    end
    in
    let visited_set = ResolveExportItem.Hash_set.create () in
    let rec resolve_module_alias ~current_module ~names_to_resolve () =
      match get_module_metadata current_module with
      | None -> (
          (* If the module is not found:
           *  - first try to look up the more-specific module from including
           *    more of the reference we are looking up
           *    - this is necessary in order to do lazy module tracking which
           *      prevents us from fully supporting namespace modules.
           * - If that also fails, check for a placeholder stub.
           *)
          match names_to_resolve with
          | head :: tail ->
              resolve_module_alias
                ~current_module:(Reference.create ~prefix:current_module head)
                ~names_to_resolve:tail
                ()
          | [] ->
              let rec resolve_placeholder_stub sofar = function
                | [] -> None
                | name :: prefixes -> (
                    let checked_module = List.rev prefixes |> Reference.create_from_list in
                    let sofar = name :: sofar in
                    match get_module_metadata checked_module with
                    | Some module_metadata when Module.empty_stub module_metadata ->
                        Some
                          (ResolvedReference.PlaceholderStub
                             { stub_module = checked_module; remaining = sofar })
                    | _ -> resolve_placeholder_stub sofar prefixes)
              in
              (* Make sure none of the parent of `current_module` is placeholder stub *)
              resolve_placeholder_stub
                names_to_resolve
                (Reference.as_list current_module |> List.rev))
      | Some module_metadata -> (
          match Module.empty_stub module_metadata with
          | true ->
              Some
                (ResolvedReference.PlaceholderStub
                   { stub_module = current_module; remaining = names_to_resolve })
          | false -> (
              match names_to_resolve with
              | [] -> Some (ResolvedReference.Module current_module)
              | next_name :: rest_names -> (
                  let item = { ResolveExportItem.current_module; name = next_name } in
                  match Hash_set.strict_add visited_set item with
                  | Result.Error _ ->
                      (* Module alias cycle detected. Abort resolution. *)
                      None
                  | Result.Ok _ -> (
                      match Module.get_export module_metadata next_name with
                      | None -> (
                          match Module.get_export module_metadata "__getattr__" with
                          | Some Module.Export.(Name (Define { is_getattr_any = true })) ->
                              Some
                                (ResolvedReference.ModuleAttribute
                                   {
                                     from = current_module;
                                     name = next_name;
                                     export = ResolvedReference.FromModuleGetattr;
                                     remaining = rest_names;
                                   })
                          | _ ->
                              (* We could be hitting an implicit module, or we could be hitting an
                                 explicit module whose name is a prefix of another explicit module.
                                 Keep moving through the current reference chain to make sure we
                                 don't mis-handle those cases. *)
                              resolve_module_alias
                                ~current_module:
                                  (Reference.create next_name |> Reference.combine current_module)
                                ~names_to_resolve:rest_names
                                ())
                      | Some (Module.Export.NameAlias { from; name }) ->
                          if Reference.equal current_module from then
                            (* This could legitimately happen when an __init__ module trying to
                               import its sibling modules *)
                            resolve_module_alias
                              ~current_module:(Reference.create name |> Reference.combine from)
                              ~names_to_resolve:rest_names
                              ()
                          else
                            (* We don't know if `name` refers to a module or not. Move forward on
                               the alias chain. *)
                            resolve_module_alias
                              ~current_module:from
                              ~names_to_resolve:(name :: rest_names)
                              ()
                      | Some (Module.Export.Module name) ->
                          (* `name` is definitely a module. *)
                          resolve_module_alias ~current_module:name ~names_to_resolve:rest_names ()
                      | Some (Module.Export.Name export) ->
                          (* We find a non-module. *)
                          Some
                            (ResolvedReference.ModuleAttribute
                               {
                                 from = current_module;
                                 name = next_name;
                                 export = ResolvedReference.Exported export;
                                 remaining = rest_names;
                               })))))
    in
    resolve_module_alias ~current_module:from ~names_to_resolve:(Reference.as_list reference) ()


  let first_matching_class_decorator
      queries
      ~names
      { Node.value = { ClassSummary.decorators; _ }; _ }
    =
    let resolve_and_check_for_match decorator =
      match Decorator.from_expression decorator with
      | None -> None
      | Some ({ Ast.Statement.Decorator.name = { Node.value = name; location }; _ } as decorator) ->
          let resolved_name =
            match resolve_exports queries name with
            | Some (ResolvedReference.ModuleAttribute { from; name; remaining; _ }) ->
                Reference.create_from_list (name :: remaining) |> Reference.combine from
            | _ -> name
          in
          let with_matched_name_if_matches name_to_match =
            if String.equal (Reference.show resolved_name) name_to_match then
              Some { decorator with name = { Node.value = resolved_name; location } }
            else
              None
          in
          List.find_map names ~f:with_matched_name_if_matches
    in
    List.find_map decorators ~f:resolve_and_check_for_match


  let exists_matching_class_decorator queries ~names class_summary =
    first_matching_class_decorator queries ~names class_summary |> Option.is_some
end

module ReadOnly = struct
  type t = {
    ast_environment: AstEnvironment.ReadOnly.t;
    get_queries: dependency:DependencyKey.registered option -> OutgoingDataComputation.Queries.t;
  }

  let get_queries ?dependency { get_queries; _ } = get_queries ~dependency

  let ast_environment { ast_environment; _ } = ast_environment

  let controls { ast_environment; _ } = AstEnvironment.ReadOnly.controls ast_environment

  let unannotated_global_environment = Fn.id

  let all_classes { get_queries; _ } =
    get_queries ~dependency:None |> OutgoingDataComputation.all_classes


  let all_unannotated_globals { get_queries; _ } =
    get_queries ~dependency:None |> OutgoingDataComputation.all_unannotated_globals


  let get_define_names { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_define_names


  let get_module_metadata { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_module_metadata


  let module_exists { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.module_exists


  let get_class_summary { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_class_summary


  let class_exists { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.class_exists


  let get_function_definition { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_function_definition


  let get_unannotated_global { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_unannotated_global


  let get_define_body { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.get_define_body


  let is_protocol { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.is_protocol


  let legacy_resolve_exports { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.legacy_resolve_exports


  let resolve_exports { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.resolve_exports


  let first_matching_class_decorator { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.first_matching_class_decorator


  let exists_matching_class_decorator { get_queries; _ } ?dependency =
    get_queries ~dependency |> OutgoingDataComputation.exists_matching_class_decorator
end

module UpdateResult = struct
  type t = {
    triggered_dependencies: DependencyKey.RegisteredSet.t;
    upstream: AstEnvironment.UpdateResult.t;
  }

  let locally_triggered_dependencies { triggered_dependencies; _ } = triggered_dependencies

  let all_triggered_dependencies { triggered_dependencies; upstream; _ } =
    [triggered_dependencies; AstEnvironment.UpdateResult.triggered_dependencies upstream]


  let invalidated_modules { upstream; _ } = AstEnvironment.UpdateResult.invalidated_modules upstream

  let module_updates { upstream; _ } = AstEnvironment.UpdateResult.module_updates upstream

  let unannotated_global_environment_update_result = Fn.id
end

module FromReadOnlyUpstream = struct
  (* The key tracking is necessary because there is no empirical way to determine which classes
     exist for a given class. This "fan-out" necessitates internal tracking. However, this module
     need not be sealed to ensure write only-ness since we're not dependency tracking this, since
     it's only used internally for doing our dependency analysis, and for all_classes, which is only
     used for all-or-nothing operations like validating the class hierarchy and printing it for
     debugging purposes *)
  module KeyTracker = struct
    module ClassKeyValue = struct
      type t = Identifier.t list [@@deriving compare]

      let prefix = Hack_parallel.Std.Prefix.make ()

      let description = "Class keys"
    end

    module UnannotatedGlobalKeyValue = struct
      type t = Reference.t list [@@deriving compare]

      let prefix = Hack_parallel.Std.Prefix.make ()

      let description = "Class keys"
    end

    module ClassKeys =
      Memory.FirstClass.WithCache.Make (SharedMemoryKeys.ReferenceKey) (ClassKeyValue)
    module UnannotatedGlobalKeys =
      Memory.FirstClass.WithCache.Make (SharedMemoryKeys.ReferenceKey) (UnannotatedGlobalKeyValue)

    type t = {
      class_keys: ClassKeys.t;
      unannotated_global_keys: UnannotatedGlobalKeys.t;
    }

    let create () =
      {
        class_keys = ClassKeys.create ();
        unannotated_global_keys = UnannotatedGlobalKeys.create ();
      }


    let add_class_keys { class_keys; _ } = ClassKeys.add class_keys

    let add_unannotated_global_keys { unannotated_global_keys; _ } =
      UnannotatedGlobalKeys.add unannotated_global_keys


    let get_class_keys { class_keys; _ } qualifiers =
      ClassKeys.KeySet.of_list qualifiers
      |> ClassKeys.get_batch class_keys
      |> ClassKeys.KeyMap.values
      |> List.filter_map ~f:Fn.id
      |> List.concat


    let get_unannotated_global_keys { unannotated_global_keys; _ } qualifiers =
      UnannotatedGlobalKeys.KeySet.of_list qualifiers
      |> UnannotatedGlobalKeys.get_batch unannotated_global_keys
      |> UnannotatedGlobalKeys.KeyMap.values
      |> List.filter_map ~f:Fn.id
      |> List.concat


    module PreviousKeys = struct
      type t = {
        previous_classes_list: Type.Primitive.t list;
        previous_classes: Type.Primitive.Set.t;
        previous_unannotated_globals_list: Reference.t list;
        previous_unannotated_globals: Reference.Set.t;
      }
    end

    let get_previous_keys_and_clear
        ({ class_keys; unannotated_global_keys } as key_tracker)
        invalidated_modules
      =
      let previous_classes_list = get_class_keys key_tracker invalidated_modules in
      let previous_unannotated_globals_list =
        get_unannotated_global_keys key_tracker invalidated_modules
      in
      let previous_classes = Type.Primitive.Set.of_list previous_classes_list in
      let previous_unannotated_globals = Reference.Set.of_list previous_unannotated_globals_list in
      ClassKeys.KeySet.of_list invalidated_modules |> ClassKeys.remove_batch class_keys;
      UnannotatedGlobalKeys.KeySet.of_list invalidated_modules
      |> UnannotatedGlobalKeys.remove_batch unannotated_global_keys;
      PreviousKeys.
        {
          previous_classes_list;
          previous_classes;
          previous_unannotated_globals_list;
          previous_unannotated_globals;
        }
  end

  module ModuleValue = struct
    type t = Module.t

    let prefix = Hack_parallel.Std.Prefix.make ()

    let description = "Module"

    let equal = Module.equal
  end

  module ModuleTable = struct
    include
      DependencyTrackedMemory.DependencyTrackedTableWithCache
        (SharedMemoryKeys.ReferenceKey)
        (DependencyKey)
        (ModuleValue)

    let is_qualifier = true

    let key_to_reference = Fn.id
  end

  module DefineNamesValue = struct
    type t = Reference.t list [@@deriving equal]

    let prefix = Hack_parallel.Std.Prefix.make ()

    let description = "DefineListing"
  end

  module DefineNames = struct
    include
      DependencyTrackedMemory.DependencyTrackedTableWithCache
        (SharedMemoryKeys.ReferenceKey)
        (DependencyKey)
        (DefineNamesValue)

    let is_qualifier = true

    let key_to_reference = Fn.id

    let get_define_names define_names qualifiers =
      get_batch define_names (KeySet.of_list qualifiers)
      |> KeyMap.values
      |> List.filter_opt
      |> List.concat
  end

  module ClassSummaryValue = struct
    type t = ClassSummary.t Node.t

    let prefix = Hack_parallel.Std.Prefix.make ()

    let description = "ClassSummary"

    let equal = Memory.equal_from_compare (Node.compare ClassSummary.compare)
  end

  module ClassSummaryTable = struct
    include
      DependencyTrackedMemory.DependencyTrackedTableWithCache
        (SharedMemoryKeys.StringKey)
        (DependencyKey)
        (ClassSummaryValue)

    let is_qualifier = false

    let key_to_reference name = Reference.create name
  end

  module FunctionDefinitionValue = struct
    type t = FunctionDefinition.t

    let description = "FunctionDefinition"

    let prefix = Hack_parallel.Std.Prefix.make ()

    let equal definition0 definition1 =
      Int.equal 0 (FunctionDefinition.compare definition0 definition1)
  end

  module FunctionDefinitionTable = struct
    include
      DependencyTrackedMemory.DependencyTrackedTableWithCache
        (SharedMemoryKeys.ReferenceKey)
        (DependencyKey)
        (FunctionDefinitionValue)

    let is_qualifier = false

    let key_to_reference = Fn.id
  end

  module UnannotatedGlobalValue = struct
    type t = UnannotatedGlobal.t

    let prefix = Hack_parallel.Std.Prefix.make ()

    let description = "UnannotatedGlobal"

    let equal = Memory.equal_from_compare UnannotatedGlobal.compare
  end

  module UnannotatedGlobalTable = struct
    include
      DependencyTrackedMemory.DependencyTrackedTableNoCache
        (SharedMemoryKeys.ReferenceKey)
        (DependencyKey)
        (UnannotatedGlobalValue)

    let is_qualifier = false

    let key_to_reference = Fn.id
  end

  module ReadWrite = struct
    type t = {
      key_tracker: KeyTracker.t;
      module_table: ModuleTable.t;
      define_names: DefineNames.t;
      class_summary_table: ClassSummaryTable.t;
      function_definition_table: FunctionDefinitionTable.t;
      unannotated_global_table: UnannotatedGlobalTable.t;
      ast_environment: AstEnvironment.ReadOnly.t;
    }

    let create ast_environment =
      {
        key_tracker = KeyTracker.create ();
        module_table = ModuleTable.create ();
        define_names = DefineNames.create ();
        class_summary_table = ClassSummaryTable.create ();
        function_definition_table = FunctionDefinitionTable.create ();
        unannotated_global_table = UnannotatedGlobalTable.create ();
        ast_environment;
      }


    let controls { ast_environment; _ } = AstEnvironment.ReadOnly.controls ast_environment
  end

  include ReadWrite

  let set_module_data
      ~environment:
        {
          key_tracker;
          define_names;
          module_table;
          class_summary_table;
          unannotated_global_table;
          function_definition_table;
          _;
        }
      ~qualifier
      ModuleComponents.
        { module_metadata; class_summaries; unannotated_globals; function_definitions }
    =
    let set_module () = ModuleTable.add module_table qualifier module_metadata in
    let set_class_summaries () =
      let register new_classes (class_name, class_summary_node) =
        ClassSummaryTable.write_around class_summary_table class_name class_summary_node;
        Set.add new_classes class_name
      in
      class_summaries
      |> List.fold ~init:Type.Primitive.Set.empty ~f:register
      |> Set.to_list
      |> KeyTracker.add_class_keys key_tracker qualifier
    in
    let set_function_definitions () =
      let register (name, function_definition) =
        FunctionDefinitionTable.write_around function_definition_table name function_definition;
        name
      in
      function_definitions
      |> List.map ~f:register
      |> List.sort ~compare:Reference.compare
      |> DefineNames.add define_names qualifier
    in
    let set_unannotated_globals () =
      let register { UnannotatedGlobal.Collector.Result.name; unannotated_global } =
        let name = Reference.create name |> Reference.combine qualifier in
        UnannotatedGlobalTable.add unannotated_global_table name unannotated_global;
        name
      in
      unannotated_globals
      |> List.map ~f:register
      |> KeyTracker.add_unannotated_global_keys key_tracker qualifier
    in
    set_class_summaries ();
    set_function_definitions ();
    set_unannotated_globals ();
    (* We must set this last, because lazy-loading uses Module.mem to determine whether the source
       has already been processed. So setting it earlier can lead to data races *)
    set_module ()


  let add_to_transaction
      {
        module_table;
        class_summary_table;
        function_definition_table;
        unannotated_global_table;
        define_names;
        _;
      }
      transaction
      ~previous_classes_list
      ~previous_unannotated_globals_list
      ~previous_defines_list
      ~invalidated_modules
    =
    let module_keys = ModuleTable.KeySet.of_list invalidated_modules in
    let class_keys = ClassSummaryTable.KeySet.of_list previous_classes_list in
    let defines_keys = FunctionDefinitionTable.KeySet.of_list previous_defines_list in
    let unannotated_globals_keys =
      UnannotatedGlobalTable.KeySet.of_list previous_unannotated_globals_list
    in
    transaction
    |> ModuleTable.add_to_transaction module_table ~keys:module_keys
    |> DefineNames.add_to_transaction define_names ~keys:module_keys
    |> ClassSummaryTable.add_to_transaction class_summary_table ~keys:class_keys
    |> FunctionDefinitionTable.add_to_transaction function_definition_table ~keys:defines_keys
    |> UnannotatedGlobalTable.add_to_transaction
         unannotated_global_table
         ~keys:unannotated_globals_keys


  let get_all_dependents ~class_additions ~unannotated_global_additions ~define_additions =
    let function_and_class_dependents =
      DependencyKey.RegisteredSet.union
        (ClassSummaryTable.KeySet.of_list class_additions |> ClassSummaryTable.get_all_dependents)
        (FunctionDefinitionTable.KeySet.of_list define_additions
        |> FunctionDefinitionTable.get_all_dependents)
    in
    DependencyKey.RegisteredSet.union
      function_and_class_dependents
      (UnannotatedGlobalTable.KeySet.of_list unannotated_global_additions
      |> UnannotatedGlobalTable.get_all_dependents)


  module LazyLoader = struct
    type t = {
      environment: ReadWrite.t;
      queries: IncomingDataComputation.Queries.t;
    }

    let try_load_module { environment; queries } qualifier =
      if not (ModuleTable.mem environment.module_table qualifier) then
        IncomingDataComputation.module_components queries qualifier
        >>| set_module_data ~environment ~qualifier
        |> ignore


    (* Try to load a module, with dependency tracking of our attempt and caching of successful
       reads. *)
    let try_load_module_with_cache ?dependency ({ environment; _ } as loader) qualifier =
      if not (ModuleTable.mem environment.module_table ?dependency qualifier) then
        (* Note: a dependency should be registered above even if no module exists, so we no longer
           need dependency tracking. *)
        try_load_module loader qualifier


    (* Pyre currently handles imports by transforming the source code so that
     * all names are fully qualified. This means that it is never possible, in
     * general, to look at a name and load the module where it lives, because
     * when we see a name like `foo.bar.baz` it could be:
     * - a module `baz` in a package `foo.bar`
     * - a name `bar` in a module `foo.bar`
     * - a nested name `bar.baz` in a module `foo`; this could happen via
     *   nested classes or via re-exports.
     *
     * As a result, we always have to attempt to load all of the "possible"
     * modules where this name might live - `foo`, `foo.bar`, and `foo.bar.baz`.
     * We load them in left-to-right order so that in the event of a collision (which
     * does happen, and unlike the Python runtime Pyre is not capable of resolving these)
     * the name bound in the closer-to-root module always wins in initial check. Incremental
     * behavior in the presence of fully-qualified-name collisions is undefined.
     *)
    let load_all_possible_modules_for_symbol ?dependency loader ~is_qualifier reference =
      let load_module_if_tracked = try_load_module_with_cache ?dependency loader in
      let ancestors_descending = Reference.possible_qualifiers_after_delocalize reference in
      List.iter ancestors_descending ~f:load_module_if_tracked;
      if is_qualifier then load_module_if_tracked reference;
      ()
  end

  module ReadOnlyTable = struct
    module type S = sig
      type key

      type value

      type table

      type t

      val create : loader:LazyLoader.t -> table -> t

      val mem : t -> ?dependency:DependencyKey.registered -> key -> bool

      val get : t -> ?dependency:DependencyKey.registered -> key -> value option
    end

    module type In = sig
      type key

      type value

      type t

      val is_qualifier : bool

      val key_to_reference : key -> Reference.t

      val mem : t -> ?dependency:DependencyKey.registered -> key -> bool

      val get : t -> ?dependency:DependencyKey.registered -> key -> value option
    end

    module Make (In : In) :
      S with type key := In.key and type value := In.value and type table := In.t = struct
      type t = {
        loader: LazyLoader.t;
        table: In.t;
      }

      let create ~loader table = { loader; table }

      let is_qualifier = In.is_qualifier

      (* See the comment on load_all_possible_modules_for_symbol for a description of why this works
         as it does *)
      let mem { loader; table } ?dependency key =
        (* First handle the case where it's already in the hash map *)
        match In.mem table ?dependency key with
        | true -> true
        | false ->
            (* If no precomputed value exists, we make sure all potential qualifiers are loaded *)
            LazyLoader.load_all_possible_modules_for_symbol
              ?dependency
              loader
              ~is_qualifier
              (In.key_to_reference key);
            (* We try fetching again *)
            In.mem table ?dependency key


      (* See the comment on load_all_possible_modules_for_symbol for a description of why this works
         as it does *)
      let get { loader; table } ?dependency key =
        (* The first get finds precomputed values *)
        match In.get table ?dependency key with
        | Some _ as hit -> hit
        | None ->
            (* If no precomputed value exists, we make sure all potential qualifiers are loaded *)
            LazyLoader.load_all_possible_modules_for_symbol
              ?dependency
              loader
              ~is_qualifier
              (In.key_to_reference key);
            (* We try fetching again *)
            In.get table ?dependency key
    end
  end

  let incoming_queries { ast_environment; _ } =
    let track_dependencies =
      AstEnvironment.ReadOnly.controls ast_environment |> EnvironmentControls.track_dependencies
    in
    let is_qualifier_tracked =
      AstEnvironment.ReadOnly.module_tracker ast_environment
      |> ModuleTracker.ReadOnly.is_qualifier_tracked
    in
    let processed_source_of_qualifier qualifier =
      let dependency =
        if track_dependencies then
          Some (WildcardImport qualifier |> SharedMemoryKeys.DependencyKey.Registry.register)
        else
          None
      in
      AstEnvironment.ReadOnly.processed_source_of_qualifier ast_environment ?dependency qualifier
    in
    IncomingDataComputation.Queries.{ is_qualifier_tracked; processed_source_of_qualifier }


  let cold_start environment =
    (* Eagerly load `builtins.pyi` + the project sources but nothing else *)
    let qualifier = Reference.empty in
    IncomingDataComputation.module_components (incoming_queries environment) qualifier
    >>| set_module_data ~environment ~qualifier
    |> ignore


  let outgoing_queries
      ~dependency
      ({
         ast_environment;
         key_tracker;
         module_table;
         define_names;
         class_summary_table;
         function_definition_table;
         unannotated_global_table;
       } as environment)
    =
    let loader = LazyLoader.{ environment; queries = incoming_queries environment } in
    (* Mask the raw DependencyTrackedTables with lazy read-only views of each one *)
    let module ModuleTable = ReadOnlyTable.Make (ModuleTable) in
    let module DefineNames = ReadOnlyTable.Make (DefineNames) in
    let module ClassSummaryTable = ReadOnlyTable.Make (ClassSummaryTable) in
    let module FunctionDefinitionTable = ReadOnlyTable.Make (FunctionDefinitionTable) in
    let module UnannotatedGlobalTable = ReadOnlyTable.Make (UnannotatedGlobalTable) in
    let module_table = ModuleTable.create ~loader module_table in
    let define_names = DefineNames.create ~loader define_names in
    let class_summary_table = ClassSummaryTable.create ~loader class_summary_table in
    let function_definition_table =
      FunctionDefinitionTable.create ~loader function_definition_table
    in
    let unannotated_global_table = UnannotatedGlobalTable.create ~loader unannotated_global_table in
    let module_tracker = AstEnvironment.ReadOnly.module_tracker ast_environment in
    (* Define the basic getters and existence checks *)
    let get_module_metadata qualifier =
      let qualifier =
        match Reference.as_list qualifier with
        | ["future"; "builtins"]
        | ["builtins"] ->
            Reference.empty
        | _ -> qualifier
      in
      match ModuleTable.get module_table ?dependency qualifier with
      | Some _ as result -> result
      | None -> None
    in
    let module_exists qualifier =
      let qualifier =
        match Reference.as_list qualifier with
        | ["future"; "builtins"]
        | ["builtins"] ->
            Reference.empty
        | _ -> qualifier
      in
      ModuleTable.mem module_table ?dependency qualifier
    in
    let get_class_summary = ClassSummaryTable.get class_summary_table ?dependency in
    let class_exists = ClassSummaryTable.mem class_summary_table ?dependency in
    let get_function_definition =
      FunctionDefinitionTable.get function_definition_table ?dependency
    in
    let get_unannotated_global = UnannotatedGlobalTable.get unannotated_global_table ?dependency in
    let get_define_names qualifier =
      DefineNames.get define_names ?dependency qualifier |> Option.value ~default:[]
    in
    (* Define the bulk key reads - these tell us what's been loaded thus far *)
    let all_classes () =
      ModuleTracker.ReadOnly.explicit_qualifiers module_tracker
      |> KeyTracker.get_class_keys key_tracker
    in
    let all_unannotated_globals () =
      ModuleTracker.ReadOnly.explicit_qualifiers module_tracker
      |> KeyTracker.get_unannotated_global_keys key_tracker
    in
    OutgoingDataComputation.Queries.
      {
        get_module_metadata;
        module_exists;
        get_class_summary;
        class_exists;
        get_function_definition;
        get_unannotated_global;
        get_define_names;
        all_classes;
        all_unannotated_globals;
      }


  let read_only ({ ast_environment; _ } as environment) =
    { ReadOnly.ast_environment; get_queries = outgoing_queries environment }


  let update ({ key_tracker; define_names; _ } as environment) ~scheduler upstream =
    let invalidated_modules = AstEnvironment.UpdateResult.invalidated_modules upstream in
    let map sources =
      let loader = LazyLoader.{ environment; queries = incoming_queries environment } in
      let register qualifier = LazyLoader.try_load_module loader qualifier in
      List.iter sources ~f:register
    in
    let update () =
      SharedMemoryKeys.DependencyKey.Registry.collected_iter
        scheduler
        ~policy:
          (Scheduler.Policy.fixed_chunk_count
             ~minimum_chunks_per_worker:1
             ~minimum_chunk_size:100
             ~preferred_chunks_per_worker:5
             ())
        ~f:map
        ~inputs:invalidated_modules
    in
    let KeyTracker.PreviousKeys.
          {
            previous_classes_list;
            previous_classes;
            previous_unannotated_globals_list;
            previous_unannotated_globals;
          }
      =
      KeyTracker.get_previous_keys_and_clear key_tracker invalidated_modules
    in
    let previous_defines_list = DefineNames.get_define_names define_names invalidated_modules in
    let triggered_dependencies =
      PyreProfiling.track_duration_and_shared_memory_with_dynamic_tags
        "TableUpdate(Unannotated globals)"
        ~f:(fun _ ->
          let (), mutation_triggers =
            DependencyKey.Transaction.empty ~scheduler
            |> add_to_transaction
                 environment
                 ~previous_classes_list
                 ~previous_unannotated_globals_list
                 ~previous_defines_list
                 ~invalidated_modules
            |> DependencyKey.Transaction.execute ~update
          in
          let current_classes =
            KeyTracker.get_class_keys key_tracker invalidated_modules |> Type.Primitive.Set.of_list
          in
          let current_defines =
            DefineNames.get_define_names define_names invalidated_modules |> Reference.Set.of_list
          in
          let current_unannotated_globals =
            KeyTracker.get_unannotated_global_keys key_tracker invalidated_modules
            |> Reference.Set.of_list
          in
          let class_additions = Set.diff current_classes previous_classes in
          let define_additions =
            Reference.Set.of_list previous_defines_list |> Set.diff current_defines
          in
          let unannotated_global_additions =
            Set.diff current_unannotated_globals previous_unannotated_globals
          in
          let addition_triggers =
            get_all_dependents
              ~class_additions:(Set.to_list class_additions)
              ~unannotated_global_additions:(Set.to_list unannotated_global_additions)
              ~define_additions:(Set.to_list define_additions)
          in
          let triggered_dependencies =
            DependencyKey.RegisteredSet.union addition_triggers mutation_triggers
          in
          let tags () =
            let triggered_dependencies_size =
              SharedMemoryKeys.DependencyKey.RegisteredSet.cardinal triggered_dependencies
              |> Format.sprintf "%d"
            in
            [
              "phase_name", "Global discovery";
              "number_of_triggered_dependencies", triggered_dependencies_size;
            ]
          in
          { PyreProfiling.result = triggered_dependencies; tags })
    in
    { UpdateResult.triggered_dependencies; upstream }
end

module Base = struct
  type t = {
    ast_environment: AstEnvironment.t;
    from_read_only_upstream: FromReadOnlyUpstream.t;
  }

  let create controls =
    let ast_environment = AstEnvironment.create controls in
    let from_read_only_upstream =
      AstEnvironment.read_only ast_environment |> FromReadOnlyUpstream.create
    in
    FromReadOnlyUpstream.cold_start from_read_only_upstream;
    { ast_environment; from_read_only_upstream }


  let update_this_and_all_preceding_environments
      { ast_environment; from_read_only_upstream }
      ~scheduler
      events
    =
    let update_result = AstEnvironment.update ~scheduler ast_environment events in
    FromReadOnlyUpstream.update from_read_only_upstream ~scheduler update_result


  let read_only { from_read_only_upstream; _ } =
    FromReadOnlyUpstream.read_only from_read_only_upstream


  let controls { from_read_only_upstream; _ } =
    FromReadOnlyUpstream.controls from_read_only_upstream


  let ast_environment { ast_environment; _ } = ast_environment

  (* All SharedMemory tables are populated and stored in separate, imperative steps that must be run
     before loading / after storing. These functions only handle serializing and deserializing the
     non-SharedMemory data *)
  let load controls =
    let ast_environment = AstEnvironment.load controls in
    let from_read_only_upstream =
      AstEnvironment.read_only ast_environment |> FromReadOnlyUpstream.create
    in
    { ast_environment; from_read_only_upstream }


  let store { ast_environment; _ } = AstEnvironment.store ast_environment
end

module Overlay = struct
  type t = {
    parent: ReadOnly.t;
    ast_environment: AstEnvironment.Overlay.t;
    from_read_only_upstream: FromReadOnlyUpstream.t;
  }

  let create parent =
    let ast_environment = ReadOnly.ast_environment parent |> AstEnvironment.Overlay.create in
    let from_read_only_upstream =
      AstEnvironment.Overlay.read_only ast_environment |> FromReadOnlyUpstream.create
    in
    { parent; ast_environment; from_read_only_upstream }


  let module_tracker { ast_environment; _ } = AstEnvironment.Overlay.module_tracker ast_environment

  let consume_upstream_update ({ from_read_only_upstream; _ } as environment) update_result =
    let filtered_update_result =
      let filtered_invalidated_modules =
        AstEnvironment.UpdateResult.invalidated_modules update_result
        |> List.filter ~f:(module_tracker environment |> ModuleTracker.Overlay.owns_qualifier)
      in
      {
        update_result with
        AstEnvironment.UpdateResult.invalidated_modules = filtered_invalidated_modules;
      }
    in
    FromReadOnlyUpstream.update
      from_read_only_upstream
      ~scheduler:(Scheduler.create_sequential ())
      filtered_update_result


  let update_overlaid_code ({ ast_environment; _ } as environment) ~code_updates =
    AstEnvironment.Overlay.update_overlaid_code ast_environment ~code_updates
    |> consume_upstream_update environment


  let propagate_parent_update
      environment
      { UpdateResult.triggered_dependencies = parent_triggered_dependencies; upstream }
    =
    let { UpdateResult.triggered_dependencies; _ } = consume_upstream_update environment upstream in
    {
      UpdateResult.triggered_dependencies =
        SharedMemoryKeys.DependencyKey.RegisteredSet.union
          parent_triggered_dependencies
          triggered_dependencies;
      upstream;
    }


  let outgoing_queries ?dependency ({ parent; from_read_only_upstream; _ } as environment) =
    let this_queries =
      FromReadOnlyUpstream.read_only from_read_only_upstream |> ReadOnly.get_queries ?dependency
    in
    let parent_queries = ReadOnly.get_queries ?dependency parent in
    let OutgoingDataComputation.Queries.{ all_classes; all_unannotated_globals; _ } =
      parent_queries
    in
    let if_owns ~owns ~f key =
      if owns key then
        f this_queries key
      else
        f parent_queries key
    in
    let owns_qualifier, owns_reference, owns_qualified_class_name =
      let module_tracker = module_tracker environment in
      ( ModuleTracker.Overlay.owns_qualifier module_tracker,
        ModuleTracker.Overlay.owns_reference module_tracker,
        ModuleTracker.Overlay.owns_identifier module_tracker )
    in
    OutgoingDataComputation.Queries.
      {
        module_exists = if_owns ~owns:owns_qualifier ~f:OutgoingDataComputation.module_exists;
        get_module_metadata =
          if_owns ~owns:owns_qualifier ~f:OutgoingDataComputation.get_module_metadata;
        get_define_names = if_owns ~owns:owns_qualifier ~f:OutgoingDataComputation.get_define_names;
        class_exists =
          if_owns ~owns:owns_qualified_class_name ~f:OutgoingDataComputation.class_exists;
        get_class_summary =
          if_owns ~owns:owns_qualified_class_name ~f:OutgoingDataComputation.get_class_summary;
        get_function_definition =
          if_owns ~owns:owns_reference ~f:OutgoingDataComputation.get_function_definition;
        get_unannotated_global =
          if_owns ~owns:owns_reference ~f:OutgoingDataComputation.get_unannotated_global;
        all_classes;
        all_unannotated_globals;
      }


  let read_only ({ from_read_only_upstream; _ } as environment) =
    let { FromReadOnlyUpstream.ast_environment; _ } = from_read_only_upstream in
    let get_queries ~dependency = outgoing_queries ?dependency environment in
    { ReadOnly.ast_environment; get_queries }
end

include Base
