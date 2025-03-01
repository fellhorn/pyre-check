(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type raw_code = string

type message = string

module IncrementalUpdate : sig
  type t =
    | NewExplicit of Ast.ModulePath.t
    | NewImplicit of Ast.Reference.t
    | Delete of Ast.Reference.t
  [@@deriving show, sexp, compare, eq]
end

module ReadOnly : sig
  type t

  val controls : t -> EnvironmentControls.t

  val module_path_of_qualifier : t -> Ast.Reference.t -> Ast.ModulePath.t option

  (** NOTE(grievejia): This API is oblivious to the existence of a build system. User-facing logic
      should always prefer {!Server.PathLookup.instantiate_path} for module-to-path translation. *)
  val artifact_path_of_qualifier : t -> Ast.Reference.t -> ArtifactPath.t option

  val relative_path_of_qualifier : t -> Ast.Reference.t -> string option

  val module_path_of_artifact_path : t -> ArtifactPath.t -> Ast.ModulePath.t option

  val module_paths : t -> Ast.ModulePath.t list

  val project_qualifiers : t -> Ast.Reference.t list

  (* This function returns all explicit modules (i.e. those backed up by a source path) that are
     tracked *)
  val explicit_qualifiers : t -> Ast.Reference.t list

  val is_qualifier_tracked : t -> Ast.Reference.t -> bool

  val code_of_module_path : t -> Ast.ModulePath.t -> (raw_code, message) Result.t
end

type t

val create : EnvironmentControls.t -> t

(* This function returns all SourcePaths that are tracked, including the shadowed ones. *)
val all_module_paths : t -> Ast.ModulePath.t list

val module_paths : t -> Ast.ModulePath.t list

val controls : t -> EnvironmentControls.t

val update : t -> events:ArtifactPath.Event.t list -> IncrementalUpdate.t list

module Serializer : sig
  val store_layouts : t -> unit

  val from_stored_layouts : controls:EnvironmentControls.t -> unit -> t
end

val read_only : t -> ReadOnly.t

module Overlay : sig
  module CodeUpdate : sig
    type t =
      | NewCode of raw_code
      | ResetCode
  end

  type t

  val create : ReadOnly.t -> t

  val owns_qualifier : t -> Ast.Reference.t -> bool

  val owns_reference : t -> Ast.Reference.t -> bool

  val owns_identifier : t -> Ast.Identifier.t -> bool

  val update_overlaid_code
    :  t ->
    code_updates:(ArtifactPath.t * CodeUpdate.t) list ->
    IncrementalUpdate.t list

  val read_only : t -> ReadOnly.t
end
