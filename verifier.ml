open Why3api
open Why3util
open Vc
open Vcg
open Utils
open Print
open ExtList

let print_exn_flag = ref false
let print_task_style = ref "full"
let prove_flag = ref true
let trans_flag = ref true
let default_timelimit = ref 1
let default_memlimit = ref 4000
let interactive_flag = ref false
let inline_assignment = ref true
let print_size_flag = ref false
let parse_only_flag = ref false

let decl_size { Why3.Theory.td_node = n } =
  match n with
  | Why3.Theory.Decl { Why3.Decl.d_node = d } ->
     begin
       (* count only lemma, axiom, goal, and skip *)
       match d with
       | Why3.Decl.Dprop (_, _, t) -> t_size t
       | _ -> 0
     end
  | _ -> 0

let task_size task =
  Why3.Task.task_fold (fun n td -> n + decl_size td) 0 task

(* ---------------- cuda program file -> Cil *)

let parse_file filename =
  let f = Frontc.parse filename () in
  Rmtmps.removeUnusedTemps f;
  f

let find_decl file name =
  let rec find = function
    | Cil.GFun (dec, _) :: rest when dec.Cil.svar.Cil.vname = name ->
       dec
    | _ :: rest -> find rest
    | [] -> raise Not_found
  in find file.Cil.globals


(* ---------------- transform task *)
type task_tree =
  | TTLeaf of Why3.Task.task
  | TTAnd of task_tree list
  | TTOr of task_tree list
  | TTSuccess                   (* no more task to solve *)
  | TTFail                      (* unsolvable task; currently there is
                                 * no possibilty of arising this during
                                 * verification process,
                                 * because we use no refutation
                                 * procedure. *)

let rec repeat_on_term f t =
  let t' = f t in
  if Why3.Term.t_equal t t' then t else repeat_on_term f t'

let tt_and = function
  | [] -> TTSuccess
  | [tt] -> tt
  | tts -> TTAnd tts

let tt_or = function
  | [] -> invalid_arg "tt_or, empty list"
  | [tt] -> tt
  | tts -> TTOr tts

let rec reduce_task_tree = function
  | TTLeaf _ as tt -> tt
  | TTAnd [] -> TTSuccess
  | TTOr [] -> TTFail
  | TTAnd [tt]
  | TTOr [tt] -> reduce_task_tree tt
  | TTAnd tts ->
     let tts' = List.map reduce_task_tree tts in
     if List.mem TTFail tts' then TTFail
     else tt_and @@ List.remove_all tts' TTSuccess
  | TTOr tts ->
     let tts' = List.map reduce_task_tree tts in
     if List.mem TTSuccess tts' then TTSuccess
     else tt_or @@ List.remove_all tts' TTFail
  | TTSuccess -> TTSuccess
  | TTFail -> TTFail

let simplify_task task =
  let tasks =
    (* common simplification *)
    task
    |> Vctrans.rewrite_using_premises
    (* |> List.map @@ (task_map_decl simplify_formula) *)
    |> List.map @@
         (task_map_decl (repeat_on_term Vctrans.decompose_thread_quant))
    |> List.map @@ Vctrans.rewrite_using_simple_premises
    |> List.concat
    |> List.map @@ apply_why3trans "split_goal_right"
    |> List.concat
  (* |> List.map @@ (task_map_decl simplify_formula) *)
  in
  let simplify task =
    let tt1 =
      (* merge -> qe *)
      task
      |> task_map_decl (repeat_on_term Vctrans.merge_quantifiers)
      |> Vctrans.eliminate_linear_quantifier
      |> task_map_decl simplify_formula
      |> Vctrans.simplify_affine_formula
      |> apply_why3trans "compute_specified"
      |> List.map (fun x -> TTLeaf x)
    in
    let tt2 =
      (* no merging, only affine expression simplification *)
      task
      |> Vctrans.simplify_affine_formula
      |> Vctrans.eliminate_linear_quantifier
      |> task_map_decl simplify_formula
      |> apply_why3trans "compute_specified"
      |> List.map (fun x -> TTLeaf x)
    in
    TTOr [TTAnd tt1; TTAnd tt2]
  in
  TTAnd (List.map simplify tasks) |> reduce_task_tree

let prover_name_list = ["alt-ergo"; "cvc3"; "cvc4"; "z3"; "eprover"]

let kill_prover_calls pcs =
  List.iter
    (fun (_, p) ->
     match Why3.Call_provers.query_call p with
     | None ->
        Unix.kill (Why3.Call_provers.prover_call_pid p) Sys.sigterm;
        (* this cleanups temporary files; better way to do this? *)
        ignore @@ Why3.Call_provers.wait_on_call p ()
     | Some postpc -> ignore @@ postpc ())
    pcs

