%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc OpenFlow Wire Protocol client.
-module(ofp_client).

-behaviour(gen_server).

%% API
-export([start_link/0,
         start_link/1,
         start_link/2,
         start_link/3,
         controlling_process/2,
         send/2,
         stop/1]).

%% Internal API
-export([make_slave/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("of_protocol.hrl").

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 6633).
-define(DEFAULT_TIMEOUT, timer:seconds(5)).

-record(state, {
          controller :: {string(), integer()},
          parent :: pid(),
          versions :: integer(),
          role = equal :: master | equal | slave,
          generation_id :: integer(),
          filter = {{true, true, true}, {true, false, false}},
          socket :: inets:socket(),
          parser :: record(),
          timeout :: integer()
         }).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

start_link() ->
    start_link(?DEFAULT_HOST).

start_link(Host) ->
    start_link(Host, ?DEFAULT_PORT).

start_link(Host, Port) ->
    start_link(Host, Port, [{version, ?DEFAULT_VERSION}]).

%% @doc Start the client.
-spec start_link(string(), integer(),
                 proplists:proplist()) -> {ok, Pid :: pid()} | ignore |
                                          {error, Error :: term()}.
start_link(Host, Port, Opts) ->
    Parent = get_opt(controlling_process, Opts, self()),
    gen_server:start_link(?MODULE, {{Host, Port}, Parent, Opts}, []).

%% @doc Change the controlling process.
-spec controlling_process(pid(), pid()) -> ok.
controlling_process(Pid, ControllingPid) ->
    gen_server:call(Pid, {controlling_process, ControllingPid}).

%% @doc Send a message.
%% Valid messages include all the reply and async messages from all version of
%% the OpenFlow Protocol specification. Attempt so send any other message will
%% result in {error, {bad_message, Message :: ofp_message()}}.
-spec send(pid(), ofp_message()) -> ok | {error, Reason :: term()}.
send(Pid, Message) ->
    case Message#ofp_message.type of
        Type when Type == error;
                  Type == echo_reply;
                  Type == features_reply;
                  Type == get_config_reply;
                  Type == packet_in;
                  Type == flow_removed;
                  Type == port_status;
                  Type == stats_reply;
                  Type == multipart_reply;
                  Type == barrier_reply;
                  Type == queue_get_config_reply;
                  Type == role_reply;
                  Type == get_async_reply ->
            gen_server:call(Pid, {send, Message});
        _Else ->
            {error, {bad_message, Message}}
    end.

%% @doc Stop the client.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

make_slave(Pid) ->
    gen_server:call(Pid, make_slave).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init({Controller, Parent, Opts}) ->
    Version = get_opt(version, Opts, ?DEFAULT_VERSION),
    Versions = lists:umerge(get_opt(versions, Opts, []), [Version]),
    Timeout = get_opt(timeout, Opts, ?DEFAULT_TIMEOUT),
    {ok, #state{controller = Controller,
                parent = Parent,
                versions = Versions,
                timeout = Timeout}, 0}.

