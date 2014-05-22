%%% -------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and Patrick Lu
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc A Generic Server implementation of a controller that talks to 
%%%		 philosophers, telling them to become hungry, stop eating and
%%%      leave with nice commands (and receive their output and
%%%		 formatting that response nicely). It also supplies some extr
%%%		 info commands such as get_state, get_neighbors, and list_forks
%%% @end
%%%--------------------------------------------------------------------

-module(controller).
-behavior(gen_server).

%% External exports
-export([start/0,
		 become_hungry/1,
		 stop_eating/1,
		 leave/1,
		 get_state/1,
		 get_neighbors/1,
		 list_forks/1]).

%% gen_server callbacks
-export([init/1, 
		 handle_call/3, 
		 handle_cast/2, 
		 handle_info/2, 
		 code_change/3, 
		 terminate/2]).

-define(CTRLID, controller).
-define(MYNAME, random_atom(10)).
-record(state, {hungryRefs,
				leaveRefs}).


%%%============================================================================
%%% API
%%%============================================================================

start(Node) ->
	os:cmd("epmd -daemon"),
	net_kernel:start([?MYNAME, shortnames]),
	case net_adm:ping(Node) of
		true ->
			gen_server:start({local, ?CTRLID}, controller, {}, []);
		false ->
			io:format("Give me a valid node to connect to...~n")
	end.

%% @spec become_hungry(Node) -> ok.
%% @doc Casts our server to tell the philosopher to become hungry (and 
%%		store the hungry reference).
become_hungry(Node) ->
	gen_server:cast(controller, {become_hungry, Node}).

%% @spec stop_eating(Node) -> ok.
%% @doc Tells the philosopher Node to stop eating
stop_eating(Node) ->
	Pid = self(),
	Ref = make_ref(),
	{?PHILID, Node} ! {Pid, Ref, stop_eating},
	ok.

%% @spec leave(Node) -> ok.
%% @doc Casts our server to tell the philosopher to leave (and 
%%		store the leave reference).
leave(Node) ->
	gen_server:cast(controller, {leave, Node}).

%% @spec get_state -> joining | thinking | hungry | eating | leaving | gone.
%% @doc Gets the state of philosopher Node.
get_state(Node) ->
	gen_server:call({?PHILID, Node}, getState).

%% @spec get_neighbors -> list().
%% @doc Gets the list of neighbors of philosopher Node.
get_neighbors(Node) ->
	gen_server:call({?PHILID, Node}, getNeighbors).

list_forks(Node) ->
	gen_server:call({?PHILID, Node}, listForks).

%%%============================================================================
%%% GenServer Callbacks (For the rest of the code)
%%%============================================================================

init({}) ->
	{ok, #state{hungryRefs = dict:new(), leaveRefs = dict:new()}}.

handle_cast({become_hungry, Node}, S = #state{hungryRefs = HungryRefs}) ->
	Pid = self(),
	Ref = make_ref(),
	NewHungryRefs = dict:store(Ref, Node, HungryRefs),
	{?PHILID, Node} ! {Pid, Ref, become_hungry},
	{noreply, S#state{hungryRefs = NewHungryRefs}};


handle_cast({leave, Node}, S = #state{leaveRefs = LeaveRefs}) ->
	Pid = self(),
	Ref = make_ref(),
	NewLeaveRefs = dict:store(Ref, Node, LeaveRefs),
	{?PHILID, Node} ! {Pid, Ref, leave},
	{noreply, S#state{leaveRefs = NewLeaveRefs}}.

handle_info({Ref, eating}, S = #state{hungryRefs = HungryRefs}) ->
	Node = dict:fetch(Ref, HungryRefs),
	io:format(timestamp (now()) ++ ": ~p just started eating.~n", [Node]),
	{noreply, S};

handle_info({Ref, gone}, S = #state{leaveRefs = LeaveRefs}) ->
	Node = dict:fetch(Ref, LeaveRefs),
	io:format(timestamp (now()) ++ ": ~p is gone from the table.~n", [Node]),
	{noreply, S};

handle_info({_Ref, badcommand, Command, Node, State}, S) -> 
	io:format(timestamp (now()) ++ ": ~p was in [STATE: ~p] and thus was not in the correct state to ~p.~n", [Node, State, Command]),
	{noreply, S}.


%%%% UNUSED CALLBACKS

handle_call(_, _, S) ->
	{reply, ok, S}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    io:format(timestamp (now()) ++ ": terminate reason: ~p~n", [_Reason]).



%%%% OTHER STUFF


random_atom(Len) ->
    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    ChrsSize = size(Chrs),
    {A1, A2, A3} = now(),
    random:seed(A1,A2,A3),
    F = fun(_, R) -> [element(random:uniform(ChrsSize), Chrs) | R] end,
    List = lists:foldl(F, "", lists:seq(1, Len)),
    list_to_atom(List).

%% @spec timestamp(Now) -> string()
%% @doc Generates a fancy looking timestamp, found on:
%%		http://erlang.2086793.n4.nabble.com/formatting-timestamps-td3594191.html
timestamp(Now) -> 
    {_, _, Micros} = Now, 
    {{YY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(Now), 
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~p", 
                  [YY, MM, DD, Hour, Min, Sec, Micros]).