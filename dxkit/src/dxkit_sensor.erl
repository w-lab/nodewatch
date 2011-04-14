%% ------------------------------------------------------------------------------
%%
%% Erlang System Monitoring: Sensor.
%%
%% Copyright (c) 2008-2010 Tim Watson (watson.timothy@gmail.com)
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
%% ------------------------------------------------------------------------------
%%
%% @doc When used in conjunction with eper, this module handles monitoring events.
%% One module is created per active subscriber, with the subscriber's client key 
%% providing a reply-to mechanism outside this application.
%%
%% This process runs on the `nodewatch' host, not the node(s) being monitored.
%%
%% ------------------------------------------------------------------------------

-module(dxkit_sensor).
-author('Tim Watson <watson.timothy@gmail.com>').

-export([start/1, stop/1]).

start(Consumer) ->
    Pid = prfHost:start(Consumer:name(), Consumer:target(), Consumer),
    {ok, Pid}.

stop(Name) ->
    prfHost:stop(Name).