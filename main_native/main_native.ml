(** Ensures [f] is running at most [n] times concurrently
    	Internally uses an Lwt_pool of [unit] *)
let pooled n f =
  let pool = Lwt_pool.create n (fun _ -> Lwt.return_unit) in
  fun x -> Lwt_pool.use pool (fun () -> f x)

module PooledFetch =
struct

  type error = Fetch.error

  (** at most 5 fetch at once *)
  let fetch = pooled 5 Fetch.fetch

end

module Log =
struct

  let log_e ~url msg = Logs.warn (fun fmt -> fmt "%s: %s" url msg)
  let log_i ~url msg = Logs.info (fun fmt -> fmt "%s: %s" url msg)

  let log_error url = function
    | `Fetch_error err ->
      log_e ~url (Fetch.error_to_string err)
    | `Parsing_error ((line, col), msg) ->
      log_e ~url (sprintf "Parsing error: %d:%d: %s" line col msg)

  let log_updated url ~entries =
    log_i ~url (sprintf "%d new entries" entries)

end

module Feed_datas =
struct

  type t = Rss_to_mail.feed_data StringMap.t

  let get t url = StringMap.find_opt url t
  let set t url data = StringMap.add url data t

end

module Rss_to_mail = Rss_to_mail.Make (PooledFetch) (Log) (Feed_datas)

let lwt_timeout t r =
  let timeout =
    Lwt.bind (Lwt_unix.sleep t) (fun () -> Lwt.fail_with "timeout")
  in
  Lwt.pick [ r; timeout ]

(** Send a list of mail to [to_]
    	Returns the list of unsent emails *)
let send_mails ~random_seed (conf : Persistent_data.config) mails =
  let send (i, (t : Rss_to_mail.mail)) =
    Logs.debug (fun fmt -> fmt "Sending \"%s\" \"%s\"" t.sender t.subject);
    let server = conf.server in
    let auth =
      let encode s = Base64.encode_string ~pad:true s in
      let `Plain (login, password) = conf.server_auth in
      encode login, encode password
    in
    let from = Some t.sender, conf.from_address in
    let to_ = None, conf.to_address in
    let boundary = "rss_to_mail-boundary-" ^ random_seed in
    let headers = [
      "Content-Type: multipart/alternative; boundary=" ^ boundary;
      "X-Entity-Ref-ID: " ^ random_seed ^ string_of_int i;
    ] in
    let do_send () =
      let part content_type content =
        Client_unix.stream_of_list @@
        ("--" ^ boundary) :: ("Content-Type: " ^ content_type) :: "" ::
        String.split_on_char '\n' content
      in
      let body = Client_unix.stream_concat [
        part "text/plain" t.body_text;
        part "text/html" t.body_html;
        Client_unix.stream_of_list [ "--" ^ boundary ^ "--" ]
      ] in
      Client_unix.send_mail ~auth ~server ~from ~to_ ~headers t.subject body
      |> Lwt.map (fun () -> None)
      |> lwt_timeout 5.
    in
    Lwt.catch do_send (fun _ ->
        Logs.err (fun fmt -> fmt "Failed sending mail \"%s\"" t.subject);
        Lwt.return (Some t))
  in
  (* At most 2 mails sending in parallel *)
  let send_pooled = pooled 2 send in
  mails
  |> Lwt_list.mapi_p (fun i t -> send_pooled (i, t))
  |> Lwt.map (List.filter_map id)

let run (conf : Persistent_data.config) (datas : Persistent_data.Feed_datas.t) =
  Logs.debug (fun fmt -> fmt "%d feeds" (List.length conf.feeds));
  let now = Unix.time () |> Int64.of_float in
  let%lwt feed_datas, mails = Rss_to_mail.check_all ~now datas.feed_datas conf.feeds in
  Logs.app (fun fmt -> fmt "%d new entries" (List.length mails));
  let%lwt unsent_mails =
    let random_seed = Int64.to_string now in
    send_mails ~random_seed conf (datas.unsent_mails @ mails)
  in
  (match unsent_mails with
   | _ :: _ -> Logs.warn (fun fmt ->
        fmt "%d mails could not be sent" (List.length unsent_mails))
   | [] -> ());
  Lwt.return Persistent_data.Feed_datas.{ feed_datas; unsent_mails }

let parse_config_file config_file =
  let err msg = failwith (sprintf "Error: %s: %s" config_file msg) in
  match CCSexp.parse_file config_file with
  | exception Sys_error msg	-> err msg
  | Error msg					-> err msg
  | Ok sexp						-> Persistent_data.load_feeds sexp

let parse_datas_file fname =
  match Persistent_data.Feed_datas.parse_file fname with
  | Error _ -> Persistent_data.Feed_datas.empty
  | Ok t -> t

let feed_datas_file = "feed_datas.sexp"

let run config_file =
  let config = parse_config_file config_file in
  let datas = parse_datas_file feed_datas_file in
  let%lwt datas = run config datas in
  Persistent_data.Feed_datas.save_to_file feed_datas_file datas;
  Lwt.return_unit

(* CLI *)

let run_command config_file () = Lwt_main.run (run config_file)

let check_config_command config_file () =
  try ignore (parse_config_file config_file)
  with Failure msg ->
    Printf.eprintf "The configuration file contains some errors:\n  %s\n" msg;
    exit 1

let run_scraper_command src () =
  match Lwt_main.run (Run_scraper.run src) with
  | Ok () -> ()
  | Error e -> Logs.err (fun fmt -> fmt "%s: %s" src e)

open Cmdliner

let verbose =
  let setup_log level =
    Logs.set_level level;
    Logs.set_reporter (Logs_fmt.reporter ())
  in
  Term.(const setup_log $ Logs_cli.level ())

let config_file =
  let doc = "Configuration file" in
  Arg.(value & pos 0 string "feeds.sexp" & info [] ~docv:"CONFIG" ~doc)

let run_term =
  let doc = "Fetch a list of feeds and send a mail for new entries" in
  Term.(const run_command $ config_file $ verbose),
  Term.info "run" ~doc

let check_config_term =
  let doc = "Check the configuration file for errors and exit" in
  Term.(const check_config_command $ config_file $ verbose),
  Term.info "check-config" ~doc

let run_scraper_term =
  let source_arg =
    let doc = "Url to an html web page or path to local file." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"SRC" ~doc)
  in
  let doc = "Run a scraper against a web page. Useful for degugging. \
             Read the scraper definition from stdin." in
  Term.(const run_scraper_command $ source_arg $ verbose),
  Term.info "run-scraper" ~doc

let () =
  Term.exit @@ Term.eval_choice run_term [
    run_term;
    check_config_term;
    run_scraper_term;
  ]
