%% @doc Zeta: an Erlang client for Riemann

-module(zeta).
-author('Joseph Abrahamson <me@jspha.com>').

-export([ev/2, ev/3, ev/4, evh/2, evh/3, evh/4]).
-export([sv/2, sv/3, sv/4, svh/2, svh/3, svh/4]).
-export([cv/2, cv/3, cv/4, cvh/2, cvh/3, cvh/4]).
-export([cv_batch/1, sv_batch/1, sv_batch/2]).

-export([all_client_configs/0, client_config/1]).

-behaviour(application).
-define(APP, ?MODULE).
-export([start/0, start/2, stop/1]).

-behaviour(supervisor).
-define(SUP, zeta_sup).
-export([init/1]).

-include("include/zeta.hrl").

%% ----------
%% Public API

-type atom_or_string() :: atom() | nonempty_string().

-type service() :: atom_or_string() | list(atom_or_string()).
-type loc_spec() :: atom_or_string() | {atom_or_string(), service()}.
-type event_opt() :: {t | time | desc | description | tag | tags | ttl, _}.

-spec 
%% @doc Builds an event, trying to be as "DWIM" as possible.
ev(loc_spec() | service(), number()) -> zevent().
ev({Host, Service}, Metric) when is_list(Host) ->
    E = ev(Service, Metric),
    E#zeta_event{host = Host};
ev({Host, Service}, Metric) when is_atom(Host) ->
    E = ev(Service, Metric),
    E#zeta_event{host = atom_to_list(Host)};
ev(Service, Metric) when is_number(Metric) ->
    #zeta_event{service = stringify(Service), metric_f = Metric};
ev(Service, undefined) ->
    #zeta_event{service = stringify(Service)}.

stringify(Thing = [X | _]) when is_integer(X) -> Thing;
stringify(Things) when is_list(Things) -> lists:map(fun stringify/1, Things);
stringify(Thing) when is_atom(Thing) -> atom_to_list(Thing);
stringify(Thing) when is_number(Thing) -> integer_to_list(round(Thing));
stringify(Thing) when is_tuple(Thing) -> 
    string:join(lists:map(fun stringify/1, tuple_to_list(Thing)), " ").

ev(Loc, Metric, State) ->
    ev(Loc, Metric, State, []).

-spec
ev(loc_spec() | service(), number(), atom_or_string(), [event_opt()]) -> zevent().
ev(Loc, Metric, State, []) when is_atom(State) ->
    ev(Loc, Metric, atom_to_list(State), []);
ev(Loc, Metric, State, []) when is_list(State) ->
    E = ev(Loc, Metric),
    E#zeta_event{state = State};
ev(Loc, Metric, State, Opts) ->
    [Time, Description, Tags, TTL, Attributes] = 
	lists:map(fun (K) -> lookup(K, Opts) end, 
		  [[t, time], [desc, description], [tag, tags], ttl, attributes]),
    E = ev(Loc, Metric, State, []),
    E#zeta_event{time = Time, 
		 description = Description, tags = process_tags(Tags, []),
		 ttl = TTL,
                 attributes = process_attributes(Attributes, [])}.

process_tags(undefined, _) -> [];
process_tags([], Acc) -> Acc;
process_tags([Tag | Tags], Acc) when is_atom(Tag) ->
    process_tags(Tags, [atom_to_list(Tag) | Acc]);
process_tags([Tag | Tags], Acc) when is_list(Tag) ->
    process_tags(Tags, [Tag | Acc]).

process_attributes(undefined, _) -> [];
process_attributes([], Acc) -> Acc;
process_attributes([{Key, Value}|Rest], Acc) ->
    process_attributes(Rest, [#zeta_attribute{key = atom_to_list(Key),
                                              value = Value}|Acc]).

evh(Service, Metric) ->
    ev({node(), Service}, Metric).

evh(Service, Metric, State) ->
    ev({node(), Service}, Metric, State).

evh(Service, Metric, State, Opts) ->
    ev({node(), Service}, Metric, State, Opts).

%% @doc Sends an event, trying to be as "DWIM" as possible.
sv(Loc, Metric) -> sv(Loc, Metric, undefined).
sv(Loc, Metric, State) -> sv(Loc, Metric, State, []).
sv(Loc, Metric, State, Opts) ->
    E = ev(Loc, Metric, State, Opts),
    sv_batch([E]).

sv_batch(Es) -> sv_batch(default, Es).
sv_batch(Backend, Es) ->
    M = #zeta_msg{zevents = Es},
    Data = zeta_pb:encode(M),
    Length = byte_size(Data),
    case zeta_corral:client(Backend) of
        {ok, Client} ->
           gen_server:call(
             Client, {events, <<Length:32/integer-big, Data/binary>>});
        {error, _} = Error ->
            Error
    end.

svh(Service, Metric) -> svh(Service, Metric, undefined).
svh(Service, Metric, State) -> svh(Service, Metric, State, []).
svh(Service, Metric, State, Opts) -> sv({node(), Service}, Metric, State, Opts).

cv(Loc, Metric) -> cv(Loc, Metric, undefined).
cv(Loc, Metric, State) -> cv(Loc, Metric, State, []).
cv(Loc, Metric, State, Opts) ->
    E = ev(Loc, Metric, State, Opts),
    cv_batch([E]).

cv_batch(Es) ->
    M = #zeta_msg{zevents = Es},
    Data = zeta_pb:encode(M),
    case zeta_corral:client() of
        {ok, Client} ->
            gen_server:cast(Client, {events, Data});
        {error, _} = Error ->
            Error
    end.

cvh(Service, Metric) -> cvh(Service, Metric, undefined).
cvh(Service, Metric, State) -> cvh(Service, Metric, State, []).
cvh(Service, Metric, State, Opts) -> cv({node(), Service}, Metric, State, Opts).

lookup(K, List) when is_atom(K) ->
    case lists:keyfind(K, 1, List) of
	{K, V} -> V;
	false -> undefined
    end;
lookup([], _) -> undefined;
lookup([K | Ks], List) ->
    case lookup(K, List) of
	undefined -> lookup(Ks, List);
	V -> V
    end.

%% ---------------------
%% Application callbacks

start() ->
    _ = lists:map(fun(A) -> ok = estart(A) end,
		  [compiler, syntax_tools, lager]),
    application:start(zeta).

start(_StartType, _Args) ->
    supervisor:start_link({local, ?SUP}, ?MODULE, []).

stop(_State) ->
    ok.


%% --------------------
%% Supervisor callbacks

init(_Args) ->
    _Backend = {zeta_client, 
	       {zeta_client, start_link, []},
	       permanent, brutal_kill, worker, [zeta_client]},
    Corral = {zeta_corral,
	      {zeta_corral, start_link, []},
	      permanent, 5000, supervisor, [zeta_corral]},
    {ok, {{one_for_one, 5, 10}, [Corral]}}.


%% ---------
%% Utilities

all_client_configs() ->
    case application:get_env(?APP, clients) of
	{ok, Confs} -> {ok, Confs};
	_ -> {ok, []}
    end.

-spec 
client_config(Client :: atom()) -> 
    {ok, {inet:address(), inet:portnumber(), Restart :: term()}} | {error, any()}.
client_config(Client) ->
    case all_client_configs() of
	{ok, Confs} ->
	    case lists:keyfind(Client, 1, Confs) of
		{Client, Conf} ->
                {ok, Conf};
		_Else ->
                {error, no_config}
	    end
    end.

estart(App) ->
    case application:start(App) of
	{error, {already_started, _}} -> ok;
	ok -> ok;
	Else -> Else
    end.

