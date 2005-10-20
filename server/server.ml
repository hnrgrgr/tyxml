(* Copyright Vincent Balat et Denis Berthod 2005 *)
(* Do not redistribute *)

open Lwt
open Messages
open Omlet
open Http_frame
open Http_com
open Sender_helpers

let static_pages_dir = ref "/"

module Content = 
  struct
    type t = string
    let content_of_string c = c
    let string_of_content s = s
  end

module Http_frame = FHttp_frame (Content)

module Http_receiver = FHttp_receiver (Content)

let listening_port = int_of_string Sys.argv.(1)

(*let _ = Unix.set_nonblock Unix.stdin
let _ = Unix.set_nonblock Unix.stdout
let _ = Unix.set_nonblock Unix.stderr*)

let new_socket () = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0
let local_addr num = Unix.ADDR_INET (Unix.inet_addr_any, num)

let error_page s =
          <<
          <html>
          <h1> Error </h1>
          $str:s$
          </html>
          >>


exception Omlet_Malformed_Url

(* *)
let get_frame_infos =
(*let full_action_param_prefix = action_prefix^action_param_prefix in
let action_param_prefix_end = String.length full_action_param_prefix - 1 in*)
  fun http_frame ->
  try 
    let url = Http_header.get_url http_frame.Http_frame.header in
    let url2 = 
      Neturl.parse_url 
	~base_syntax:(Hashtbl.find Neturl.common_url_syntax "http")
	url
    in
    let params_string = try
      Neturl.url_query ~encoded:true url2
    with Not_found -> ""
    in
    let get_params = Netencoding.Url.dest_url_encoded_parameters params_string 
    in
    let post_params =
      match http_frame.Http_frame.content with
	  None -> []
	| Some s -> Netencoding.Url.dest_url_encoded_parameters s
    in
    let internal_state,post_params2 = 
      try (Some (int_of_string (List.assoc state_param_name post_params)),
	   List.remove_assoc state_param_name post_params)
      with Not_found -> (None, post_params)
    in
    let internal_state2,get_params2 = 
      try 
	match internal_state with
	    None ->
	      (Some (int_of_string (List.assoc state_param_name get_params)),
	       List.remove_assoc state_param_name get_params)
	  | _ -> (internal_state, get_params)
      with Not_found -> (internal_state, get_params)
    in
    let action_info, post_params3 =
      try
	let action_name, pp = 
	  ((List.assoc (action_prefix^action_name) post_params2),
	   (List.remove_assoc (action_prefix^action_name) post_params2)) in
	let reload,pp2 = 
	  try
	    ignore (List.assoc (action_prefix^action_reload) pp);
	    (true, (List.remove_assoc (action_prefix^action_reload) pp))
	  with Not_found -> false, pp in
	let ap,pp3 = pp2,[]
(*	  List.partition 
	    (fun (a,b) -> 
	       ((String.sub a 0 action_param_prefix_end)= 
		   full_action_param_prefix)) pp2 *) in
	  (Some (action_name, reload, ap), pp3)
      with Not_found -> None, post_params2 in
    let useragent = (Http_header.get_headers_value
		       http_frame.Http_frame.header "user-agent")
    in
      ((*remove_slash*) (Neturl.url_path url2), (* the url path *)
       url,
       internal_state2,
       get_params2,
       post_params3,
       useragent),action_info
  with _ -> raise Omlet_Malformed_Url

    