exception Finished

let try_prove_task ?(provers=prover_name_list)
                   ?(timelimit=(!default_timelimit))
                   ?(memlimit=(!default_memlimit)) task =
  let pcs = List.map
              (fun name ->
               let pcall = prove_task ~timelimit ~memlimit name task () in
               name, pcall)
              provers
  in
  let filter_finished pcs =
    let rec f pcs finished running = match pcs with
      | [] -> finished, running
      | pc :: pcs' ->
         match Why3.Call_provers.query_call @@ snd pc  with
         | None -> f pcs' finished (pc :: running)
         | Some r -> f pcs' ((fst pc, r ()) :: finished) running
    in f pcs [] []
  in
  let rec check pcs =
    let finished, running = filter_finished pcs in
    List.iter (fun (name, result) ->
               print_result name result;
               (* for debugging; print task if inconsistent assumption
                   is reported *)
               if Str.string_match (Str.regexp "Inconsistent assumption")
                                   result.Why3.Call_provers.pr_output 0
               then
                 (Format.printf "Task with inconsistent assumption:@.";
                  print_task_short task None);
               if result.Why3.Call_provers.pr_answer = Why3.Call_provers.Valid
               then
                 begin
                   (* The task has already been proved.
                    * We don't need to run other provers on this task any more,
                    * so try to kill the processes. *)
                   kill_prover_calls running;
                   raise Finished
                 end)
              finished;
    if running = [] then false
    else
      (* wait for a while and try again  *)
      (* (Unix.select [] [] [] 0.1; check running) *)
      (* (Unix.sleep 1; check running) *)
      (* (ignore @@ Unix.system "sleep 0.1"; check running) *)
      (Unix.sleepf 0.1; check running)
  in
  Format.printf "Calling provers...@.";
  try check pcs with Finished -> true

let generate_task filename funcname =
  let file = parse_file filename in
  debug "parsed file %s" filename;
  let fdecl = find_decl file funcname in
  if !parse_only_flag then
    begin
      Cil.printCilAsIs := true;
      let sep = String.make 70 '=' in
      ignore @@ Pretty.printf "%s@!Parser output:@!%a@!%s@!"
                              sep Cil.d_block fdecl.Cil.sbody sep;
      exit 0
    end;
  let vcs = generate_vc file fdecl in
  let tasks = List.map (fun vc ->
                        Taskgen.task_of_vc !inline_assignment vc)
                       vcs in
  tasks

let print_task_size tasks =
  let sizes = List.map task_size tasks in
  List.iteri (fun i n ->
              Format.printf "Task #%d has size %d@."
                            (i + 1) n)
             sizes;
  Format.printf "Total size %d@." @@
    List.fold_left (+) 0 sizes

(* let rec tree_map fn tree =
 *   match tree with
 *   | TTLeaf t -> fn t
 *   | TTAnd tts -> TTAnd (List.map (tree_map fn) tts)
 *   | TTOr tts -> TTOr (List.map (tree_map fn) tts)
 *   | TTSuccess
 *   | TTFail -> tree *)

