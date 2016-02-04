%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% 1. Permission is defined as a pair {object, operation}
%% 2. Objects are organized in the tree structure with common root []
%% 3. One vertex of this tree can be parametrized: {bucket, bucket_name},
%%    wildcard all can be used in place of bucket_name
%% 4. Permission pattern is a pair {Object pattern, Allowed operations}
%% 5. Allowed operations can be list of operations, all or none
%% 6. Object pattern is a list of vertices that define a certain subtree of the objects tree
%% 7. Object pattern vertex {bucket, bucket_name} always matches object vertex {bucket, any},
%%    object pattern vertex {bucket, any} matches {bucket, bucket_name} with any bucket_name
%%    otherwise vertices match if they are equal
%% 8. Object matches the object pattern if all the vertices of object pattern match
%%    corresponding vertices of the object.
%% 9. Each role is defined as a list of permission patterns.
%% 10.To find which operations are allowed for certain object in certain role we look for the
%%    first permission pattern with matching object pattern in the permission pattern list of
%%    the role.
%% 11.The permission is allowed by the role if its operation is among the allowed operations
%%    for its object.
%% 12.Each user can have multiple roles assigned
%% 13.Certain permission is allowed to the user if it is allowed at least by one of the roles
%%    assigned to user.

%% @doc roles and permissions implementation

-module(menelaus_roles).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([get_definitions/0,
         get_definitions/1,
         preconfigured_roles/0,
         is_allowed/2,
         get_compiled_roles/1,
         get_all_assignable_roles/1,
         get_users/0,
         get_users/1,
         store_user/3,
         delete_user/1,
         upgrade_users/1]).

preconfigured_roles() ->
    [{admin, [],
      [{name, <<"Admin">>},
       {desc, <<"Can manage ALL cluster features including security.">>}],
      [{[], all}]},
     {ro_admin, [],
      [{name, <<"Read Only Admin">>},
       {desc, <<"Can view ALL cluster features.">>}],
      [{[{bucket, any}, password], none},
       {[{bucket, any}, data], none},
       {[admin, security], [read]},
       {[admin], none},
       {[], [read]}]},
     {cluster_admin, [],
      [{name, <<"Cluster Admin">>},
       {desc, <<"Can manage all cluster features EXCEPT security.">>}],
      [{[admin], none},
       {[], all}]},
     {bucket_admin, [bucket_name],
      [{name, <<"Bucket Admin">>},
       {desc, <<"Can manage ALL bucket features for specified buckets (incl. start/stop XDCR)">>}],
      [{[{bucket, bucket_name}, xdcr], [read, execute]},
       {[{bucket, bucket_name}], all},
       {[{bucket, any}, data], none},
       {[{bucket, any}, settings], [read]},
       {[admin], none},
       {[], [read]}]},
     {bucket_sasl, [bucket_name],
      [],
      [{[{bucket, bucket_name}, data], all},
       {[{bucket, bucket_name}], [read]},
       {[pools], [read]}]},
     {views_admin, [bucket_name],
      [{name, <<"Views Admin">>},
       {desc, <<"Can manage views for specified buckets">>}],
      [{[{bucket, bucket_name}, views], all},
       {[{bucket, bucket_name}, data], [read]},
       {[{bucket, any}, settings], [read]},
       {[{bucket, any}], none},
       {[xdcr], none},
       {[admin], none},
       {[], [read]}]},
     {replication_admin, [],
      [{name, <<"Replication Admin">>},
       {desc, <<"Can manage ONLY XDCR features (cluster AND bucket level)">>}],
      [{[{bucket, any}, xdcr], all},
       {[xdcr], all},
       {[admin], none},
       {[], [read]}]}].

get_definitions() ->
    case cluster_compat_mode:is_cluster_watson() of
        true ->
            get_definitions(ns_config:latest());
        false ->
            preconfigured_roles()
    end.

get_definitions(Config) ->
    {value, RolesDefinitions} = ns_config:search(Config, roles_definitions),
    RolesDefinitions.

object_match(_, []) ->
    true;
object_match([], [_|_]) ->
    false;
object_match([{_Same, _} | RestOfObject], [{_Same, any} | RestOfObjectPattern]) ->
    object_match(RestOfObject, RestOfObjectPattern);
object_match([{_Same, any} | RestOfObject], [{_Same, _} | RestOfObjectPattern]) ->
    object_match(RestOfObject, RestOfObjectPattern);
object_match([_Same | RestOfObject], [_Same | RestOfObjectPattern]) ->
    object_match(RestOfObject, RestOfObjectPattern);
