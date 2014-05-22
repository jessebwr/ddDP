%%% -------------------------------------------------------------------
%%% CSCI182E - Distributed Systems
%%% @author Jesse Watts-Russell and David Scott
%%% @copyright ChickenFartStory Inc. 2015, All rights reserved
%%%
%%% @doc A Generic Server Implementation of a Philosopher, accepting the
%%%		 commands specified by the assignment, implementing the
%%%		 algorithm specified in algorithm.pdf, and supplying some
%%%		 extra info utilities.
%%% @end
%%%--------------------------------------------------------------------

-module(philosopher).
-behavior(gen_server).

%% External exports
-export([main/1]).

%% gen_server callbacks
-export([init/1, 
		 handle_call/3, 
		 handle_cast/2, 
		 handle_info/2, 
		 code_change/3, 
		 terminate/2]).

-define(PROCNAME, philosopher).
-define(STATES, [joining, thinking, hungry, eating, leaving, gone]).

-record(state, {currState,
				hungRef, hungPid, stopRef, stopPid, leaveRef, leavePid,
				nodeDict,
				numJoinRequestsSent, numJoinResponses,
				forkQueue, edgeQueue
				}).

%% nodeDict entry of the form node() :  {clean/dirty/donthave, monitorRef}

%%%============================================================================
%%% API
%%%============================================================================

main(Args) ->
	[ NodeName | NodesToConnectTo ] = Args,
	os:cmd("epmd -daemon"),
	net_kernel:start([list_to_atom(NodeName), shortnames]),
	io:format(timestamp (now()) ++ ": Initializing The Philosopher " ++ atom_to_list(node()) ++ ".~n"),
	gen_server:start({local, ?PROCNAME}, philosopher, {NodesToConnectTo}, []).


%%%============================================================================
%%% GenServer Calls/Casts
%%%============================================================================


%%%============================================================================
%%% GenServer Callbacks (For the rest of the code)
%%%============================================================================

%% @spec init({NodesToConnectTo}) -> {ok, State}.
%% @doc Starts in joining state and sends connectToMePLZ requests to specified
%%		nodes.
init({NodesToConnectTo}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: joining] Trying to connect to all specified nodes.~n"),
	AtomNodes = lists:map(fun(X) -> list_to_atom(X) end, NodesToConnectTo),
	NumRequests = length(AtomNodes),
	NodeDict = dict:new(),
	process_flag(trap_exit, true),
	case NodesToConnectTo of
		[] -> 
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: joining] There were no nodes, transitioning to thinking.~n"),
			{ok, #state{currState = thinking, nodeDict = NodeDict,
						numJoinRequestsSent = 0, 
						numJoinResponses = 0,
						forkQueue = [], edgeQueue = []}};
		_else ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: joining] Sending requests to specified nodes.~n"),
			gen_server:abcast(AtomNodes, ?PROCNAME, {node(), connectToMePLZ}),
			{ok, #state{currState = joining, nodeDict = NodeDict,
						numJoinRequestsSent = NumRequests, 
						numJoinResponses = 0,
						forkQueue = [], edgeQueue = []}}
	end.
	




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% SYNCRHONOUS MESSAGES FROM OTHER PHILOSOPHERS %%%%%%%%%%%%%%%%%%