(* C'est de la bidouille. Cette fonction est � refaire proprement
   (pour ent�tes http)
*)
(*
let really_write code keep_alive ?cookie out_ch buffer pos len =
  let rec really_write_aux out_ch buffer pos len =
    Lwt_unix.write out_ch buffer pos len >>=
      (
	fun len' ->
          if len = len'
          then return ()
          else really_write_aux out_ch buffer (pos+len') (len-len')
      )
  in 
  let header =
bip 700;
("HTTP/1.1 "^code^"
Date: Tue, 31 May 2006 16:34:59 GMT
Server: ploplop (Unix)  (Gentoo/Linux) omlet
Last-Modified: Wed, 20 Oct 1900 12:51:24 GMT
Accept-Ranges: bytes
Cache-Control: no-cache
"^(match cookie with None -> "" | Some c -> ("Set-Cookie: session="^c^"\n"))
^"Content-Length: "^(string_of_int len)^"
Connection: "^(if keep_alive then "Keep-Alive" else "close")^"
Content-Type: text/html\n\n") in
print_endline "J'envoie :";
print_endline header;
    Lwt_unix.write out_ch header 0 (String.length header) >>= (fun _ ->
print_endline buffer;
 really_write_aux out_ch buffer pos len)
*)

let service http_frame in_ch sockaddr 
    xhtml_sender file_sender empty_sender () =
  try 
    let cookie = 
      try 
	Some
	  (List.assoc "session"
	     (Netencoding.Url.dest_url_encoded_parameters 
		(Http_header.get_headers_value 
		   http_frame.Http_frame.header "cookie")))
	  (* en fait dest_url_encoded_parameters n'est pas exactement
	     ce que je veux si les params sont s�par�s par des ; au lieu
	     de &... � revoir !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! *)
      with _ -> None
    in
    let (_,fullurl,_,_,_,_) as frame_info, action_info = 
      get_frame_infos http_frame in
      match action_info with
	  None ->
	    (* Je pr�f�re pour l'instant ne jamais faire de keep-alive pour
	       �viter d'avoir un nombre de threads qui croit sans arr�t *)
	    let keep_alive = false in
	    (try 
	      let cookie2,page = get_page frame_info sockaddr cookie in
		send_page ~keep_alive:keep_alive 
		  ?cookie:(if cookie2 <> cookie then 
			     (if cookie2 = None 
			      then Some("0; expires=Wednesday, 09-Nov-99 23:12:40 GMT")
			      else cookie2) 
			   else None)
		  page xhtml_sender 
	    with Static_File l -> 
	      Messages.warning ("Fichier statique : "^l);
	      send_file 
		~keep_alive:keep_alive 
		~code:200 (!static_pages_dir^l) file_sender
	    )
	      >>= (fun _ -> return keep_alive)
	| Some (action_name, reload, action_params) ->
	    let cookie2,() = 
	      make_action 
		action_name action_params frame_info sockaddr cookie in
	    let keep_alive = false in
	      (if reload then
		 let cookie3,page = get_page frame_info sockaddr cookie2 in
		   (send_page ~keep_alive:keep_alive 
		      ?cookie:(if cookie3 <> cookie then 
				 (if cookie3 = None 
				  then Some("0; expires=Wednesday, 09-Nov-99 23:12:40 GMT")
				  else cookie3) 
			       else None)
	              page xhtml_sender)
	       else
		 (send_empty ~keep_alive:keep_alive 
		    ?cookie:(if cookie2 <> cookie then 
			       (if cookie2 = None 
				then Some("0; expires=Wednesday, 09-Nov-99 23:12:40 GMT")
				else cookie2) 
			     else None)
                    ~code:204
	            empty_sender)) >>=
		(fun _ -> return keep_alive)
  with Omlet_404 -> 
   (*really_write "404 Not Found" false in_ch "error 404 \n" 0 11 *)
   send_error ~error_num:404 xhtml_sender
   (*send_file ~code:404 "../pages/error.html" file_sender*)
   (*send_file ~code:200 "../pages/Volta.GIF" file_sender*)
   >>= (fun _ ->
     return true (* idem *))
    | Omlet_Malformed_Url ->
    (*really_write "404 Not Found ??" false in_ch "error ??? (Malformed URL) \n"
    * 0 11 *)
	send_error ~error_num:400 xhtml_sender
	>>= (fun _ ->
	       return true (* idem *))
    | e ->
	send_page ~keep_alive:false
	  (error_page ("Exception : "^(Printexc.to_string e)))
	  xhtml_sender
    (* send_file ~code:200 "../pages/Volta.GIF" file_sender *)
	>>= (fun _ ->
	       return true (* idem *))
                                              



(** Thread waiting for events on a the listening port *)
let listen () =

  let listen_connexion receiver in_ch sockaddr 
      xhtml_sender file_sender empty_sender =

    let rec listen_connexion_aux () =
      let analyse_http () = 
        Http_receiver.get_http_frame receiver () >>=(fun
          http_frame ->
             catch (service http_frame in_ch sockaddr 
		      xhtml_sender file_sender empty_sender)
	      fail
            (*fun ex ->
              match ex with
              | _ -> fail ex
            *)
            >>= (fun keep_alive -> 
              if keep_alive then
                listen_connexion_aux ()
                (* Pour laisser la connexion ouverte, je relance *)
              else return ()
            )
        ) in
      catch analyse_http 
      (function
        |Com_buffer.End_of_file -> return ()
        |Http_error.Http_exception (_,_) as http_ex->
            (*let mes = Http_error.string_of_http_exception http_ex in
            really_write "404 Plop" (* � revoir ! *) 
	      false in_ch mes 0 
	      (String.length mes);*)
            send_error ~http_exception:http_ex xhtml_sender;
            return ()
        |ex -> fail ex
      )

    in listen_connexion_aux ()

    in 
    let wait_connexion socket =
      let rec wait_connexion_rec () =
        Lwt_unix.accept socket >>= (fun (inputchan, sockaddr) ->
	warning "\n____________________________NEW CONNECTION__________________________";
        let xhtml_sender =
          create_xhtml_sender ~server_name:"ploplop (Unix) (gentoo/Linux) omlet"
        inputchan 
        in
        let file_sender =
          create_file_sender ~server_name:"ploplop (Unix) (gentoo/Linux) omlet"
        inputchan
        in
        let empty_sender =
          create_empty_sender ~server_name:"ploplop (Unix) (gentoo/Linux) omlet"
        inputchan
        in
	listen_connexion 
	  (Http_receiver.create inputchan) inputchan sockaddr xhtml_sender
        file_sender empty_sender;
          wait_connexion_rec ()) (* je relance une autre attente *)
      in wait_connexion_rec ()
    
    in
    ((* Initialize the listening address *)
    new_socket () >>= (fun listening_socket ->
      Unix.setsockopt listening_socket Unix.SO_REUSEADDR true;
      Unix.bind listening_socket (local_addr listening_port);
      Unix.listen listening_socket 1;
      wait_connexion  listening_socket
    ))



let _ = 
  Lwt_unix.run (
    (* Initialisations *)
    static_pages_dir := "../pages/";
    (* On charge les modules *)
    (try
       Dynlink.init();
(*       Dynlink.loadfile "/opt/godi/lib/ocaml/pkg-lib/pcre/pcre.cma";
       Dynlink.loadfile "/opt/godi/lib/ocaml/site-lib/postgres/postgres.cma";
       Dynlink.loadfile "/opt/godi/lib/ocaml/std-lib/dbi/dbi.cma";
       Dynlink.loadfile "/opt/godi/lib/ocaml/std-lib/dbi/dbi_postgres.cmo"; *)
       Dynlink.loadfile "../lib/db_create.cmo";
       Dynlink.loadfile "../lib/krokopersist.cmo";
       Dynlink.loadfile "../lib/krokache.cmo";
       Dynlink.loadfile "../lib/krokodata.cmo";
       Dynlink.loadfile "../lib/krokopages.cmo";
       Dynlink.loadfile "../lib/krokosavable.cmo";
       Dynlink.loadfile "../lib/krokoboxes.cmo";
       load_aaaaa_module ~dir:[""] ~cmo:"../lib/moduleexample.cmo";
       load_aaaaa_module ~dir:["krokoutils"] ~cmo:"../lib/krokoxample.cmo";
       load_aaaaa_module ~dir:["kiko"] ~cmo:"../../kiko/lib/kiko.cmo";
     with Aaaaa_error_while_loading m -> (warning ("Error while loading "^m)));
    listen ()
  )