object_match(_, _) ->
    false.

get_allowed_operations(_Object, []) ->
    none;
get_allowed_operations(Object, [{ObjectPattern, AllowedOperations} | Rest]) ->
    case object_match(Object, ObjectPattern) of
        true ->
            AllowedOperations;
        false ->
            get_allowed_operations(Object, Rest)
    end.

operation_allowed(_, all) ->
    true;
operation_allowed(_, none) ->
    false;
operation_allowed(Operation, AllowedOperations) ->
    lists:member(Operation, AllowedOperations).

is_allowed(Permission, {_, _} = Identity) ->
    Roles = get_compiled_roles(Identity),
    is_allowed(Permission, Roles);
is_allowed({Object, Operation}, Roles) ->
    lists:any(fun (Role) ->
                      Operations = get_allowed_operations(Object, Role),
                      operation_allowed(Operation, Operations)
              end, Roles);
is_allowed(Permissions, Roles) when is_list(Permissions) ->
    lists:any(fun (Permission) ->
                      is_allowed(Permission, Roles)
              end, Permissions).

substitute_params(Params, ParamDefinitions, Permissions) ->
    ParamPairs = lists:zip(ParamDefinitions, Params),
    lists:map(fun ({ObjectPattern, AllowedOperations}) ->
                      {lists:map(fun ({Name, any}) ->
                                         {Name, any};
                                     ({Name, Param}) ->
                                         {Param, Subst} = lists:keyfind(Param, 1, ParamPairs),
                                         {Name, Subst};
                                     (Vertex) ->
                                         Vertex
                                 end, ObjectPattern), AllowedOperations}
              end, Permissions).

compile_roles(Roles, Definitions) ->
    lists:map(fun (Name) when is_atom(Name) ->
                      {Name, [], _Props, Permissions} = lists:keyfind(Name, 1, Definitions),
                      Permissions;
                  ({Name, Params}) ->
                      {Name, ParamDefinitions, _Props, Permissions} =
                          lists:keyfind(Name, 1, Definitions),
                      substitute_params(Params, ParamDefinitions, Permissions)
              end, Roles).

get_user_roles({User, saslauthd} = Identity) ->
    case cluster_compat_mode:is_cluster_watson() of
        true ->
            Props = ns_config:search_prop(ns_config:latest(), user_roles, Identity, []),
            proplists:get_value(roles, Props, []);
        false ->
            case saslauthd_auth:get_role_pre_watson(User) of
                admin ->
                    [admin];
                ro_admin ->
                    [ro_admin];
                false ->
                    []
            end
    end.

get_roles({"", wrong_token}) ->
    case ns_config_auth:is_system_provisioned() of
        false ->
            [admin];
        true ->
            []
    end;
get_roles({"", anonymous}) ->
    case ns_config_auth:is_system_provisioned() of
        false ->
            [admin];
        true ->
            [{bucket_sasl, [BucketName]} || BucketName <- ns_config_auth:get_no_auth_buckets()]
    end;
get_roles({_, admin}) ->
    [admin];
get_roles({_, ro_admin}) ->
    [ro_admin];
get_roles({BucketName, bucket}) ->
    [{bucket_sasl, [BucketName]}];
get_roles({_, saslauthd} = Identity) ->
    get_user_roles(Identity).

get_compiled_roles(Identity) ->
    Definitions = get_definitions(),
    Roles = get_roles(Identity),
    compile_roles(Roles, Definitions).

get_possible_param_values(Config, bucket_name) ->
    [all | [Name || {Name, _} <- ns_bucket:get_buckets(Config)]].

get_all_assignable_roles(Config) ->
    BucketNames = get_possible_param_values(Config, bucket_name),

    lists:foldr(
      fun ({bucket_sasl, _, _, _}, Acc) ->
              Acc;
          ({Role, [], Props, _}, Acc) ->
              [{Role, Props} | Acc];
          ({Role, [bucket_name], Props, _}, Acc) ->
              lists:foldr(
                fun (BucketName, Acc1) ->
                        [{{Role, [BucketName]}, Props} | Acc1]
                end, Acc, BucketNames)
      end, [], get_definitions(Config)).

get_users() ->
    get_users(ns_config:latest()).

get_users(Config) ->
    ns_config:search(Config, user_roles, []).

