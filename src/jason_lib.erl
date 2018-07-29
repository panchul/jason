%%%-----------------------------------------------------------------------------
%%% File:      jason_lib.erl
%%% @author    Eric Pailleau <jason@crownedgrouse.com>
%%% @copyright 2017 crownedgrouse.com
%%% @doc
%%% Library for Jason
%%% @end
%%%
%%% Permission to use, copy, modify, and/or distribute this software
%%% for any purpose with or without fee is hereby granted, provided
%%% that the above copyright notice and this permission notice appear
%%% in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
%%% WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
%%% WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
%%% AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
%%% CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
%%% LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
%%% NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
%%% CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% Created : 2017-02-13
%%%-----------------------------------------------------------------------------
-module(jason_lib).

-export([mapify/1, recordify/1, proplistify/1]).

%% MAPS %%
%%==============================================================================
%% @doc Translate to map
%% @end
-spec mapify(any()) -> any().

mapify([{_,_}|_T] = Obj) when is_list(Obj)  ->
          {_, M} = lists:mapfoldl(fun({K, V}, Acc) -> {{K, V}, Acc#{safe_list_to_atom(binary_to_list(K)) => mapify(V)}} end , #{}, Obj),
          M;
mapify([_H|_T] = Obj) when is_list(Obj) ->
          {_, M} = lists:mapfoldl(fun(Z, Acc) -> {Z, Acc ++ [mapify(Z)]} end , [], Obj),
          M;
mapify({K,V}) when is_tuple(K), is_tuple(V) % Date
          -> {K, V} ;
mapify({K, V}) when is_list(V) -> #{safe_list_to_atom(binary_to_list(K)) => mapify(V)};
mapify({K, V}) -> #{safe_list_to_atom(binary_to_list(K)) => cast(V)};
mapify(X) -> cast(X).

%% RECORDS %%
%%==============================================================================
%% @doc Translate to record
%% @end
-spec recordify(list()) -> tuple().

recordify(Obj)
   when is_list(Obj)
   -> % Replace binary keys by atom key, and detect values types
      R = lists:flatmap(fun({K, V}) -> [{erlang:binary_to_atom(K, utf8), cast(V)}] end, Obj),
      T = lists:flatmap(fun({K, V}) -> [{K, detect_type(V)}] end, R),
      CR = case get(jason_records) of
               [] -> '' ;
               undefined -> '' ;
               X  -> % Some records announced, check if we find it
                     Keys = lists:flatmap(fun({K, _}) -> [K] end, R),
                     case lists:keyfind(Keys, 2, X) of
                           false -> '' ;
                           {F, _}     -> F
                     end
           end,

      % Hash Erlang term for ad hoc record name if necessary otherwise use record name detected
      H = case CR of
               '' -> HH = list_to_atom(integer_to_list(erlang:phash2(T))),
                     % Create module for this record handling if not existing
                     case get(jason_adhoc) of
                           undefined -> put(jason_adhoc, []);
                           _         -> ok
                     end,
                     case lists:any(fun(X) -> case X of HH -> true; _ -> false end end, get(jason_adhoc)) of
                           true  -> ok ;
                           false -> create_module(HH, T)
                     end,
                     HH;
               RN -> RN
          end,
      % Create record
      V = lists:flatmap(fun({_, Z}) -> [Z] end, R),
      erlang:list_to_tuple([H] ++ V).

%%==============================================================================
%% @doc Detect type of data
%% @end
-spec detect_type(any()) -> atom() | tuple().

detect_type(V) when is_atom(V)    -> literal ;
detect_type(V) when is_float(V)   -> float ;
detect_type(V) when is_integer(V) -> integer ;
detect_type(V) when is_list(V)    -> list;
detect_type(V) when is_binary(V)  -> binary;
detect_type({K,V}) when is_tuple(K),is_tuple(V)
                                  -> datetime;
detect_type(V) when is_tuple(V)   -> {record, element(1, V)}.

%%==============================================================================
%% @doc Create argonaut module for record handling
%% @end
-spec create_module(atom(), list()) -> atom().

create_module(H, T) ->
      % Module declaration
      M1 = parse_forms(io_lib:format("-module(~p).~n", [H])),
      {Ks, _Ts} = lists:unzip(T),
      M10 = parse_forms(io_lib:format("-jason(argonaut).~n", [])),

      % Functions export
      M2 = parse_forms(io_lib:format("-export([new/0, fields/0, size/0, def/0, ~ts]).~n",
                        [string:join(lists:flatmap(fun(K) -> [io_lib:format("~p/1,~p/2", [K,K])] end, Ks), ", ")])),

      % Json types definition
      M3  = parse_forms(io_lib:format("-type literal() :: null | true | false .~n",[])),
      M31 = parse_forms(io_lib:format("-type datetime() :: calendar:datetime() .~n",[])),

      % Record definition
      DefT = string:join(lists:flatmap(fun({K, V}) ->
                           Def1  =    case V of
                                          {record, R} -> io_lib:format(" = ~p:new() ", [R]) ;
                                          integer -> " = 0 " ;
                                          float   -> " = 0.0 " ;
                                          list    -> " = [] " ;
                                          literal -> " = null ";
                                          binary  -> " = <<"">>";
                                          datetime-> " = {{1970,1,1},{0,0,0}}"
                                     end,
                           Type1 =    case V of
                                          {record, A} -> "'" ++  atom_to_list(A) ++ "':'" ++ atom_to_list(A) ++ "'" ;
                                          V when is_atom(V) -> atom_to_list(V)
                                     end,
                           [io_lib:format("~p ~s :: ~s()", [K, Def1, Type1])]
                                                   end, T), ", "),
      M40 = parse_forms(io_lib:format("-record(~p, {~ts}).~n", [H, DefT])),

      M41 = parse_forms(io_lib:format("-opaque ~p() :: #~p{}.~n", [H, H])),
      M42 = parse_forms(io_lib:format("-export_type([~p/0]).~n", [H])),

      % Function definitions
      M50 = parse_forms(io_lib:format("new() -> #~p{}.~n", [H])),
      M51 = parse_forms(io_lib:format("fields() -> record_info(fields, ~p).~n", [H])),
      M52 = parse_forms(io_lib:format("size()   -> record_info(size, ~p).~n", [H])),

      RecDef = io_lib:format("-record(~p, {~ts}).~n", [H, DefT]),
      M53 = parse_forms(io_lib:format("def() -> \"-record(~p, {~ts}).\".~n", [H, DefT])),

      M54 = lists:flatmap(fun({K, Type}) ->
                           G = case Type of
                                          {record, R} -> io_lib:format(",is_tuple(V),(~p == element(1, V)) ", [R]) ;
                                          integer -> ",is_integer(V) " ;
                                          float   -> ",is_float(V) " ;
                                          list    -> ",is_list(V) " ;
                                          binary  -> ",is_binary(V) " ;
                                          literal -> ",is_atom(V),((V == 'true') or (V == 'false') or (V == 'null')) ";
                                          datetime-> ",is_tuple(V) "
                               end,
                           [parse_forms(io_lib:format("~p(#~p{~p = X}) -> X.~n", [K, H, K])),
                            parse_forms(io_lib:format("~p(R, V) when is_record(R, ~p)~s -> R#~p{~p = V}.~n",
                                                      [K, H, G, H, K]))] end, T),
      % Compile forms
      Binary = case compile:forms(lists:flatten([M1,M10,M2,M3,M31,M40,M41,M42,M50,M51,M52,M53,M54])) of
                  {ok, _, B} -> B ;
                  {ok, _, B, Warnings} -> io:format("Warning : ~p~n", [Warnings]), B ;
                  error -> io:format("Error while compiling : ~p~n", [H]),
                           <<"">>;
                  {error,Errors,Warnings} -> io:format("Error   : ~p~n", [Errors]),
                                             io:format("Warning : ~p~n", [Warnings]),
                                             <<"">>
               end,

      % Dump record def if requested
      _ = case get(jason_to) of
              undefined -> ok ;
              File when is_list(File)     -> append_file(File, RecDef);
              _ -> ok
          end,

      % Load module
      case code:load_binary(H, atom_to_list(H), Binary) of
         {module, _}    -> put(jason_adhoc, lists:flatten(get(jason_adhoc) ++ [H])) ;
         {error, _What} -> ok
      end.

%%==============================================================================
%% @doc Parse forms
%% @end
-spec parse_forms(list()) -> atom() | list().

parse_forms(C) ->
         Code = lists:flatten(C),
         case erl_scan:string(Code) of
              {ok, S, _} ->  case erl_parse:parse_form(S) of
                                 {ok, PF}    -> PF ;
                                 {error, Ei} -> erlang:display({parse_error, Ei, io_lib:format("~ts",[Code])}), false
                             end;
              {error, EI, EL} -> erlang:display({scan_error, EI, EL, io_lib:format("~ts",[Code])}), false
         end.

%% PROPLIST %%
%%==============================================================================
%% @doc Translate to proplist
%% @end
-spec proplistify(any()) -> any().

proplistify([{K,V}])
      when is_binary(K)      -> [{safe_list_to_atom(binary_to_list(K)), proplistify(V)}];
proplistify([{K,V}])         -> [{proplistify(K), proplistify(V)}];
proplistify([{_,_}|_T] = R)  when is_list(R)
                             -> lists:flatmap(fun(Z) -> case Z of
                                    {K, V} when is_binary(K) -> [{safe_list_to_atom(binary_to_list(K)), proplistify(V)}];
                                    {K, V} -> [{proplistify(K), proplistify(V)}];
                                    O      -> [cast(O)]
                                 end end, R);
proplistify([_H|_T] = R) when is_list(R)
                             -> case io_lib:printable_unicode_list(R) of
                                     false -> lists:flatmap(fun(Z) -> [proplistify(Z)] end, R);
                                     true  -> cast(R)
                                end;
proplistify({K,V}) when is_tuple(K),is_tuple(V) % Date
                             -> {K,V} ;
proplistify({K,V})           -> {safe_list_to_atom(binary_to_list(K)), proplistify(V)};
proplistify(R)               -> cast(R).

%% General %%
%%==============================================================================
%% @doc Cast data (list if printable, otherwise binary)
%% @end
-spec cast(any()) -> any().

cast(V) ->
   case get(jason_binary) of
      v  -> cast(V, binary);
      kv -> cast(V, binary);
      _  -> cast(V, undefined)
   end.

cast(V, binary) when is_binary(V) -> V ;

cast(V, binary) when is_list(V) -> erlang:list_to_binary(V);

cast(V, _) when is_binary(V) ->
   X = erlang:binary_to_list(V),
   case io_lib:printable_unicode_list(X) of
      true  -> X;
      false -> V
   end;
cast(V, _) when is_list(V)   ->
   case io_lib:printable_unicode_list(V) of
      false -> lists:flatmap(fun(Z) -> [cast(Z)] end, V);
      true  -> V
   end;
cast(V, _)                   -> V .

%%==============================================================================
%% @doc Append data to file
%% @end
-spec append_file(list(), any()) -> atom().

append_file(Filename, Bytes)
    when is_list(Filename) ->
    case file:open(Filename, [append]) of
        {ok, IoDevice} ->
            ok = file:write(IoDevice, Bytes),
            file:close(IoDevice);
        {error, Reason} ->
            io:format("~s open error  reason:~s~n", [Filename, Reason])
    end.

%%==============================================================================
%% @doc Safe list to atom (check > 255 of UTF8)
%% @end
-spec safe_list_to_atom(list()) -> atom() | binary().

safe_list_to_atom(L) ->
   R = case get(jason_binary) of
            k  -> list_to_binary(L);
            kv -> list_to_binary(L);
            _  ->  case catch list_to_atom(L) of
                        {'EXIT', _} -> list_to_binary(L);
                        X -> X
                     end
         end,
   R.

%%==============================================================================
%% doc Detect encoding
%%      TODO
%% end
%% 3.  Encoding
%%
%%   JSON text SHALL be encoded in Unicode.  The default encoding is
%%   UTF-8.
%%   Since the first two characters of a JSON text will always be ASCII
%%   characters [RFC0020], it is possible to determine whether an octet
%%   stream is UTF-8, UTF-16 (BE or LE), or UTF-32 (BE or LE) by looking
%%   at the pattern of nulls in the first four octets.
%%           00 00 00 xx  UTF-32BE
%%           00 xx 00 xx  UTF-16BE
%%           xx 00 00 00  UTF-32LE
%%           xx 00 xx 00  UTF-16LE
%%           xx xx xx xx  UTF-8
%detect_encoding() -> {utf32, big} ;
%detect_encoding() -> {utf16, big} ;
%detect_encoding() -> {utf32, little} ;
%detect_encoding() -> {utf16, little} ;
%detect_encoding(_) -> utf8 .