handle_call({send, _Message}, _From, #state{socket = undefined} = State) ->
    {reply, {error, not_connected}, State};
handle_call({send, Message}, _From,
            #state{role = Role, filter = Filter} = State) ->
    case filter_message(Message, Role, Filter) of
        true ->
            {reply, do_send(Message, State), State};
        false ->
            {reply, {error, filtered}, State}
    end;
handle_call({controlling_process, Pid}, _From, State) ->
    {reply, ok, State#state{parent = Pid}};
handle_call(make_slave, _From, #state{role = master} = State) ->
    {reply, ok, State#state{role = slave}};
handle_call(stop, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(timeout, #state{controller = {Host, Port},
                            versions = Versions,
                            timeout = Timeout} = State) ->
    %% Try to connect to the controller
    TCPOpts = [binary, {active, once}],
    case gen_tcp:connect(Host, Port, TCPOpts) of
        {ok, Socket} ->
            {ok, HelloBin} = of_protocol:encode(create_hello(Versions)),
            ok = gen_tcp:send(Socket, HelloBin),
            {noreply, State#state{socket = Socket}};
        {error, _Reason} ->
            {noreply, State, Timeout}
    end;
handle_info({tcp, Socket, Data}, #state{socket = Socket,
                                        parent = Parent,
                                        parser = undefined,
                                        versions = Versions} = State) ->
    inet:setopts(Socket, [{active, once}]),
    
    %% Wait for hello
    case of_protocol:decode(Data) of
        {ok, #ofp_message{body = #ofp_hello{}} = Hello, Leftovers} ->
            case decide_on_version(Versions, Hello) of
                {unsupported_version, _} = Reason ->
                    reset_connection(State, Reason);
                {no_common_version, _, _} = Reason ->
                    reset_connection(State, Reason);
                Version ->
                    Parent ! {ofp_connected, self(), Version},
                    {ok, Parser} = ofp_parser:new(Version),
                    self() ! {tcp, Socket, Leftovers},
                    {noreply, State#state{parser = Parser}}
            end;
        _Else ->
            reset_connection(State, bad_initial_message)
    end;
handle_info({tcp, Socket, Data}, #state{socket = Socket,
                                        parser = Parser} = State) ->
    inet:setopts(Socket, [{active, once}]),

    case ofp_parser:parse(Parser, Data) of
        {ok, NewParser, Messages} ->
            Handle = fun(Message, Acc) ->
                             handle_message(Message, Acc)
                     end,
            NewState = lists:foldl(Handle, State, Messages),
            {noreply, NewState#state{parser = NewParser}};
        _Else ->
            reset_connection(State, {bad_data, Data})
    end;
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    reset_connection(State, tcp_closed);
handle_info({tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    reset_connection(State, {tcp_error, Reason});
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

do_send(Message, #state{socket = Socket, parser = Parser}) ->
    case ofp_parser:encode(Parser, Message) of
        {ok, Binary} ->
            gen_tcp:send(Socket, Binary);
        {error, Reason} ->
            {error, Reason}
    end.

handle_message(#ofp_message{version = Version, type = Type} = Message,
               #state{role = slave} = State)
  when Type == flow_mod;
       Type == group_mod;
       Type == port_mod;
       Type == table_mod;
       Type == meter_mod ->
    %% Don't allow slave controllers to modify things.
    Error = create_error(Version, bad_request, is_slave),
    IsSlaveError = Message#ofp_message{type = error, body = Error},
    do_send(IsSlaveError, State);
handle_message(#ofp_message{type = Type} = Message,
               #state{parent = Parent} = State)
  when Type == echo_request;
       Type == features_request;
       Type == get_config_request;
       Type == set_config;
       Type == packet_out;
       Type == flow_mod;
       Type == group_mod;
       Type == port_mod;
       Type == table_mod;
       Type == stats_request;
       Type == barrier_request;
       Type == queue_get_config_request;
       Type == meter_mod ->
    Parent ! {ofp_message, self(), Message},
    State;
%% handle_message(#ofp_message{type = role_request, body = RoleRequest},
%%                #state{role = _Role} = State) ->
%%     State;
%% handle_message(#ofp_message{type = get_async_request, body = GetAsync},
%%                #state{filter = _Filter} = State) ->
%%     State;
%% handle_message(#ofp_message{type = set_async, body = SetAsync},
%%                #state{filter = _Filter} = State) ->
%%     State;
handle_message(_OtherMessage, State) ->
    State.

create_hello(Versions) ->
    Version = lists:max(Versions),
    Body = if
               Version >= 4 ->
                   #ofp_hello{elements = [{versionbitmap, Versions}]};
               true ->
                   #ofp_hello{}
           end,
    #ofp_message{version = Version, xid = 0, body = Body}.

decide_on_version(CVersions, #ofp_message{version = SVersion, body = Body}) ->
    CVersion = lists:max(CVersions),
    if
        CVersion >= 4 ->
            case CVersion == SVersion of
                true ->
                    CVersion;
                false ->
                    Elements = Body#ofp_hello.elements,
                    SVersions = get_opt(versionbitmap, Elements, [SVersion]),
                    case gcv(CVersions, SVersions) of
                        no_common_version ->
                            {no_common_version, CVersions, SVersions};
                        Version ->
                            Version
                    end
            end;
        true ->
            case lists:member(SVersion, CVersions) of
                true ->
                    SVersion;
                false ->
                    {unsupported_version, SVersion}
            end
    end.

filter_message(#ofp_message{type = Type}, Role, {MasterEqual, Slave}) ->
    {PacketIn, PortStatus, FlowRemoved} =
        case Role of
            slave ->
                Slave;
            _Else ->
                MasterEqual
        end,
    case Type of
        packet_in ->
            PacketIn;
        port_status ->
            PortStatus;
        flow_removed ->
            FlowRemoved;
        _Other ->
            true
    end.

%%------------------------------------------------------------------------------
%% Helper functions
%%------------------------------------------------------------------------------

get_opt(Opt, Opts, Default) ->
    case lists:keyfind(Opt, 1, Opts) of
        false ->
            Default;
        {Opt, Value} ->
            Value
    end.

%% @doc Greatest common version.
gcv([], _) ->
    no_common_version;
gcv(_, []) ->
    no_common_version;
gcv([CV | _], [SV | _]) when CV == SV ->
    CV;
gcv([CV | CVs], [SV | _] = SVs) when CV > SV ->
    gcv(CVs, SVs);
gcv([CV | _] = CVs, [SV | SVs]) when CV < SV ->
    gcv(CVs, SVs).

reset_connection(#state{socket = Socket,
                        parent = Parent,
                        timeout = Timeout} = State, Reason) ->
    %% Close the socket
    case Socket of
        undefined ->
            ok;
        Socket ->
            gen_tcp:close(Socket)
    end,

    %% Notify the parent
    Parent ! {ofp_closed, self(), Reason},

    %% Reset
    {noreply, State#state{socket = undefined,
                          parser = undefined}, Timeout}.

create_error(3, Type, Code) ->
    ofp_client_v3:create_error(Type, Code);
create_error(4, Type, Code) ->
    ofp_client_v4:create_error(Type, Code).

%% create_role(3, Role, GenId) ->
%%     ofp_client_v3:create_role(Role, GenId);
%% create_role(4, Role, GenId) ->
%%     ofp_client_v4:create_role(Role, GenId).

%% extract_role(3, RoleRequest) ->
%%     ofp_client_v3:extract_role(RoleRequest);
%% extract_role(4, RoleRequest) ->
%%     ofp_client_v4:extract_role(RoleRequest).

%% create_async(4, Masks) ->
%%     ofp_client_v4:create_async(Masks).

%% extract_async(4, Async) ->
%%     ofp_client_v4:extract_async(Async).
