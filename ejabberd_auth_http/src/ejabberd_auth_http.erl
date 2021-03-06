%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_http.erl
%%% Author  : Piotr Nosek <piotr.nosek@erlang-solutions.com>
%%% Purpose : Authentication via HTTP request
%%% Created : 23 Sep 2013 by Piotr Nosek <piotr.nosek@erlang-solutions.com>
%%%----------------------------------------------------------------------

-module(ejabberd_auth_http).
-author('piotr.nosek@erlang-solutions.com').

-behaviour(ejabberd_auth).

-behaviour(ejabberd_config).

%% External exports
-export([start/1,
         set_password/3,
         check_password/4,
         check_password/6,
         try_register/3,
         get_password/2,
         get_password_s/2,
         user_exists/2,
         remove_user/2,
         remove_user/3,
         plain_password_required/1,
         store_type/1,
         login/2,
         get_password/3,
         opt_type/1,
         stop/1]).

-include("scram.hrl").
-include("logger.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

opt_type(auth_opts) ->
    fun(L) ->
            lists:map(
              fun({host, V}) when is_binary(V) ->
                      {host, V};
                 ({connection_pool_size, V}) when is_integer(V) ->
                      {connection_pool_size, V};
                 ({connection_opts, V}) when is_list(V) ->
                      {connection_opts, V};
                 ({basic_auth, V}) when is_binary(V) ->
                      {basic_auth, V};
                 ({path_prefix, V}) when is_binary(V) ->
                      {path_prefix, V}
              end, L)
    end;
opt_type(_) -> [auth_opts].

-spec start(binary()) -> ok.
start(Host) ->
    AuthOpts = ejabberd_config:get_option({auth_opts, Host}, fun(V) -> V end),
    {_, AuthHost} = lists:keyfind(host, 1, AuthOpts),
    PoolSize = proplists:get_value(connection_pool_size, AuthOpts, 10),
    Opts = proplists:get_value(connection_opts, AuthOpts, []),
    ChildMods = [fusco],
    ChildMFA = {fusco, start_link, [binary_to_list(AuthHost), Opts]},
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    ChildSpec = {Proc, {cuesport, start_link,
			[pool_name(Host), PoolSize, ChildMods, ChildMFA]},
		 transient, 2000, supervisor, [cuesport | ChildMods]},
    supervisor:start_child(ejabberd_backend_sup, ChildSpec).

-spec plain_password_required(binary()) -> false.
plain_password_required(Server) ->
    store_type(Server) == scram.

-spec store_type(binary()) -> external.
store_type(_) ->
    external.

-spec check_password(ejabberd:luser(), binary(), ejabberd:lserver(), binary()) -> boolean().
check_password(LUser, _AuthzId, LServer, Password) ->
    case scram2:enabled(LServer) of
        false ->
            case make_req(get, <<"check_password">>, LUser, LServer, Password) of
                {ok, <<"true">>} -> true;
                _ -> false
            end;
        true ->
            {ok, true} =:= verify_scram_password(LUser, LServer, Password)
    end.

-spec check_password(ejabberd:luser(), binary(), ejabberd:lserver(), binary(), binary(), fun()) -> boolean().
check_password(LUser, _AuthzId, LServer, Password, Digest, DigestGen) ->
    case make_req(get, <<"get_password">>, LUser, LServer, <<"">>) of
        {error, _} ->
            false;
        {ok, GotPasswd} ->
            case scram2:enabled(LServer) of
                true ->
                    case scram2:deserialize(GotPasswd) of
                        {ok, #scram{} = Scram} ->
                            scram2:check_digest(Scram, Digest, DigestGen, Password);
                        _ ->
                            false
                    end;
                false ->
                    check_digest(Digest, DigestGen, Password, GotPasswd)
            end
    end.

-spec check_digest(binary(), fun(), binary(), binary()) -> boolean().
check_digest(Digest, DigestGen, Password, Passwd) ->
    DigRes = if
                 Digest /= <<>> ->
                     Digest == DigestGen(Passwd);
                 true ->
                     false
             end,
    if DigRes ->
           true;
       true ->
           (Passwd == Password) and (Password /= <<>>)
    end.


-spec set_password(ejabberd:luser(), ejabberd:lserver(), binary()) -> ok | {error, term()}.
set_password(LUser, LServer, Password) ->
    PasswordFinal = case scram2:enabled(LServer) of
                        true -> scram2:serialize(scram2:password_to_scram(
                                                  Password, scram2:iterations(LServer)));
                        false -> Password
                    end,
    case make_req(post, <<"set_password">>, LUser, LServer, PasswordFinal) of
        {error, _} = Err -> Err;
        _ -> ok
    end.

-spec try_register(ejabberd:luser(), ejabberd:lserver(), binary()) -> ok | {error, atom()}.
try_register(LUser, LServer, Password) ->
    PasswordFinal = case scram2:enabled(LServer) of
                        true -> scram2:serialize(scram2:password_to_scram(
                                                  Password, scram2:iterations(LServer)));
                        false -> Password
                    end,
    case make_req(post, <<"register">>, LUser, LServer, PasswordFinal) of
        {ok, created} -> ok;
        {error, conflict} -> {error, exists};
        Error -> Error
    end.

-spec get_password(ejabberd:luser(), ejabberd:lserver()) -> error.
get_password(_, _) ->
    error.

-spec get_password_s(ejabberd:luser(), ejabberd:lserver()) -> binary().
get_password_s(User, Server) ->
    case get_password(User, Server) of
        Pass when is_binary(Pass) -> Pass;
        _ -> <<>>
    end.

-spec user_exists(ejabberd:luser(), ejabberd:lserver()) -> boolean().
user_exists(LUser, LServer) ->
    case make_req(get, <<"user_exists">>, LUser, LServer, <<"">>) of
        {ok, <<"true">>} -> true;
        _ -> false
    end.

-spec remove_user(ejabberd:luser(), ejabberd:lserver()) -> ok | not_exists | not_allowed | bad_request.
remove_user(LUser, LServer) ->
    remove_user_req(LUser, LServer, <<"">>, <<"remove_user">>).

-spec remove_user(ejabberd:luser(), ejabberd:lserver(), binary()) -> ok | not_exists | not_allowed | bad_request.
remove_user(LUser, LServer, Password) ->
    case scram2:enabled(LServer) of
        false ->
            remove_user_req(LUser, LServer, Password, <<"remove_user_validate">>);
        true ->
            case verify_scram_password(LUser, LServer, Password) of
                {ok, false} ->
                    not_allowed;
                {ok, true} ->
                    remove_user_req(LUser, LServer, <<"">>, <<"remove_user">>);
                {error, Error} ->
                    Error
            end
    end.

-spec remove_user_req(binary(), binary(), binary(), binary()) ->
    ok | not_exists | not_allowed | bad_request.
remove_user_req(LUser, LServer, Password, Method) ->
    case make_req(post, Method, LUser, LServer, Password) of
        {error, not_allowed} -> not_allowed;
        {error, not_found} -> not_exists;
        {error, _} -> bad_request;
        _ -> ok
    end.

%%%----------------------------------------------------------------------
%%% Request maker
%%%----------------------------------------------------------------------

-spec make_req(post | get, binary(), binary(), binary(), binary()) ->
    {ok, Body :: binary()} | {error, term()}.
make_req(_, _, LUser, LServer, _) when LUser == error orelse LServer == error ->
    {error, {prep_failed, LUser, LServer}};
make_req(Method, Path, LUser, LServer, Password) -> 
    AuthOpts = ejabberd_config:get_option({auth_opts, LServer}, fun(V) -> V end),
    BasicAuth = case lists:keyfind(basic_auth, 1, AuthOpts) of
                    {_, BasicAuth0} -> BasicAuth0;
                    _ -> ""
                end,
    PathPrefix = case lists:keyfind(path_prefix, 1, AuthOpts) of
                     {_, Prefix} -> Prefix;
                     false -> <<"/">>
                 end,
    BasicAuth64 = base64:encode(BasicAuth),
    LUserE = list_to_binary(http_uri:encode(binary_to_list(LUser))),
    LServerE = list_to_binary(http_uri:encode(binary_to_list(LServer))),
    PasswordE = list_to_binary(http_uri:encode(binary_to_list(Password))),
    Query = <<"user=", LUserE/binary, "&server=", LServerE/binary, "&pass=", PasswordE/binary>>,
    Header = [{<<"Authorization">>, <<"Basic ", BasicAuth64/binary>>}],
    ContentType = {<<"Content-Type">>, <<"application/x-www-form-urlencoded">>},
    Connection = cuesport:get_worker(existing_pool_name(LServer)),

    ?DEBUG("Making request '~s' for user ~s@~s...", [Path, LUser, LServer]),
    {ok, {{Code, _Reason}, _RespHeaders, RespBody, _, _}} = case Method of
        get -> fusco:request(Connection, <<PathPrefix/binary, Path/binary, "?", Query/binary>>,
                             "GET", Header, "", 2, 5000);
        post -> fusco:request(Connection, <<PathPrefix/binary, Path/binary>>,
                              "POST", [ContentType|Header], Query, 2, 5000)
    end,

    ?DEBUG("Request result: ~s: ~p", [Code, RespBody]),
    case Code of
        <<"409">> -> {error, conflict};
        <<"404">> -> {error, not_found};
        <<"401">> -> {error, not_authorized};
        <<"403">> -> {error, not_allowed};
        <<"400">> -> {error, RespBody};
        <<"204">> -> {ok, <<"">>};
        <<"201">> -> {ok, created};
        <<"200">> -> {ok, RespBody}
    end.

%%%----------------------------------------------------------------------
%%% Other internal functions
%%%----------------------------------------------------------------------
-spec pool_name(binary()) -> atom().
pool_name(Host) ->
    list_to_atom("ejabberd_auth_http_" ++ binary_to_list(Host)).

-spec existing_pool_name(binary()) -> atom().
existing_pool_name(Host) ->
    list_to_existing_atom("ejabberd_auth_http_" ++ binary_to_list(Host)).

-spec verify_scram_password(binary(), binary(), binary()) ->
    {ok, boolean()} | {error, bad_request | not_exists}.
verify_scram_password(LUser, LServer, Password) ->
    case make_req(get, <<"get_password">>, LUser, LServer, <<"">>) of
        {ok, RawPassword} ->
            case scram2:deserialize(RawPassword) of
                {ok, #scram{} = ScramRecord} ->
                    {ok, scram2:check_password(Password, ScramRecord)};
                _ ->
                    {error, bad_request}
            end;
        _ ->
            {error, not_exists}
    end.

login(_User, _Server) ->
    erlang:error(not_implemented).

get_password(_User, _Server, _DefaultValue) ->
    erlang:error(not_implemented).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    supervisor:terminate_child(ejabberd_backend_sup, Proc),
    supervisor:delete_child(ejabberd_backend_sup, Proc).