delete_user(Identity) ->
    ns_config:run_txn(
      fun (Config, SetFn) ->
              case ns_config:search(Config, user_roles) of
                  false ->
                      {abort, {error, not_found}};
                  {value, Users} ->
                      case lists:keytake(Identity, 1, Users) of
                          false ->
                              {abort, {error, not_found}};
                          {value, _, NewUsers} ->
                              {commit, SetFn(user_roles, NewUsers, Config)}
                      end
              end
      end).

validate_role(Role, Definitions, _BucketNames) when is_atom(Role) ->
    lists:keymember(Role, 1, Definitions);
validate_role({Role, [BucketName]}, Definitions, BucketNames) ->
    lists:keymember(Role, 1, Definitions) andalso
        lists:member(BucketName, BucketNames).

store_user(Identity, Name, Roles) ->
    Props = case Name of
                undefined ->
                    [];
                _ ->
                    [{name, Name}]
            end,
    ns_config:run_txn(
      fun (Config, SetFn) ->
              {value, Definitions} = ns_config:search(roles_definitions),
              BucketNames = get_possible_param_values(Config, bucket_name),

              UnknownRoles = [Role || Role <- Roles,
                                      not validate_role(Role, Definitions, BucketNames)],
              case UnknownRoles of
                  [] ->
                      Users = ns_config:search(Config, user_roles, []),
                      NewUsers = lists:keystore(Identity, 1, Users,
                                                {Identity, [{roles, Roles} | Props]}),
                      {commit, SetFn(user_roles, NewUsers, Config)};
                  _ ->
                      {abort, {error, roles_validation, UnknownRoles}}
              end
      end).

collect_users(asterisk, _Role, Dict) ->
    Dict;
collect_users([], _Role, Dict) ->
    Dict;
collect_users([User | Rest], Role, Dict) ->
    NewDict = dict:update(User, fun (Roles) ->
                                        ordsets:add_element(Role, Roles)
                                end, ordsets:from_list([Role]), Dict),
    collect_users(Rest, Role, NewDict).

upgrade_users(Config) ->
    case ns_config:search(Config, saslauthd_auth_settings) of
        false ->
            [];
        {value, Props} ->
            case proplists:get_value(enabled, Props, false) of
                false ->
                    [];
                true ->
                    Dict = dict:new(),
                    Dict1 = collect_users(proplists:get_value(admins, Props, []), admin, Dict),
                    Dict2 = collect_users(proplists:get_value(roAdmins, Props, []), ro_admin, Dict1),
                    [{set, user_roles,
                      lists:map(fun ({User, Roles}) ->
                                        {{binary_to_list(User), saslauthd},
                                         [{roles, ordsets:to_list(Roles)}]}
                                end, dict:to_list(Dict2))}]
            end
    end.

upgrade_users_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins,[<<"user1">>, <<"user2">>, <<"user1">>, <<"user3">>]},
                 {roAdmins,[<<"user4">>, <<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [admin, ro_admin]}]},
                 {{"user2", saslauthd}, [{roles, [admin]}]},
                 {{"user3", saslauthd}, [{roles, [admin]}]},
                 {{"user4", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_users(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).

upgrade_users_asterisk_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins, asterisk},
                 {roAdmins,[<<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_users(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).

%% assertEqual is used instead of assert and assertNot to avoid
%% dialyzer warnings
object_match_test() ->
    ?assertEqual(true, object_match([o1, o2], [o1, o2])),
    ?assertEqual(false, object_match([o1], [o1, o2])),
    ?assertEqual(true, object_match([o1, o2], [o1])),
    ?assertEqual(true, object_match([{b, "a"}], [{b, "a"}])),
    ?assertEqual(false, object_match([{b, "a"}], [{b, "b"}])),
    ?assertEqual(true, object_match([{b, any}], [{b, "b"}])),
    ?assertEqual(false, object_match([{b, all}], [{b, "b"}])),
    ?assertEqual(true, object_match([{b, all}], [{b, any}])),
    ?assertEqual(true, object_match([{b, "a"}], [{b, any}])),
    ?assertEqual(true, object_match([{b, any}], [{b, any}])).

admin_test() ->
    Roles = compile_roles([admin], preconfigured_roles()),
    ?assertEqual(true, menelaus_roles:is_allowed({[{bucket, all}], create}, Roles)).

bucket_admin_test() ->
    Roles = compile_roles([{bucket_admin, ["default"]}], preconfigured_roles()),
    ?assertEqual(false, menelaus_roles:is_allowed({[{bucket,"test"}, data], read}, Roles)),
    ?assertEqual(false, menelaus_roles:is_allowed({[{bucket, all}], create}, Roles)).