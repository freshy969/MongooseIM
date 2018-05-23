%%%-------------------------------------------------------------------
%%% @author Kacper Mentel <kacper.mentel@erlang-solutions.com>
%%% @copyright (C) 2018, Kacper Mentel
%%% @doc
%%% Generic RabbitMQ worker. The module is responsible for formatting and
%%% sending events to AMQP client. Worker holds it's own AMQP connection and
%%% channel in it's state.
%%% @end
%%%-------------------------------------------------------------------
-module(mongoose_rabbit_worker).

-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2, presence_msg/2]).

-record(state, {connection, channel}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the RabbitMQ worker.
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([{amqp_client_opts, Opts}]) ->
    process_flag(trap_exit, true),
    self() ! {init, Opts},
    {ok, #state{}}.

handle_call({create_exchanges, Exchanges}, _From,
            #state{channel = Channel} = State) ->
    [declare_exchange(Channel, Exchange) || Exchange <- Exchanges],
    {reply, ok, State};
handle_call({delete_exchanges, Exchanges}, _From,
            #state{channel = Channel} = State) ->
    [delete_exchange(Channel, Exchange) || Exchange <- Exchanges],
    {reply, ok, State}.

handle_cast({user_presence_changed, #{user_jid := UserJID,
                                      exchange := Exchange,
                                      status := Status}},
            #state{channel = Channel} = State) ->
    publish_status(Status, Channel, Exchange, UserJID),
    {noreply, State}.

handle_info({init, Opts}, State) ->
    {ok, Connection} = amqp_connection:start(Opts),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {noreply, State#state{connection = Connection, channel = Channel}}.

terminate(_Reason, #state{connection = Connection, channel = Channel}) ->
    close_rabbit_connection(Connection, Channel),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec declare_exchange(Channel :: pid(), Exchange :: binary()) -> term().
declare_exchange(Channel, Exchange) ->
    amqp_channel:call(Channel, #'exchange.declare'{exchange = Exchange,
                                                   type = <<"topic">>}).

-spec delete_exchange(Channel :: pid(), Exchange :: binary()) -> term().
delete_exchange(Channel, Exchange) ->
    amqp_channel:call(Channel, #'exchange.delete'{exchange = Exchange}).

-spec publish_status(Status :: atom(), Channel :: pid(), Exchange :: binary(),
                     JID :: binary()) -> term().
publish_status(Status, Channel, Exchange, JID) ->
    Message = presence_msg(JID, Status),
    publish(Channel, Exchange, JID, Message).

-spec publish(Channel :: pid(), Exchange :: binary(), RoutingKey :: binary(),
              Message :: binary()) -> term().
publish(Channel, Exchange, RoutingKey, Message) ->
    amqp_channel:call(Channel,
                      #'basic.publish'{
                         exchange = Exchange,
                         routing_key = RoutingKey},
                      #amqp_msg{payload = Message}).

-spec presence_msg(JID :: binary(), Status :: atom()) -> binary().
presence_msg(JID, Status) ->
    Msg = #{user_id => JID, present => is_user_online(Status)},
    jiffy:encode(Msg).

-spec is_user_online(online | offline) -> boolean().
is_user_online(online) -> true;
is_user_online(offline) -> false.

-spec close_rabbit_connection(Connection :: pid(), Channel :: pid()) ->
    ok | term().
close_rabbit_connection(Connection, Channel) ->
    try amqp_channel:close(Channel)
    catch
        _Error:_Reason -> already_closed
    end,
    amqp_connection:close(Connection).