%% Note that these are mainly for testing purposes
handle_call(getState, _FromWhoeverDuntMatter, S) ->
	{reply, S#state.currState, S};

handle_call(getNeighbors, _FromWhoeverDuntMatter, S) ->
	{reply, dict:fetch_keys(S#state.nodeDict), S};

handle_call(listForks, _FromWhoeverDuntMatter, S) ->
	DictOfPresentForks = dict:filter(
						fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
							end, S#state.nodeDict),
	ListOfPresentForks = dict:to_list(DictOfPresentForks),
	{reply, ListOfPresentForks, S};


%% @spec handle_call({Node, bye}, S) -> {noreply, State}
%% @doc Handle when other nodes are about to leave. Erase that node from my
%%      dictionary. If we are leaving or hungry, we check if we now have all
%%		required forks and if we do, transition to gone/eating respectivly.
%%	    This is done synchronously in order to ensure the last safety property
%%	    is obeyed by the system at all times; in the algorithmic description
%%	    the same effect is achieved by requiring "bye" or "leaving" messages
%%	    to be acnowledged.
%% 		For some reason, when dealing with records in Erlang, assignment is to
%%		left-to-right.
%%		When a node leaves, we need to demonitor it, and additionally flush
%%		the buffer of messages from it so that they aren't kept around
%%		uselessly.
%%		It is worth noting that gen_server:multi_call/3 blocks the entire
%%		Gen Server.  In the algorithm, when we are leaving and have all our
%%		forks, we make all our forks clean in order to prevent losing forks
%%		in the time it takes to get our acknowledgements.  Here, since the
%%		entire Gen Server is blocked while awaiting acknowledgements, we don't
%%		need to worry about that issue at all.
handle_call({Node, bye}, _From, S = #state{currState = CurrState, 
				nodeDict = NodeDict}) when 
				(CurrState == thinking) or (CurrState == joining) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p is just about to leave, so I'm removing him from my neighbors.~n", [CurrState, Node]),
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	erlang:demonitor(NodeMonitorRef,[flush]),
	NewDict = dict:erase(Node, NodeDict),
	{reply, moo, S#state{nodeDict = NewDict}};

handle_call({Node, bye}, _From, S = #state{currState = hungry, nodeDict = NodeDict}) ->
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	erlang:demonitor(NodeMonitorRef,[flush]),
	NewDict = dict:erase(Node, NodeDict),
	ForkQueue = lists:delete(Node, S#state.forkQueue),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewDict),
	case dict:size(DictOfPresentForks) == dict:size(NewDict) of
		true ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p is just about to leave, so I'm removing him from my neighbors. But with him gone, I have all my forks so I'm gonna transition to eating.~n", [hungry, Node]),
			S#state.hungPid ! {S#state.hungRef, eating},
			{reply, moo,  S#state{currState = eating, nodeDict = NewDict, forkQueue = ForkQueue}};
		false ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p is just about to leave, so I'm removing him from my neighbors. I still don't have all my forks to eat.~n", [hungry, Node]),
			{reply, moo, S#state{nodeDict = NewDict, forkQueue = ForkQueue}}
	end;

handle_call({Node, bye}, _From, S = #state{currState = leaving, nodeDict = NodeDict}) ->
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	erlang:demonitor(NodeMonitorRef,[flush]),
	NewDict = dict:erase(Node, NodeDict),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewDict),
	case dict:size(DictOfPresentForks) == dict:size(NewDict) of
		true ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p is just about to leave, so I'm removing him from my neighbors. But with him gone, I have all my forks so I'm gonna transition to gone.~n", [leaving, Node]), 
			NewNodeList = dict:fetch_keys(NewDict),
			gen_server:multi_call(NewNodeList, ?PROCNAME, {node(), bye}),
			terminate(normal, S);
		false ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p is just about to leave, so I'm removing him from my neighbors. I still don't have all my forks to leave.~n", [leaving, Node]),
			{reply, moo, S#state{nodeDict = NewDict}}
	end.



%%%%%%%%%%%%% END SYNCRHONOUS MESSAGES FROM OTHER PHILOSOPHERS %%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% ASYNCRHONOUS MESSAGES FROM OTHER PHILOSOPHERS %%%%%%%%%%%%%%%%%

%% @spec handle_cast({Node, connectToMePLZ}, S) -> {noreply, State}
%% @doc Handle requests for connection (from new nodes) during each state.
%% 		Add the new node to the local record's node dictionary, and set up
%%		a monitor on that new node.  If I'm hungry, immediately request the
%%		new guy's fork; if I'm eating, enqueue the request for later.
handle_cast({Node, connectToMePLZ}, S = #state{currState = CurrState}) when
			(CurrState == thinking) or (CurrState == joining)->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a edge request, immediately connecting to new node ~p.~n", [CurrState, Node]),
	NodeDict = S#state.nodeDict,
	NodeMonitorRef = erlang:monitor(process, {philosopher, Node}),
	NewNodeDict = dict:store(Node, {donthave, NodeMonitorRef}, NodeDict),
	gen_server:cast({?PROCNAME, Node}, {node(), connected}),
	{noreply, S#state{nodeDict = NewNodeDict}};

handle_cast({Node, connectToMePLZ}, S = #state{currState = CurrState}) when
			(CurrState == hungry) or (CurrState == leaving)->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a edge request, immediately connecting to new node ~p followed by a request for that edge's fork.~n", [CurrState, Node]),
	NodeDict = S#state.nodeDict,
	NodeMonitorRef = erlang:monitor(process, {philosopher, Node}),
	NewNodeDict = dict:store(Node, {donthave, NodeMonitorRef}, NodeDict),
	gen_server:cast({?PROCNAME, Node}, {node(), connected}),
	gen_server:cast({?PROCNAME, Node}, {node(), gimmeTheFork}),
	{noreply, S#state{nodeDict = NewNodeDict}};

handle_cast({Node, connectToMePLZ}, S = #state{currState = eating}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a edge request from ~p, queing that request for after.~n", [eating, Node]),
	EdgeQueue = S#state.edgeQueue ++ [Node],
	{noreply, S#state{edgeQueue = EdgeQueue}};



%% @spec handle_cast({Node, connected}, S) -> {noreply, State}
%% @doc Handles when nodes acknowledge a newly added node. We can either
%%		stay joining, or move to thinking, when we get all of the
%%		acknowledgements back.
handle_cast({Node, connected}, S = #state{currState = joining}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received edge confirmation from ~p.~n", [joining, Node]),
	NodeDict = S#state.nodeDict,
	NumRequestsSent = S#state.numJoinRequestsSent,
	NumResponses = S#state.numJoinResponses + 1,
	NodeMonitorRef = erlang:monitor(process, {philosopher, Node}),
	NewNodeDict = dict:store(Node, {dirty, NodeMonitorRef}, NodeDict),

	case NumRequestsSent == NumResponses of
		true -> 
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received all edge confirmations, transitioning to thinking.~n", [joining]),
			{noreply, S#state{nodeDict = NewNodeDict, 
							  numJoinResponses = NumResponses,
							  currState = thinking}};
		false ->
			{noreply, S#state{nodeDict = NewNodeDict, 
							  numJoinResponses = NumResponses,
							  currState = joining}}
	end;			



%% @spec handle_cast({Node, gimmeTheFork}, S) -> {noreply, State}
%% @doc Handle requests for forks. If we are joining or thinking, we just
%%		pass off the fork to the guy who requested it.
%%		If we are hungry or leaving, we check if our fork is dirty... if it is
%%		then we send it off to the guy who requested it, and immediately send
%%		a request for it. If it is clean or we are eating, then we queue up
%%		the fork request and handle it when we are done eating/leaving.
handle_cast({Node, gimmeTheFork}, S = #state{currState = CurrState}) 
			when (CurrState == joining) or (CurrState == thinking) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p, granting the request.~n", [CurrState, Node]),
	NodeDict = S#state.nodeDict,
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	NewNodeDict = dict:store(Node, {donthave, NodeMonitorRef}, NodeDict),
	gen_server:cast({?PROCNAME, Node}, {node(), heresTheFork}),
	{noreply, S#state{nodeDict = NewNodeDict}};

handle_cast({Node, gimmeTheFork}, S = #state{currState = CurrState}) when
		(CurrState == hungry) ->
	{MyForkState, NodeMonitorRef} = dict:fetch(Node, S#state.nodeDict),
	case MyForkState of 
		clean ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p, but my fork is clean, so queing that request up.~n", [CurrState, Node]),
			ForkQueue = S#state.forkQueue ++ [Node],
			{noreply, S#state{forkQueue = ForkQueue}};
		dirty ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p and my fork is dirty, so sending the fork over and immediately making a request for it.~n", [CurrState, Node]),
			NodeDict = S#state.nodeDict,
			NewNodeDict = dict:store(Node, {donthave, NodeMonitorRef}, NodeDict),
			gen_server:cast({?PROCNAME, Node}, {node(), heresTheFork}),	
			gen_server:cast({?PROCNAME, Node}, {node(), gimmeTheFork}),
			{noreply, S#state{nodeDict = NewNodeDict}}
	end;

handle_cast({Node, gimmeTheFork}, S = #state{currState = CurrState}) when
		(CurrState == leaving) ->
	{MyForkState, NodeMonitorRef} = dict:fetch(Node, S#state.nodeDict),
	case MyForkState of 
		clean ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p, but my fork is clean, so ignoring that request.~n", [CurrState, Node]),
			{noreply, S};
		dirty ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p and my fork is dirty, so sending the fork over and immediately making a request for it.~n", [CurrState, Node]),
			NodeDict = S#state.nodeDict,
			NewNodeDict = dict:store(Node, {donthave, NodeMonitorRef}, NodeDict),
			gen_server:cast({?PROCNAME, Node}, {node(), heresTheFork}),	
			gen_server:cast({?PROCNAME, Node}, {node(), gimmeTheFork}),
			{noreply, S#state{nodeDict = NewNodeDict}}
	end;

handle_cast({Node, gimmeTheFork}, S = #state{currState = eating}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Got a fork request from ~p, but I'm eating, so queing that request up.~n", [eating, Node]),
	ForkQueue = S#state.forkQueue ++ [Node],
	{noreply, S#state{forkQueue = ForkQueue}};



%% @spec handle_cast({Node, heresTheFork}, S) -> {noreply, State}
%% @doc Handles when we get a fork we previously asked for. We either enter
%%		leaving or eating once we acquire all our forks.
handle_cast({Node, heresTheFork}, S = #state{currState = hungry}) ->
	NodeDict = S#state.nodeDict,
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	NewNodeDict = dict:store(Node, {clean, NodeMonitorRef}, NodeDict),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewNodeDict),
	case dict:size(DictOfPresentForks) == dict:size(NodeDict) of
		true ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received a fork from ~p. Now I have all of them so I'm gonna transition to eating.~n", [hungry, Node]),
			S#state.hungPid ! {S#state.hungRef, eating},
			{noreply, S#state{currState = eating, nodeDict = NewNodeDict}};
		false ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received a fork from ~p. Waiting for the rest of them.~n", [hungry, Node]),
			{noreply, S#state{nodeDict = NewNodeDict}}
	end;

handle_cast({Node, heresTheFork}, S = #state{currState = leaving}) ->
	NodeDict = S#state.nodeDict,
	{_ , NodeMonitorRef} = dict:fetch(Node, NodeDict),
	NewNodeDict = dict:store(Node, {clean, NodeMonitorRef}, NodeDict),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewNodeDict),
	case dict:size(DictOfPresentForks) == dict:size(NodeDict) of
		true ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received a fork from ~p. Now I have all of them so I'm gonna transition to gone.~n", [leaving, Node]),
			NewNodeList = dict:fetch_keys(NewNodeDict),
			gen_server:multi_call(NewNodeList, ?PROCNAME, {node(), bye}),
			terminate(normal, S);
		false ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Received a fork from ~p. Waiting for the rest of them.~n", [leaving, Node]),
			{noreply, S#state{nodeDict = NewNodeDict}}
	end.




%%%%%%%%%%%%% END ASYNCRHONOUS MESSAGES FROM OTHER PHILOSOPHERS %%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%% MESSAGES FROM THE CONTROLLER %%%%%%%%%%%%%%%%%%%%%%%%%%%


%% @spec handle_info({Pid, Ref, become_hungry}, 
%%					S = #state{currState = thinking}) -> {noreply, State}
%%
%% @doc Receive the become_hungry request from the external controller
%%		and change our state to hungry after sending requests out to all our
%%		peers. If we already have all the forks, transition to eating
handle_info({Pid, Ref, become_hungry}, S = #state{currState = thinking}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to become hungry by ~p.~n", [thinking, Pid]),
	NodeDict = S#state.nodeDict,
	ListOfNodes = dict:fetch_keys(dict:filter(
					fun(_Key, {Fork, _}) -> Fork == donthave end, NodeDict)),

	case ListOfNodes of
		[] -> 
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I have all my forks, so I can just transition to eating.~n", [hungry]),
			Pid ! {Ref, eating},
			{noreply, S#state{currState = eating, hungRef = Ref, hungPid=Pid}};
		_Else ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Sending out requests for forks.~n", [hungry]),
			gen_server:abcast(ListOfNodes, ?PROCNAME, {node(), gimmeTheFork}),
			{noreply, S#state{currState = hungry, hungRef = Ref, hungPid=Pid}}
	end;

%% @spec handle_info({Pid, Ref, stop_eating}, 
%%					S = #state{currState = thinking}) -> {noreply, State}
%%
%% @doc Receive the stop_eating request from the external controller. We change
%%		to the thinking state, and then fill all edge and fork requests that
%%		were pending.
handle_info({Pid, Ref, stop_eating}, S = #state{currState = eating}) ->
	EdgeQueue = S#state.edgeQueue,
	io:format(timestamp(now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to stop eating by ~p, so I'll satisfy all my queue requests then transition to thinking.~n", [eating, Pid]),
	DirtyDict = dict:map(fun(_Key,{_Fork, NodeMonitorRef}) -> 
						{dirty, NodeMonitorRef} end, S#state.nodeDict),
	ForkQueue = S#state.forkQueue,
	DictAfterEdges = handleForkQueue(ForkQueue, DirtyDict),
	NewDict = handleEdgeQueue(EdgeQueue, DictAfterEdges, eating),
	{noreply, S#state{currState = thinking, stopRef = Ref, stopPid = Pid,
					nodeDict = NewDict,
					forkQueue = [], edgeQueue = []}};

%% @spec handle_info({Pid, Ref, leave}, S) -> {noreply, State}
%%
%% @doc Receive the leave request from the external controller. We change
%%		to the leaving state, and call for all forks we don't have.
handle_info({Pid, Ref, leave}, S = #state{currState = CurrState})
												when CurrState /= joining ->
	case CurrState of 
		eating ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to leave by ~p, so I'll satisfy all my edge queue requests then transition to leaving. ~n", [CurrState, Pid]),
			EdgeQueue = S#state.edgeQueue,
			NewNodeList = dict:fetch_keys(handleEdgeQueue(EdgeQueue, 
										S#state.nodeDict, CurrState)),
			gen_server:multi_call(NewNodeList, ?PROCNAME, {node(), bye}),
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: leaving] I've got all my forks so I'm gone.~n"),
			terminate(normal, S#state{leaveRef = Ref, leavePid = Pid});
		hungry ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to leave by ~p, so I'll just switch to leaving.~n", [CurrState, Pid]),
			{noreply, S#state{currState = leaving, 
							leaveRef = Ref, leavePid = Pid}};
		thinking ->
			NodeList = dict:fetch_keys(S#state.nodeDict),
			case NodeList of 
				[] -> 
					io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to leave by ~p, and I don't have any neighbors, so I'm just gonna go.~n", [CurrState, Pid]),
					terminate(normal, S#state{leaveRef = Ref, leavePid = Pid});
				_Else ->
					io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've been told to leave by ~p, so I'm requesting all my forks and entering the leaving state.~n", [CurrState, Pid]),
					NodeDict = S#state.nodeDict,

					ListOfNodes = dict:fetch_keys(dict:filter(
						fun(_Key, {Fork, _}) -> Fork==donthave end, NodeDict)),
					lists:foreach(fun(Node) -> 
						gen_server:cast({?PROCNAME, Node}, 
							{node(), gimmeTheFork}) end, ListOfNodes),
					{noreply, S#state{currState = leaving, 
						leaveRef = Ref, leavePid = Pid}}
			end;
		leaving ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I've already been told to leave, stop harassing me.~n", [CurrState]),
			Pid ! {Ref, badcommand, leave, node(), CurrState},
			{noreply, S}
	end;



%%%%%%%%%%%%%%%%%%% END MESSAGES FROM THE CONTROLLER %%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%% EXTRA CREDIT STUFF %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @spec handle_info({'DOWN',_,_,{philosopher, Node},_},S) -> {noreply, State}
%%
%% @doc Handles when a node goes down unexpectedly. Removes that node from
%%		your dictionary and acts accordingly.
handle_info({'DOWN',_,_,{philosopher, Node},_}, 
		S = #state{currState = CurrState, nodeDict = NodeDict}) when 
			(CurrState == thinking) or (CurrState == joining) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Holy poop. ~p just died. I'm cleaning up right now by just removing him from my neighbors.~n", [CurrState, Node]),	
	NewDict = dict:erase(Node, NodeDict),
	{noreply, S#state{nodeDict = NewDict}};

handle_info({'DOWN',_,_,{philosopher, Node},_}, 
		S = #state{currState = hungry, nodeDict = NodeDict}) ->	
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Holy poop. ~p just died. I'm cleaning up right now by just removing him from my neighbors and my Fork Queue.~n", [hungry, Node]),	
	NewDict = dict:erase(Node, NodeDict),
	ForkQueue = lists:delete(Node, S#state.forkQueue),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewDict),
	case dict:size(DictOfPresentForks) == dict:size(NewDict) of
		true ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Well after ~p just died it seems I have all my forks to eat. So entering eating state.~n", [hungry, Node]),	
			S#state.hungPid ! {S#state.hungRef, eating},
			{noreply, S#state{currState = eating, nodeDict = NewDict, 
				forkQueue = ForkQueue}};
		false ->
			{noreply, S#state{nodeDict = NewDict, forkQueue = ForkQueue}}
	end;

handle_info({'DOWN',_,_,{philosopher, Node},_}, 
		S = #state{currState = leaving, nodeDict = NodeDict}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Holy poop. ~p just died. I'm cleaning up right now by just removing him from my neighbors.~n", [leaving, Node]),	
	NewDict = dict:erase(Node, NodeDict),
	NewNodeList = dict:fetch_keys(NewDict),
	DictOfPresentForks = dict:filter(
					fun(_Key, {Fork, _}) -> (Fork == clean) or (Fork == dirty) 
						end, NewDict),
	case dict:size(DictOfPresentForks) == dict:size(NewDict) of
		true ->
			gen_server:multi_call(NewNodeList, ?PROCNAME, {node(), bye}),
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Well after ~p just died it seems I have all my forks to leave. So entering gone state.~n", [leaving, Node]),
			terminate(normal, S);
		false ->
			{noreply, S#state{nodeDict = NewDict}}
	end;

handle_info({'DOWN',_,_,{philosopher, Node},_}, 
		S = #state{currState = eating, nodeDict = NodeDict}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] Holy poop. ~p just died. I'm cleaning up right now by just removing him from my neighbors and my Fork Queue.~n", [eating, Node]),
	NewDict = dict:erase(Node, NodeDict),
	ForkQueue = lists:delete(Node, S#state.forkQueue),
	{noreply, S#state{nodeDict = NewDict, forkQueue = ForkQueue}};

%%%%%%%%%%%%%%%%%%%%%%%%% END EXTRA CREDIT STUFF %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% Catch unrecognized info.

handle_info({Pid, Ref, Command}, S = #state{currState = CurrState}) ->
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I am not currently in the right state to ~p.~n", [CurrState, Command]),
	Pid ! {Ref, badcommand, Command, node(), CurrState},
	{noreply, S};

handle_info(E, S) ->
	CurrState = S#state.currState,
    io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] unexpected: ~p~n", 
    													[CurrState, E]),
    {noreply, S}.


%% @spec handleForkQueue(ForkQueue, Dict) -> dict().
%% @doc Passes off forks to all nodes in the queue that have requested them.
handleForkQueue([], Dict) ->
	Dict;
handleForkQueue(ForkQueue, Dict) ->
	[Node | Rest] = ForkQueue,
	{_ , NodeMonitorRef} = dict:fetch(Node, Dict),
	NewDict = dict:store(Node, {donthave, NodeMonitorRef}, Dict),
	gen_server:cast({?PROCNAME, Node}, {node(), heresTheFork}),
	io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I'm done eating, so handing off requested fork to ~p.~n", [eating, Node]),
	handleForkQueue(Rest, NewDict).

%% @spec handleEdgeQueue(EdgeQueue, Dict, CurrState) -> dict()
%% @doc Connects to all nodes that have requested connection.
handleEdgeQueue([], Dict, _CurrState) ->
	Dict;
handleEdgeQueue(EdgeQueue, Dict, CurrState) ->
	[Node | Rest] = EdgeQueue,
	case net_adm:ping(Node) of
		pong ->
			NodeMonitorRef = erlang:monitor(process, {philosopher, Node}),
			NewDict = dict:store(Node, {donthave, NodeMonitorRef}, Dict),
			gen_server:cast({?PROCNAME, Node}, {node(), connected}),
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] I'm done, so handling edge request from ~p.~n", [CurrState, Node]),
			handleEdgeQueue(Rest, NewDict, CurrState);
		pang ->
			io:format(timestamp (now()) ++ ": [NODE: " ++ atom_to_list(node()) ++ ", STATE: ~p] ~p died unexpectedly while I was doing my stuff (while it was enqueued for joining) so I'm just ignoring it.~n", [eating, Node]),
			handleEdgeQueue(Rest, Dict, CurrState)
	end.


% Handling Errors and unused callbacks

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, State) ->
	Pid = State#state.leavePid,
	Ref = State#state.leaveRef,
	Pid ! {Ref, gone},
	erlang:halt(),
    ok;
terminate(_Reason, _State) ->
    io:format(timestamp (now()) ++ ": terminate reason: ~p~n", [_Reason]).

%% @spec timestamp(Now) -> string()
%% @doc Generates a fancy looking timestamp, found on:
%%		http://erlang.2086793.n4.nabble.com/formatting-timestamps-td3594191.html
timestamp(Now) -> 
    {_, _, Micros} = Now, 
    {{YY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_local_time(Now), 
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w.~p", 
                  [YY, MM, DD, Hour, Min, Sec, Micros]). 