let rec try_on_task_tree prove = function
  | TTLeaf t as tree -> if prove t then TTSuccess else tree
  | TTAnd tts ->
     List.map (try_on_task_tree prove) tts
     |> List.filter ((=) TTSuccess)
     |> (function [] -> TTSuccess | [tt] -> tt | tts' -> TTAnd tts')
  | TTOr tts ->
     (* Refrain from using List functions to avoid eagerly trying to
      * prove all the tasks in [tts]: solving one of them suffices. *)
     let rec try_any tts acc =
       (* Returns empty list if some of the subtree is proved. *)
       match tts with
       | [] ->
          begin
            match acc with
            (* Note: the case of nil does not mean `no more options,
             * hence this attempt failed'.  *)
            | [] -> TTFail
            | [tt] -> tt
            | _ -> TTOr (List.rev acc) (* original order *)
          end
       | tt :: tts' ->
          let tt' = try_on_task_tree prove tt in
          (* Success if one of them is solved *)
          if tt' = TTSuccess then TTSuccess
          else try_any tts' (tt' :: acc)
     in
     try_any tts []
  | TTSuccess -> TTSuccess
  | TTFail -> TTFail

let rec print_task_list tasks =
  let print task =
    if !print_task_style = "full" then
      begin
        Format.printf "Unsolved task: #%d:@." (Why3.Task.task_hash task);
        print_task_full task None
      end
    else if !print_task_style = "short" then
      begin
        Format.printf "Unsolved task: #%d:@." (Why3.Task.task_hash task);
        print_task_short task None
      end
  in
  List.iter print tasks

let rec print_task_tree tt =
  let rec pp_structure fmt tt =
    match tt with
    | TTSuccess -> Format.pp_print_string fmt "<proved>"
    | TTFail -> assert false
    | TTLeaf task -> Format.pp_print_int fmt (Why3.Task.task_hash task)
    | TTAnd tts ->
       Format.printf "(And %a)"
                     (Format.pp_print_list
                        ~pp_sep:(fun f _ -> Format.pp_print_string f " ")
                        pp_structure)
                     tts
    | TTOr tts ->
       Format.printf "(Or %a)"
                     (Format.pp_print_list
                        ~pp_sep:(fun f _ -> Format.pp_print_string f " ")
                        pp_structure)
                     tts
  in
  Format.printf "%a@." pp_structure tt

let rec task_tree_count = function
  | TTSuccess
  | TTFail -> 0
  | TTLeaf _ -> 1
  | TTAnd tts -> List.length tts
  | TTOr tts -> 1

let verify_spec filename funcname =
  let tasks = generate_task filename funcname in
  Format.printf "%d tasks (before simp.)@." (List.length tasks);
  let tt =
    if !trans_flag then tt_and (List.map simplify_task tasks)
    else tt_and (List.map (fun x -> TTLeaf x) tasks)
  in
  Format.printf "%d tasks (after simp.)@." (task_tree_count tt);
  print_task_tree tt;
  (* if !print_size_flag then print_task_size tasks; *)
  if !prove_flag then
    let tt' =
      try_on_task_tree (fun t -> try_prove_task ~timelimit:1 t) tt
    in
    debug "eliminating mk_dim3...@.";
    let tt' = try_on_task_tree
                (fun t ->
                 Vctrans.eliminate_ls Why3api.fs_mk_dim3 t
                 |> task_map_decl simplify_formula
                 |> Vctrans.eliminate_linear_quantifier
                 |> task_map_decl simplify_formula
                 |> apply_why3trans "compute_specified"
                 (* |> List.map (fun t -> print_task_short t None; t) *)
                 |> List.for_all (try_prove_task ~timelimit:1))
                tt'
    in
    (* ----try congruence *)
    (* debug_flag := true; *)
    let trans_congruence task =
      let _, task' = Why3.Task.task_separate_goal task in
      (* debug "trying congruence on:@.  %a@." Why3.Pretty.print_task task; *)
      match Vctrans.apply_congruence @@ Why3.Task.task_goal_fmla task with
      | None -> None
      | Some goal ->
         Some (Why3.Task.add_decl task' @@
                 Why3.Decl.create_prop_decl Why3.Decl.Pgoal
                                            (Why3.Task.task_goal task)
                                            goal
               |> apply_why3trans "split_goal_right"
               |> List.map @@ apply_why3trans "compute_specified"
               |> List.concat
               |> List.map @@ task_map_decl simplify_formula
               |> List.map @@ Vctrans.eliminate_linear_quantifier
               |> List.map @@ task_map_decl simplify_formula)
    in
    let rec f n task =
      if n = 0 then
        false
      else
        match trans_congruence task with
        | None -> false
        | Some tasks ->
           List.filter (fun t -> not (try_prove_task t)) tasks
           |> List.for_all @@ f (n - 1)
    in
    debug "trying congruence...@.";
    let tt'' = try_on_task_tree (fun t -> f 10 t) tt' in
    (* ----try eliminate-equality *)
    debug "trying eliminate equality...@.";
    let try_elim_eq task =
      let task' = transform_goal Vctrans.replace_equality_with_false task in
      let tasks =
        if !trans_flag then
          task'
          |> task_map_decl simplify_formula
          |> Vctrans.eliminate_linear_quantifier
          |> task_map_decl simplify_formula
          |> apply_why3trans "compute_specified"
        else [task']
      in
      List.for_all try_prove_task tasks
    in
    let tt''' = try_on_task_tree try_elim_eq tt'' in
    (* print unsolved tasks *)
    print_task_tree tt''';
    (* List.iter Vctrans.collect_eqns_test tasks'; *)
    if tt''' = TTSuccess then
      Format.printf "Verified!@."
    else
      let n = task_tree_count tt''' in
      Format.printf "%d unsolved task%s.@."
                    n (if n = 1 then "" else "s")
  else
    if !print_task_style = "full" then
      List.iter (fun task ->
                 Format.printf "Task #%d:@." (Why3.Task.task_hash task);
                 print_task_full task None)
                tasks
    else if !print_task_style = "short" then
      List.iter (fun task ->
                 Format.printf "Task #%d:@." (Why3.Task.task_hash task);
                 print_task_short task None)
                tasks
