(** Pretty-printer that conforms with C syntax. Also defines the grammar of
 * concrete C syntax, as opposed to our idealistic, well-formed C*. *)

open PPrint
open PrintCommon
open C

(* Pretty-printing of actual C syntax *****************************************)

let c99_macro_for_width w =
  let open Constant in
  match w with
  | UInt8  -> "UINT8_C"
  | UInt16 -> "UINT16_C"
  | UInt32 -> "UINT32_C"
  | UInt64 -> "UINT64_C"
  | Int8   -> "INT8_C"
  | Int16  -> "INT16_C"
  | Int32  -> "INT32_C"
  | Int64  -> "INT64_C"

let p_constant (w, s) =
  string (c99_macro_for_width w) ^^ lparen ^^ string s ^^ rparen

let p_storage_spec = function
  | Typedef -> string "typedef"

let p_type_spec = function
  | Int w -> print_width w ^^ string "_t"
  | Void -> string "void"
  | Named s -> string s

let p_type_declarator d =
  let rec p_noptr = function
    | Ident n ->
        string n
    | Array (d, s) ->
        p_noptr d ^^ lbracket ^^ p_constant s ^^ rbracket
    | Function (d, params) ->
        p_noptr d ^^ lparen ^^ separate_map (comma ^^ space) (fun (spec, decl) ->
          p_type_spec spec ^/^ p_any decl
        ) params ^^ rparen
    | d ->
        lparen ^^ p_any d ^^ rparen
  and p_any = function
    | Pointer d ->
        star ^^ p_any d
    | d ->
        p_noptr d
  in
  p_any d

let p_type_name (spec, decl) =
  p_type_spec spec ^/^ p_type_declarator decl

(* http:/ /en.cppreference.com/w/c/language/operator_precedence *)
let prec_of_op2 op =
  let open Constant in
  match op with
  | AddW | SubW -> failwith "[prec_of_op]: should've been desugared"
  | Add -> 4, 4, 4
  | Sub -> 4, 4, 3
  | Div -> 3, 3, 2
  | Mult -> 3, 3, 3
  | Mod -> 3, 3, 2
  | BOr -> 10, 10, 10
  | BAnd -> 8, 8, 8
  | BXor -> 9, 9, 9
  | BShiftL -> 5, 5, 4
  | BShiftR -> 5, 5, 4

(* The precedence level [curr] is the maximum precedence the current node should
 * have. If it doesn't, then it should be parenthesized. Lower numbers bind
 * tighter. *)
let paren_if curr mine doc =
  if curr < mine then
    group (lparen ^^ doc ^^ rparen)
  else
    doc

let rec p_expr curr = function
  | Op2 (op, e1, e2) ->
      let mine, left, right = prec_of_op2 op in
      let e1 = p_expr left e1 in
      let e2 = p_expr right e2 in
      paren_if curr mine (e1 ^/^ print_op op ^^ jump e2)
  | Index (e1, e2) ->
      let mine, left, right = 1, 1, 15 in
      let e1 = p_expr left e1 in
      let e2 = p_expr right e2 in
      paren_if curr mine (e1 ^^ lbracket ^^ e2 ^^ rbracket)
  | Assign (e1, e2) ->
      let mine, left, right = 14, 13, 14 in
      let e1 = p_expr left e1 in
      let e2 = p_expr right e2 in
      paren_if curr mine (e1 ^/^ equals ^/^ e2)
  | Call (e, es) ->
      let mine, left, arg = 1, 1, 15 in
      let e = p_expr left e in
      let es = separate_map (comma ^^ break 1) (p_expr arg) es in
      paren_if curr mine (e ^^ lparen ^^ es ^^ rparen)
  | Name s ->
      string s
  | Cast (t, e) ->
      let mine, right = 2, 2 in
      let e = p_expr right e in
      let t = p_type_name t in
      paren_if curr mine (lparen ^^ t ^^ rparen ^^ e)
  | Constant c ->
      p_constant c
  | _ ->
      failwith "[p_expr]: not implemented"

let p_expr = p_expr 15

let rec p_init (i: init) =
  match i with
  | Expr e ->
      p_expr e
  | Initializer inits ->
      braces_with_nesting (separate_map (comma ^^ break 1) p_init inits)

let p_decl_and_init (decl, init) =
  let init = match init with
    | Some init ->
        break 1 ^^ equals ^/^ p_init init
    | None -> empty
  in
  group (p_type_declarator decl ^^ init)

let p_declaration (spec, stor, decl_and_inits) =
  let stor = match stor with Some stor -> p_storage_spec stor ^^ break 1 | None -> empty in
  stor ^^ group (p_type_spec spec) ^/^
  group (separate_map (comma ^^ break 1) p_decl_and_init decl_and_inits)

let rec p_stmt (s: stmt) =
  (* [p_stmt] is responsible for appending [semi] and calling [group]! *)
  match s with
  | Compound stmts ->
      braces_with_nesting (separate_map hardline p_stmt stmts)
  | Expr expr ->
      group (p_expr expr ^^ semi)
  | SelectIf (e, stmt) ->
      group (string "if" ^/^ p_expr e) ^/^
      braces_with_nesting (p_stmt stmt)
  | SelectIfElse (e, s1, s2) ->
      group (string "if" ^/^ p_expr e) ^/^
      braces_with_nesting (p_stmt s1) ^/^
      string "else" ^/^
      braces_with_nesting (p_stmt s2) 
  | Return None ->
      group (string "return" ^^ semi)
  | Return (Some e) ->
      group (string "return" ^/^ p_expr e ^^ semi)
  | Decl d ->
      group (p_declaration d ^^ semi)


let p_decl_or_function (df: declaration_or_function) =
  match df with
  | Decl d ->
      group (p_declaration d ^^ semi)
  | Function (d, stmt) ->
      group (p_declaration d) ^/^ p_stmt stmt

let print_files =
  PrintCommon.print_files p_decl_or_function