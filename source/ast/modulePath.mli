(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core

module Raw : sig
  type t = {
    relative: string;
    priority: int;
  }
  [@@deriving compare, equal, hash, sexp]

  module Set : Stdlib.Set.S with type elt = t

  val create : configuration:Configuration.Analysis.t -> ArtifactPath.t -> t option

  val full_path : configuration:Configuration.Analysis.t -> t -> ArtifactPath.t
end

type t = {
  raw: Raw.t;
  qualifier: Reference.t;
  should_type_check: bool;
}
[@@deriving compare, eq, hash, sexp]

include Hashable with type t := t

val pp : Format.formatter -> t -> unit

val create : configuration:Configuration.Analysis.t -> ArtifactPath.t -> t option

val qualifier : t -> Reference.t

val raw : t -> Raw.t

val relative : t -> string

val should_type_check : t -> bool

val create_for_in_memory_scratch_project
  :  configuration:Configuration.Analysis.t ->
  relative:string ->
  should_type_check:bool ->
  t

val create_for_testing : relative:string -> should_type_check:bool -> priority:int -> t

val qualifier_from_relative_path : string -> Reference.t

val full_path : configuration:Configuration.Analysis.t -> t -> ArtifactPath.t

(* Expose for testing *)
val same_module_compare : configuration:Configuration.Analysis.t -> t -> t -> int

val is_stub : t -> bool

val is_init : t -> bool

val is_internal_path : configuration:Configuration.Analysis.t -> ArtifactPath.t -> bool

val expand_relative_import : from:Reference.t -> t -> Reference.t

val equal_raw_paths : t -> t -> bool
