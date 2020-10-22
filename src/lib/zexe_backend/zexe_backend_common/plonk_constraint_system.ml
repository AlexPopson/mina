open Sponge
open Unsigned.Size_t

module type Gate_vector_intf = sig
  open Unsigned

  type field_vector

  type t

  val create : unit -> t

  val add_raw :
       t
    -> gate_enum:int
    -> row:Unsigned.size_t
    -> lrow:Unsigned.size_t
    -> lcol:int
    -> rrow:Unsigned.size_t
    -> rcol:int
    -> orow:Unsigned.size_t
    -> ocol:int
    -> field_vector
    -> unit
end

module Row = struct
  type t = Public_input of int | After_public_input of int

  let to_absolute ~public_input_size = function
    | Public_input i ->
        Unsigned.Size_t.of_int i
    | After_public_input i ->
        Unsigned.Size_t.of_int (i + public_input_size)
end

module Gate_spec = struct
  type ('row, 'f) t =
    { gate_enum: int
    ; row: 'row
    ; lrow: 'row
    ; lcol: int
    ; rrow: 'row
    ; rcol: int
    ; orow: 'row
    ; ocol: int
    ; coeffs: 'f array }

  let map_rows t ~f =
    {t with row= f t.row; lrow= f t.lrow; rrow= f t.rrow; orow= f t.orow}
end

module Hash_state = struct
  open Core_kernel
  module H = Digestif.SHA256

  type t = H.ctx

  let digest t = Md5.digest_string H.(to_raw_string (get t))

  let empty = H.feed_string H.empty "plonk_constraint_system"
end

module Plonk_constraint = struct
  open Core_kernel

  module T = struct
    type ('v, 'f) t =
      | Basic of {l: 'f * 'v; r: 'f * 'v; o: 'f * 'v; m: 'f; c: 'f}
      | Poseidon of {state: 'v array array}
      | EC_add of {p1: 'v * 'v; p2: 'v * 'v; p3: 'v * 'v}
      | EC_scale of {state: 'v Scale_round.t array}
      | EC_endoscale of {state: 'v Endoscale_round.t array}
    [@@deriving sexp]

    let map (type a b f) (t : (a, f) t) ~(f : a -> b) =
      let fp (x, y) = (f x, f y) in
      match t with
      | Basic {l; r; o; m; c} ->
          let p (x, y) = (x, f y) in
          Basic {l= p l; r= p r; o= p o; m; c}
      | Poseidon {state} ->
          Poseidon {state= Array.map ~f:(fun x -> Array.map ~f x) state}
      | EC_add {p1; p2; p3} ->
          EC_add {p1= fp p1; p2= fp p2; p3= fp p3}
      | EC_scale {state} ->
          EC_scale {state= Array.map ~f:(fun x -> Scale_round.map ~f x) state}
      | EC_endoscale {state} ->
          EC_endoscale
            {state= Array.map ~f:(fun x -> Endoscale_round.map ~f x) state}

    let eval (type v f)
        (module F : Snarky_backendless.Field_intf.S with type t = f)
        (eval_one : v -> f) (t : (v, f) t) =
      match t with
      (* cl * vl + cr * vr + co * vo + m * vl*vr + c = 0 *)
      | Basic {l= cl, vl; r= cr, vr; o= co, vo; m; c} ->
          let vl = eval_one vl in
          let vr = eval_one vr in
          let vo = eval_one vo in
          let open F in
          let res =
            List.reduce_exn ~f:add
              [mul cl vl; mul cr vr; mul co vo; mul m (mul vl vr); c]
          in
          if not (equal zero res) then (
            Core.eprintf
              !"%{sexp:t} * %{sexp:t}\n\
                + %{sexp:t} * %{sexp:t}\n\
                + %{sexp:t} * %{sexp:t}\n\
                + %{sexp:t} * %{sexp:t}\n\
                + %{sexp:t}\n\
                = %{sexp:t}%!"
              cl vl cr vr co vo m (mul vl vr) c res ;
            false )
          else true
      | _ ->
          true

    (* TODO *)
  end

  include T
  include Snarky_backendless.Constraint.Add_kind (T)
end

module Position = struct
  type t = {row: Row.t; col: int}
end

module Internal_var = Core_kernel.Unique_id.Int ()

module V = struct
  open Core_kernel

  (*
   An external variable is one generated by snarky (via exists).

   An internal variable is one that we generate as an intermediate variable (e.g., in
   reducing linear combinations to single PLONK positions).

   Every internal variable is computable from a finite list of
   external variables and internal variables. 

   Currently, in fact, every internal variable is a linear combination of
   external variables and previously generated internal variables.
*)

  module T = struct
    type t = External of int | Internal of Internal_var.t
    [@@deriving compare, hash, sexp]
  end

  include T
  include Comparable.Make (T)
  include Hashable.Make (T)
end

type ('a, 'f) t =
  { equivalence_classes: Position.t list V.Table.t
        (* How to compute each internal variable (as a linaer combination of other variables) *)
  ; internal_vars: (('f * V.t) list * 'f option) Internal_var.Table.t
  ; mutable rows_rev: V.t option array list
  ; mutable gates:
      [`Finalized | `Unfinalized_rev of (Row.t, 'f) Gate_spec.t list]
  ; mutable next_row: int
  ; mutable hash: Hash_state.t
  ; mutable constraints: int
  ; public_input_size: int Core_kernel.Set_once.t
  ; mutable auxiliary_input_size: int }

module Hash = Core.Md5

let digest (t : _ t) = Hash_state.digest t.hash

module Make (Fp : sig
  include Field.S

  val to_bigint_raw_noalloc : t -> Bigint.t
end)
(Gates : Gate_vector_intf with type field_vector := Fp.Vector.t) (Params : sig
    val params : Fp.t Params.t
end) =
struct
  open Core
  open Pickles_types

  type nonrec t = (Gates.t, Fp.t) t

  module H = Digestif.SHA256

  let feed_constraint t constr =
    let fp =
      let n = Fp.Bigint.length_in_bytes in
      let fp_buf = Bytes.init n ~f:(fun _ -> '\000') in
      fun x acc ->
        let limbs = Fp.Bigint.to_ptr (Fp.to_bigint_raw_noalloc x) in
        for i = 0 to n - 1 do
          Bytes.set fp_buf i Ctypes.(!@(limbs +@ i))
        done ;
        H.feed_bytes acc fp_buf
    in
    let lc =
      let int_buf = Bytes.init 8 ~f:(fun _ -> '\000') in
      fun x t ->
        List.fold x ~init:t ~f:(fun acc (x, index) ->
            let acc = fp x acc in
            for i = 0 to 7 do
              Bytes.set int_buf i
                (Char.of_int_exn ((index lsr (8 * i)) land 255))
            done ;
            H.feed_bytes acc int_buf )
    in
    let cvars xs =
      List.concat_map xs ~f:(fun x ->
          let c, ts =
            Fp.(
              Snarky_backendless.Cvar.to_constant_and_terms x ~equal ~add ~mul
                ~zero ~one)
          in
          Option.value_map c ~default:[] ~f:(fun c -> [(c, 0)]) @ ts )
      |> lc
    in
    match constr with
    | Snarky_backendless.Constraint.Equal (v1, v2) ->
        let t = H.feed_string t "equal" in
        cvars [v1; v2] t
    | Snarky_backendless.Constraint.Boolean b ->
        let t = H.feed_string t "boolean" in
        cvars [b] t
    | Snarky_backendless.Constraint.Square (x, z) ->
        let t = H.feed_string t "square" in
        cvars [x; z] t
    | Snarky_backendless.Constraint.R1CS (a, b, c) ->
        let t = H.feed_string t "r1cs" in
        cvars [a; b; c] t
    | Plonk_constraint.T constr -> (
      match constr with
      | Basic {l; r; o; m; c} ->
          let t = H.feed_string t "basic" in
          let pr (s, x) acc = fp s acc |> cvars [x] in
          t |> pr l |> pr r |> pr o |> fp m |> fp c
      | Poseidon {state} ->
          let t = H.feed_string t "poseidon" in
          let row a = cvars (Array.to_list a) in
          Array.fold state ~init:t ~f:(fun acc a -> row a acc)
      | EC_add {p1; p2; p3} ->
          let t = H.feed_string t "ec_add" in
          let pr (x, y) = cvars [x; y] in
          t |> pr p1 |> pr p2 |> pr p3
      | EC_scale {state} ->
          let t = H.feed_string t "ec_scale" in
          Array.fold state ~init:t
            ~f:(fun acc {xt; b; yt; xp; l1; yp; xs; ys} ->
              cvars [xt; b; yt; xp; l1; yp; xs; ys] acc )
      | EC_endoscale {state} ->
          let t = H.feed_string t "ec_endoscale" in
          Array.fold state ~init:t
            ~f:(fun acc {b2i1; xt; b2i; xq; yt; xp; l1; yp; xs; ys} ->
              cvars [b2i1; xt; b2i; xq; yt; xp; l1; yp; xs; ys] acc ) )
    | _ ->
        failwith "Unsupported constraint"

  let compute_witness sys (external_values : int -> Fp.t) : Fp.t array array =
    let internal_values : Fp.t Internal_var.Table.t =
      Internal_var.Table.create ()
    in
    let public_input_size = Set_once.get_exn sys.public_input_size [%here] in
    let num_rows = public_input_size + sys.next_row in
    let res = Array.init num_rows ~f:(fun _ -> Array.create ~len:3 Fp.zero) in
    for i = 0 to public_input_size - 1 do
      res.(i).(0) <- external_values (i + 1)
    done ;
    let find t k =
      match Hashtbl.find t k with
      | None ->
          failwithf !"Could not find %{sexp:Internal_var.t}\n%!" k ()
      | Some x ->
          x
    in
    let compute ((lc, c) : (Fp.t * V.t) list * Fp.t option) =
      List.fold lc ~init:(Option.value c ~default:Fp.zero)
        ~f:(fun acc (s, x) ->
          let x =
            match x with
            | External x ->
                external_values x
            | Internal x ->
                find internal_values x
          in
          Fp.(acc + (s * x)) )
    in
    List.iteri (List.rev sys.rows_rev) ~f:(fun i_after_input row ->
        let i = i_after_input + public_input_size in
        Array.iteri row ~f:(fun j v ->
            match v with
            | None ->
                ()
            | Some (External v) ->
                res.(i).(j) <- external_values v
            | Some (Internal v) ->
                let lc = find sys.internal_vars v in
                let value = compute lc in
                res.(i).(j) <- value ;
                Hashtbl.set internal_values ~key:v ~data:value ) ) ;
    res

  let create_internal ?constant sys lc : V.t =
    let v = Internal_var.create () in
    Hashtbl.add_exn sys.internal_vars ~key:v ~data:(lc, constant) ;
    V.Internal v

  let digest t = Hash_state.digest t.hash

  let create () =
    { public_input_size= Set_once.create ()
    ; internal_vars= Internal_var.Table.create ()
    ; gates= `Unfinalized_rev [] (* Gates.create () *)
    ; rows_rev= []
    ; next_row= 0
    ; equivalence_classes= V.Table.create ()
    ; hash= Hash_state.empty
    ; constraints= 0
    ; auxiliary_input_size= 0 }

  (* TODO *)
  let to_json _ = `List []

  let get_auxiliary_input_size t = t.auxiliary_input_size

  let get_primary_input_size t = Set_once.get_exn t.public_input_size [%here]

  let set_auxiliary_input_size t x = t.auxiliary_input_size <- x

  let set_primary_input_size t x =
    Set_once.set_exn t.public_input_size [%here] x

  let digest = digest

  let wire' sys key row col =
    let prev =
      match V.Table.find sys.equivalence_classes key with
      | Some x -> (
        match List.hd x with Some x -> x | None -> {row; col} )
      | None ->
          {row; col}
    in
    V.Table.add_multi sys.equivalence_classes ~key ~data:{row; col} ;
    prev

  let wire sys key row col = wire' sys key (Row.After_public_input row) col

  let finalize_and_get_gates sys =
    match sys.gates with
    | `Finalized ->
        failwith "Already finalized"
    | `Unfinalized_rev gates ->
        let g = Gates.create () in
        let n = Set_once.get_exn sys.public_input_size [%here] in
        (* First, add gates for public input *)
        let pub = [|Fp.one; Fp.zero; Fp.zero; Fp.zero; Fp.zero|] in
        let pub_input_gate_specs_rev = ref [] in
        for row = 0 to n - 1 do
          let lp = wire' sys (V.External (row + 1)) (Row.Public_input row) 0 in
          let lp_row = Row.to_absolute ~public_input_size:n lp.row in
          (* Add to the gate vector *)
          let row = Unsigned.Size_t.of_int row in
          pub_input_gate_specs_rev :=
            { Gate_spec.gate_enum= 1
            ; row
            ; lrow= lp_row
            ; lcol= lp.col
            ; rrow= row
            ; rcol= 1
            ; orow= row
            ; ocol= 2
            ; coeffs= pub }
            :: !pub_input_gate_specs_rev
        done ;
        let offset_row = Row.to_absolute ~public_input_size:n in
        let all_gates =
          List.rev_append !pub_input_gate_specs_rev
            (List.rev_map ~f:(Gate_spec.map_rows ~f:offset_row) gates)
        in
        List.iter all_gates
          ~f:(fun {gate_enum; row; lrow; lcol; rrow; rcol; orow; ocol; coeffs}
             ->
            Gates.add_raw g ~gate_enum ~row ~lrow ~lcol ~rrow ~rcol ~orow ~ocol
              (Fp.Vector.of_array coeffs) ) ;
        g

  let finalize t = ignore (finalize_and_get_gates t)

  let accumulate_sorted_terms (c0, i0) terms =
    Sequence.of_list terms
    |> Sequence.fold ~init:(c0, i0, [], 0) ~f:(fun (acc, i, ts, n) (c, j) ->
           if Int.equal i j then (Fp.add acc c, i, ts, n)
           else (c, j, (acc, i) :: ts, n + 1) )

  let canonicalize x =
    let c, terms =
      Fp.(
        Snarky_backendless.Cvar.to_constant_and_terms ~add ~mul
          ~zero:(of_int 0) ~equal ~one:(of_int 1))
        x
    in
    let terms =
      List.sort terms ~compare:(fun (_, i) (_, j) -> Int.compare i j)
    in
    let has_constant_term = Option.is_some c in
    let terms = match c with None -> terms | Some c -> (c, 0) :: terms in
    match terms with
    | [] ->
        Some ([], 0, false)
    | t0 :: terms ->
        let acc, i, ts, n = accumulate_sorted_terms t0 terms in
        Some (List.rev ((acc, i) :: ts), n + 1, has_constant_term)

  open Position

  let add_row sys row t l r o c =
    match sys.gates with
    | `Finalized ->
        failwith "add_row called on finalized constraint system"
    | `Unfinalized_rev gates ->
        sys.gates
        <- `Unfinalized_rev
             ( { gate_enum= t
               ; row= After_public_input sys.next_row
               ; lrow= l.row
               ; lcol= l.col
               ; rrow= r.row
               ; rcol= r.col
               ; orow= o.row
               ; ocol= o.col
               ; coeffs= c }
             :: gates ) ;
        sys.next_row <- sys.next_row + 1 ;
        sys.rows_rev <- row :: sys.rows_rev

  let add_generic_constraint ?l ?r ?o c sys : unit =
    let next_row = sys.next_row in
    let lp =
      match l with
      | Some lx ->
          wire sys lx next_row 0
      | None ->
          {row= After_public_input next_row; col= 0}
    in
    let rp =
      match r with
      | Some rx ->
          wire sys rx next_row 1
      | None ->
          {row= After_public_input next_row; col= 1}
    in
    let op =
      match o with
      | Some ox ->
          wire sys ox next_row 2
      | None ->
          {row= After_public_input next_row; col= 2}
    in
    add_row sys [|l; r; o|] 1 lp rp op c

  let completely_reduce sys (terms : (Fp.t * int) list) =
    (* just adding constrained variables without values *)
    let rec go = function
      | [] ->
          assert false
      | [(s, x)] ->
          (s, V.External x)
      | (ls, lx) :: t ->
          let lx = V.External lx in
          let rs, rx = go t in
          let s1x1_plus_s2x2 = create_internal sys [(ls, lx); (rs, rx)] in
          add_generic_constraint ~l:lx ~r:rx ~o:s1x1_plus_s2x2
            [|ls; rs; Fp.(negate one); Fp.zero; Fp.zero|]
            sys ;
          (Fp.one, s1x1_plus_s2x2)
    in
    go terms

  let reduce_lincom sys (x : Fp.t Snarky_backendless.Cvar.t) =
    let constant, terms =
      Fp.(
        Snarky_backendless.Cvar.to_constant_and_terms ~add ~mul
          ~zero:(of_int 0) ~equal ~one:(of_int 1))
        x
    in
    let terms =
      List.sort terms ~compare:(fun (_, i) (_, j) -> Int.compare i j)
    in
    match (constant, terms) with
    | Some c, [] ->
        (c, `Constant)
    | None, [] ->
        (Fp.zero, `Constant)
    | _, t0 :: terms -> (
        let terms =
          let acc, i, ts, _ = accumulate_sorted_terms t0 terms in
          List.rev ((acc, i) :: ts)
        in
        match terms with
        | [] ->
            assert false
        | [(ls, lx)] -> (
          match constant with
          | None ->
              (ls, `Var (V.External lx))
          | Some c ->
              (* res = ls * lx + c *)
              let res = create_internal ~constant:c sys [(ls, External lx)] in
              add_generic_constraint ~l:(External lx) ~o:res
                [|ls; Fp.zero; Fp.(negate one); Fp.zero; c|]
                (* Could be here *)
                sys ;
              (Fp.one, `Var res) )
        | (ls, lx) :: tl ->
            let rs, rx = completely_reduce sys tl in
            let res =
              create_internal ?constant sys [(ls, External lx); (rs, rx)]
            in
            (* res = ls * lx + rs * rx + c *)
            add_generic_constraint ~l:(External lx) ~r:rx ~o:res
              [| ls
               ; rs
               ; Fp.(negate one)
               ; Fp.zero
               ; (match constant with Some x -> x | None -> Fp.zero) |]
              (* Could be here *)
              sys ;
            (Fp.one, `Var res) )

  let add_constraint ?label:_ sys
      (constr :
        ( Fp.t Snarky_backendless.Cvar.t
        , Fp.t )
        Snarky_backendless.Constraint.basic) =
    sys.hash <- feed_constraint sys.hash constr ;
    let red = reduce_lincom sys in
    let reduce_to_v (x : Fp.t Snarky_backendless.Cvar.t) : V.t =
      let s, x = red x in
      match x with
      | `Var x ->
          if Fp.equal s Fp.one then x
          else
            let sx = create_internal sys [(s, x)] in
            (* s * x - sx = 0 *)
            add_generic_constraint ~l:x ~o:sx
              [|s; Fp.zero; Fp.(negate one); Fp.zero; Fp.zero|]
              sys ;
            sx
      | `Constant ->
          let x = create_internal sys ~constant:s [] in
          add_generic_constraint ~l:x
            [|Fp.one; Fp.zero; Fp.zero; Fp.zero; Fp.negate s|]
            sys ;
          x
    in
    match constr with
    | Snarky_backendless.Constraint.Square (v1, v2) -> (
        let (sl, xl), (so, xo) = (red v1, red v2) in
        match (xl, xo) with
        | `Var xl, `Var xo ->
            (* (sl * xl)^2 = so * xo
               sl^2 * xl * xl - so * xo = 0
            *)
            add_generic_constraint ~l:xl ~r:xl ~o:xo
              [|Fp.zero; Fp.zero; Fp.negate so; Fp.(sl * sl); Fp.zero|]
              sys
        | `Var xl, `Constant ->
            add_generic_constraint ~l:xl ~r:xl
              [|Fp.zero; Fp.zero; Fp.zero; Fp.(sl * sl); Fp.negate so|]
              sys
        | `Constant, `Var xo ->
            (* sl^2 = so * xo *)
            add_generic_constraint ~o:xo
              [|Fp.zero; Fp.zero; so; Fp.zero; Fp.negate (Fp.square sl)|]
              sys
        | `Constant, `Constant ->
            assert (Fp.(equal (square sl) so)) )
    | Snarky_backendless.Constraint.R1CS (v1, v2, v3) -> (
        let (s1, x1), (s2, x2), (s3, x3) = (red v1, red v2, red v3) in
        match (x1, x2, x3) with
        | `Var x1, `Var x2, `Var x3 ->
            (* s1 x1 * s2 x2 = s3 x3
               - s1 s2 (x1 x2) + s3 x3 = 0
            *)
            add_generic_constraint ~l:x1 ~r:x2 ~o:x3
              [|Fp.zero; Fp.zero; s3; Fp.(negate s1 * s2); Fp.zero|]
              sys
        | `Var x1, `Var x2, `Constant ->
            add_generic_constraint ~l:x1 ~r:x2
              [|Fp.zero; Fp.zero; Fp.zero; Fp.(s1 * s2); Fp.negate s3|]
              sys
        | `Var x1, `Constant, `Var x3 ->
            (* s1 x1 * s2 = s3 x3
            *)
            add_generic_constraint ~l:x1 ~o:x3
              [|Fp.(s1 * s2); Fp.zero; Fp.negate s3; Fp.zero; Fp.zero|]
              sys
        | `Constant, `Var x2, `Var x3 ->
            add_generic_constraint ~r:x2 ~o:x3
              [|Fp.zero; Fp.(s1 * s2); Fp.negate s3; Fp.zero; Fp.zero|]
              sys
        | `Var x1, `Constant, `Constant ->
            add_generic_constraint ~l:x1
              [|Fp.(s1 * s2); Fp.zero; Fp.zero; Fp.zero; Fp.negate s3|]
              sys
        | `Constant, `Var x2, `Constant ->
            add_generic_constraint ~r:x2
              [|Fp.zero; Fp.(s1 * s2); Fp.zero; Fp.zero; Fp.negate s3|]
              sys
        | `Constant, `Constant, `Var x3 ->
            add_generic_constraint ~o:x3
              [|Fp.zero; Fp.zero; s3; Fp.zero; Fp.(negate s1 * s2)|]
              sys
        | `Constant, `Constant, `Constant ->
            assert (Fp.(equal s3 Fp.(s1 * s2))) )
    | Snarky_backendless.Constraint.Boolean v -> (
        let s, x = red v in
        match x with
        | `Var x ->
            (* -x + x * x = 0  *)
            add_generic_constraint ~l:x ~r:x
              [|Fp.(negate one); Fp.zero; Fp.zero; Fp.one; Fp.zero|]
              sys
        | `Constant ->
            assert (Fp.(equal s (s * s))) )
    | Snarky_backendless.Constraint.Equal (v1, v2) -> (
        let (s1, x1), (s2, x2) = (red v1, red v2) in
        match (x1, x2) with
        | `Var x1, `Var x2 ->
            (* s1 x1 - s2 x2 = 0
          *)
            if s1 <> s2 then
              add_generic_constraint ~l:x1 ~r:x2
                [|s1; Fp.(negate s2); Fp.zero; Fp.zero; Fp.zero|]
                sys
              (* TODO: optimize by not adding generic costraint but rather permuting the vars *)
            else
              add_generic_constraint ~l:x1 ~r:x2
                [|s1; Fp.(negate s2); Fp.zero; Fp.zero; Fp.zero|]
                sys
        | `Var x1, `Constant ->
            add_generic_constraint ~l:x1
              [|s1; Fp.zero; Fp.zero; Fp.zero; Fp.negate s2|]
              sys
        | `Constant, `Var x2 ->
            add_generic_constraint ~r:x2
              [|Fp.zero; s2; Fp.zero; Fp.zero; Fp.negate s1|]
              sys
        | `Constant, `Constant ->
            assert (Fp.(equal s1 s2)) )
    | Plonk_constraint.T (Basic {l; r; o; m; c}) ->
        (* 0
         = l.s * l.x 
         + r.s * r.x 
         + o.s * o.x 
         + m * (l.x * r.x)
         + c
         = 
           l.s * l.s' * l.x'
         + r.s * r.s' * r.x' 
         + o.s * o.s' * o.x' 
         + m * (l.s' * l.x' * r.s' * r.x')
         + c
         = 
           (l.s * l.s') * l.x'
         + (r.s * r.s') * r.x' 
         + (o.s * o.s') * o.x' 
         + (m * l.s' * r.s') * l.x' r.x'
         + c
      *)
        (* TODO: This is sub-optimal *)
        let c = ref c in
        let red_pr (s, x) =
          match red x with
          | s', `Constant ->
              c := Fp.add !c Fp.(s * s') ;
              (* No need to have a real term. *)
              (s', None)
          | s', `Var x ->
              (s', Some (Fp.(s * s'), x))
        in
        (* l.s * l.x 
         + r.s * r.x 
         + o.s * o.x 
         + m * (l.x * r.x)
         + c
         = 
           l.s * l.s' * l.x'
         + r.s * r.x 
         + o.s * o.x 
         + m * (l.x * r.x)
         + c
         = 
        *)
        let l_s', l = red_pr l in
        let r_s', r = red_pr r in
        let _, o = red_pr o in
        let var = Option.map ~f:snd in
        let coeff = Option.value_map ~default:Fp.zero ~f:fst in
        let m =
          match (l, r) with
          | Some _, Some _ ->
              Fp.(l_s' * r_s' * m)
          | _ ->
              (* TODO: Figure this out later. *)
              failwith "Must use non-constant cvar in plonk constraints"
        in
        add_generic_constraint ?l:(var l) ?r:(var r) ?o:(var o)
          [|coeff l; coeff r; coeff o; m; !c|]
          sys
    | Plonk_constraint.T (Poseidon {state}) ->
        let reduce_state sys (s : Fp.t Snarky_backendless.Cvar.t array array) :
            V.t array array =
          Array.map ~f:(Array.map ~f:reduce_to_v) s
        in
        let state = reduce_state sys state in
        let add_round_state array ind =
          let prev =
            Array.mapi array ~f:(fun i x -> wire sys x sys.next_row i)
          in
          add_row sys
            (Array.map array ~f:(fun x -> Some x))
            2 prev.(0) prev.(1) prev.(2)
            Params.params.round_constants.(ind + 1)
        in
        Array.iteri
          ~f:(fun i perm ->
            if i = Array.length state - 1 then
              let prev =
                Array.mapi perm ~f:(fun i x -> wire sys x sys.next_row i)
              in
              add_row sys
                (Array.map perm ~f:(fun x -> Some x))
                0 prev.(0) prev.(1) prev.(2)
                [|Fp.zero; Fp.zero; Fp.zero; Fp.zero; Fp.zero|]
            else add_round_state perm i )
          state
    | Plonk_constraint.T (EC_add {p1; p2; p3}) ->
        let red =
          Array.map [|p1; p2; p3|] ~f:(fun (x, y) ->
              (reduce_to_v x, reduce_to_v y) )
        in
        let y =
          Array.mapi ~f:(fun i (x, y) -> wire sys y sys.next_row i) red
        in
        add_row sys
          (Array.map red ~f:(fun (_, y) -> Some y))
          3 y.(0) y.(1) y.(2) [||] ;
        let x =
          Array.mapi ~f:(fun i (x, y) -> wire sys x sys.next_row i) red
        in
        add_row sys
          (Array.map red ~f:(fun (x, _) -> Some x))
          4 x.(0) x.(1) x.(2) [||] ;
        ()
    | Plonk_constraint.T (EC_scale {state}) ->
        let i = ref 0 in
        let add_ecscale_round (round : V.t Scale_round.t) =
          let xt = wire sys round.xt sys.next_row 0 in
          let b = wire sys round.b sys.next_row 1 in
          let yt = wire sys round.yt sys.next_row 2 in
          let xp = wire sys round.xp (sys.next_row + 1) 0 in
          let l1 = wire sys round.l1 (sys.next_row + 1) 1 in
          let yp = wire sys round.yp (sys.next_row + 1) 2 in
          let xs = wire sys round.xs (sys.next_row + 2) 0 in
          let xt1 = wire sys round.xt (sys.next_row + 2) 1 in
          let ys = wire sys round.ys (sys.next_row + 2) 2 in
          add_row sys
            [|Some round.xt; Some round.b; Some round.yt|]
            5 xt b yt [||] ;
          add_row sys
            [|Some round.xp; Some round.l1; Some round.yp|]
            6 xp l1 yp [||] ;
          add_row sys
            [|Some round.xs; Some round.xt; Some round.ys|]
            7 xs xt1 ys [||]
        in
        Array.iter
          ~f:(fun round -> add_ecscale_round round ; incr i)
          (Array.map state ~f:(Scale_round.map ~f:reduce_to_v)) ;
        ()
    | Plonk_constraint.T (EC_endoscale {state}) ->
        let add_endoscale_round (round : V.t Endoscale_round.t) =
          let b2i1 = wire sys round.b2i1 sys.next_row 0 in
          let xt = wire sys round.xt sys.next_row 1 in
          let b2i = wire sys round.b2i (sys.next_row + 1) 0 in
          let xq = wire sys round.xq (sys.next_row + 1) 1 in
          let yt = wire sys round.yt (sys.next_row + 1) 2 in
          let xp = wire sys round.xp (sys.next_row + 2) 0 in
          let l1 = wire sys round.l1 (sys.next_row + 2) 1 in
          let yp = wire sys round.yp (sys.next_row + 2) 2 in
          let xs = wire sys round.xs (sys.next_row + 3) 0 in
          let xq1 = wire sys round.xq (sys.next_row + 3) 1 in
          let ys = wire sys round.ys (sys.next_row + 3) 2 in
          add_row sys
            [|Some round.b2i1; Some round.xt; None|]
            8 b2i1 xt
            {row= After_public_input sys.next_row; col= 3}
            [||] ;
          add_row sys
            [|Some round.b2i; Some round.xq; Some round.yt|]
            9 b2i xq yt [||] ;
          add_row sys
            [|Some round.xp; Some round.l1; Some round.yp|]
            10 xp l1 yp [||] ;
          add_row sys
            [|Some round.xs; Some round.xq; Some round.ys|]
            11 xs xq1 ys [||]
        in
        Array.iter
          ~f:(fun round -> add_endoscale_round round)
          (Array.map state ~f:(Endoscale_round.map ~f:reduce_to_v)) ;
        ()
    | constr ->
        failwithf "Unhandled constraint %s"
          Obj.(extension_name (extension_constructor constr))
          ()
end
