%% -----------------------------------------------------------------------------
%%
%% Erlang System Monitoring Tools: World Server*
%%
%% Copyright (c) 2010 Tim Watson (watson.timothy@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
%% @author Tim Watson [http://hyperthunk.wordpress.com]
%% @copyright (c) Tim Watson, 2010
%% @since: May 2010
%%
%% Provides a server that holds the "current state of the world", in terms of
%% an erlang cluster (list of nodes, node configuration info, connectivity
%% between nodes, etc). The name is a nod to the stdlib (net_adm:world).
%%
%% -----------------------------------------------------------------------------

-module(dxkit_world_server).
-author('Tim Watson <watson.timothy@gmail.com>').

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start/0, start/1, start_link/1]).

-export([nodes/0]).

-behavior(gen_server2).

-include("../include/nodewatch.hrl").
-include("dxkit.hrl").

-record(wstate, {
    start_ts        :: timestamp(),
    timeout         :: integer(),
    options  = []   :: [{atom(), term()}],
    nodes           :: term()
}).

-type(server_option()   :: {refresh, {interval(), unit_of_measure()}} |
                           {startup, {scan, all}} |
                           {nodes, [node()]}).

-define(DEFAULT_TIMEOUT, 60000).

%% -----------------------------------------------------------------------------
%%      Public API
%% -----------------------------------------------------------------------------

%%
%% @doc Starts the server without any configuration.
%%
start() ->
    start([]).

%%
%% @doc Starts the server with the supplied configuration.
%%
%% Options = [
%%            {refresh, {Interval, UnitOfMeasure}}, connection refresh policy |
%%            {startup, {scan, all}}, scan for nodes using net_adm:world/1 |
%%            {nodes, [node()]}, list of nodes to connect
%%            ]
%%
-spec(start/1 :: (Options::[server_option()]) -> term()).
start(Options) ->
    gen_server2:start({local, ?MODULE}, ?MODULE, Options, []).

%%
%% @doc Starts the server with the supplied configuration.
%%
-spec(start_link/1 :: (Options::[server_option()]) -> term()).
start_link(Options) ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, Options, []).

nodes() ->
    gen_server:call(?MODULE, nodes).

%% -----------------------------------------------------------------------------
%% gen_server2 callbacks
%% -----------------------------------------------------------------------------

%% @hidden
init(Args) ->
    process_flag(trap_exit, true),
    Start = erlang:now(), End = Start,
    Timestamp = ?TS(Start, End),
    Timeout = refresh_interval(Args),
    State = #wstate{start_ts=Timestamp,
                    timeout=Timeout,
                    options=Args,
                    nodes=ets:new(dx.world.nodes, [{keypos, 2}])},
    %% discovery takes place out of band as this can block for a while....
    set_timer(Timeout),
    case net_kernel:monitor_nodes(true, [{node_type, all}, nodedown_reason]) of
        ok  -> {ok, State};
        Err -> {stop, Err}
    end.

handle_call(nodes, {_From, _Tag}, #wstate{nodes=Tab}=State) ->
    {reply, ets:tab2list(Tab), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node}, State) ->
    reset_state({nodeup, Node, []}, State);
handle_info({nodeup, Node, InfoList}, State) ->
    reset_state({nodeup, Node, InfoList}, State);
handle_info({nodedown, Node}, State) ->
    reset_state({nodedown, Node, []}, State);
handle_info({nodedown, Node, InfoList}, State) ->
    reset_state({nodedown, Node, InfoList}, State);
handle_info({timeout, _TRef, refresh},
            #wstate{nodes=Tab, options=Opt, timeout=Timeout}=State) ->
    Nodes = case lists:keyfind(nodes, 1, Opt) of
        {nodes, N} -> N;
        _ -> []
    end,
    %% FIXME: if find_nodes regularly takes longer than the timeout,
    %%  we need to `up' the timeout accordingly...
    Scan = case lists:keyfind(startup, 1, Opt) of
        {startup, {scan, all}} ->
            dxkit_net:find_nodes();
        {startup, {scan, Hosts}} when is_list(Hosts) ->
            lists:flatten([dxkit_net:find_nodes(Host) || Host <- Hosts]);
        _ -> []
    end,
    NodeList = lists:concat([Nodes, Scan]),
    fastlog:debug("[World] Revising NodeSet = ~p~n", [NodeList]),
    [ets:insert(Tab, dxkit_net:connect(N)) || N <- NodeList, 
                                              N =/= node()],
    spawn(fun() -> 
        gen_event:notify(dxkit_event_handler, 
            {world, refresh}) end),                                          
    set_timer(Timeout),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -----------------------------------------------------------------------------
%%      Private API
%% -----------------------------------------------------------------------------

set_timer(Timeout) ->
    fastlog:debug("[World] Starting refresh timer with a ~p ms interval.~n", [Timeout]),
    erlang:start_timer(Timeout, ?MODULE, refresh).

reset_state({NodeStatus, Node, InfoList}, #wstate{nodes=Tab}=State) ->
    fastlog:debug("[World] Node ~p status change: ~p~n", [Node, NodeStatus]),
    NodeInfo = case ets:lookup(Tab, Node) of
        [NI] ->
            dxkit_net:update_node(NI, {NodeStatus, InfoList});
        _ ->
            dxkit_net:connect(Node)
    end,
    ets:insert(Tab, NodeInfo),
    spawn(fun() -> 
        gen_event:notify(dxkit_event_handler, 
            {world, {NodeStatus, NodeInfo}}) end),
    {noreply, State}.

refresh_interval(Config) ->
    %% TODO: move this into init/reconfigure so it isn't running so often
    case lists:keytake(refresh, 1, Config) of
        {value, {refresh, {Int, Uom}}, _} ->
            case Uom of
                milliseconds -> Int;
                _ -> apply(timer, Uom, [Int])
            end;
        {value, {refresh, Millis}, _} ->
            Millis;
        _ ->
            ?DEFAULT_TIMEOUT
    end.
