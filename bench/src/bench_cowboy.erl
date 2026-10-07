-module(bench_cowboy).
-behaviour(cowboy_handler).
-export([start/1, init/2]).

-define(FILLER, [<<"accounts">>, <<"billing">>, <<"comments">>, <<"drafts">>,
                 <<"events">>, <<"files">>, <<"groups">>, <<"invites">>,
                 <<"jobs">>, <<"keys">>, <<"labels">>, <<"messages">>,
                 <<"notes">>, <<"orders">>, <<"pages">>, <<"queues">>,
                 <<"reports">>, <<"settings">>, <<"tags">>, <<"teams">>]).

start(Port) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Filler = lists:flatmap(fun(Name) ->
        [{<<"/", Name/binary>>, ?MODULE, {name, Name}},
         {<<"/", Name/binary, "/:id">>, ?MODULE, {name, Name}}]
    end, ?FILLER),
    Routes = [{<<"/">>, ?MODULE, hello},
              {<<"/json">>, ?MODULE, json},
              {<<"/users/:id/posts/:post">>, ?MODULE, post}
              | Filler],
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    {ok, _} = cowboy:start_clear(bench_http,
        #{socket_opts => [{ip, {127, 0, 0, 1}}, {port, Port}],
          max_connections => 10000},
        #{env => #{dispatch => Dispatch}}),
    nil.

init(Req, hello = State) ->
    {ok, text(<<"Hello, world!">>, Req), State};
init(Req, json = State) ->
    Body = json:encode(#{<<"id">> => 42, <<"name">> => <<"gloss">>,
                         <<"tags">> => [<<"fast">>, <<"small">>]}),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>},
                          Body, Req), State};
init(Req, post = State) ->
    Id = cowboy_req:binding(id, Req),
    Post = cowboy_req:binding(post, Req),
    {ok, text(<<Id/binary, "/", Post/binary>>, Req), State};
init(Req, {name, Name} = State) ->
    {ok, text(Name, Req), State}.

text(Body, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                     Body, Req).
