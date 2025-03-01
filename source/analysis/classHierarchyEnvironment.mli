(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open SharedMemoryKeys

module HierarchyReadOnly : sig
  include Environment.ReadOnly

  val get_edges
    :  t ->
    ?dependency:DependencyKey.registered ->
    Ast.Identifier.t ->
    ClassHierarchy.Edges.t option

  val alias_environment : t -> AliasEnvironment.ReadOnly.t

  val class_hierarchy : ?dependency:DependencyKey.registered -> t -> (module ClassHierarchy.Handler)

  val type_parameters_as_variables
    :  t ->
    ?dependency:DependencyKey.registered ->
    ?default:Type.Variable.t list option ->
    Type.Primitive.t ->
    Type.Variable.t list option
end

include
  Environment.S
    with module ReadOnly = HierarchyReadOnly
     and module PreviousEnvironment = AliasEnvironment

(* Exposed for testing purpose only *)
val compute_generic_base : Type.t list -> Type.t option
