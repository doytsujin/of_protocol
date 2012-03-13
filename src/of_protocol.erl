%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Protocol library module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_protocol).

%% API
-export([encode/1, decode/1]).

-include("of_protocol.hrl").

-define(VERSION, << 1:1/integer, 3:7/integer >>).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Encode erlang representation to binary.
-spec encode(record()) -> binary() | {error, term()}.
encode(Record) ->
    try
        encode2(Record)
    catch
        _:Exception ->
            {error, Exception}
    end.

%% @doc Decode binary to erlang representation.
-spec decode(binary()) -> {record(), binary()} | {error, term()}.
decode(<< HeaderBin:8/binary, Rest/binary >>) ->
    try
        {Header, Type, Length} = decode_header(HeaderBin),
        decode(Type, Length, Header, Rest)
    catch
        _:Exception ->
            {error, Exception}
    end.

%%%-----------------------------------------------------------------------------
%%% Actual encode/decode functions
%%%-----------------------------------------------------------------------------

%% @doc Encode header
encode_header(#header{xid = Xid}, Type, Length) ->
    TypeInt = ofp_map:msg_type(Type),
    << ?VERSION/binary, TypeInt:8/integer, Length:16/integer, Xid:32/integer >>.

%% @doc Encode other structures
encode_struct(#port{port_no = PortNo, hw_addr = HWAddr, name = Name,
                    config = Config, state = State, curr = Curr,
                    advertised = Advertised, supported = Supported,
                    peer = Peer, curr_speed = CurrSpeed,
                    max_speed = MaxSpeed}) ->
    ConfigBin = flags_to_binary(port_config, Config, 4),
    StateBin = flags_to_binary(port_state, State, 4),
    CurrBin = flags_to_binary(port_feature, Curr, 4),
    AdvertisedBin = flags_to_binary(port_feature, Advertised, 4),
    SupportedBin = flags_to_binary(port_feature, Supported, 4),
    PeerBin = flags_to_binary(port_feature, Peer, 4),
    Padding = (16 - size(Name)) * 8,
    << PortNo:32/integer, 0:32/integer, HWAddr:6/binary, 0:16/integer,
       Name/binary, 0:Padding/integer, ConfigBin:4/binary, StateBin:4/binary,
       CurrBin:4/binary, AdvertisedBin:4/binary, SupportedBin:4/binary,
       PeerBin:4/binary, CurrSpeed:32/integer, MaxSpeed:32/integer >>;
encode_struct(#match{type = Type, oxm_fields = Fields}) ->
    TypeInt = ofp_map:match_type(Type),
    FieldsBin = encode_list(Fields),
    FieldsLength = size(FieldsBin),
    Length = FieldsLength + ?MATCH_SIZE - 4,
    Padding = ((4 + FieldsLength) rem 8) * 8,
    << TypeInt:16/integer, Length:16/integer, FieldsBin/binary,
       0:Padding/integer >>;
encode_struct(#oxm_field{class = Class, field = Field, has_mask = HasMask,
                         value = Value, mask = Mask}) ->
    ClassInt = ofp_map:oxm_class(Class),
    FieldInt = ofp_map:oxm_field(Class, Field),
    case Class of
        openflow_basic ->
            BitLength = ofp_map:tlv_length(Field),
            Length = (BitLength - 1) div 8 + 1;
        _ ->
            Length = size(Value),
            BitLength = Length * 8
    end,
    Value2 = cut(Value, BitLength),
    case HasMask of
        true ->
            HasMaskInt = 1,
            Mask2 = cut(Mask, BitLength),
            Rest = << Value2:Length/binary, Mask2:Length/binary >>,
            Len2 = Length * 2;
        false ->
            HasMaskInt = 0,
            Rest = << Value2:Length/binary >>,
            Len2 = Length
    end,
    << ClassInt:16/integer, FieldInt:7/integer, HasMaskInt:1/integer,
       Len2:8/integer, Rest/binary >>.

%% @doc Actual encoding of the messages
encode2(#hello{header = Header}) ->
    HeaderBin = encode_header(Header, hello, ?HEADER_SIZE),
    << HeaderBin/binary >>;
encode2(#error_msg{header = Header, type = Type, code = Code, data = Data}) ->
    Length = size(Data) + ?ERROR_MSG_SIZE,
    HeaderBin = encode_header(Header, error, Length),
    TypeInt = ofp_map:error_type(Type),
    CodeInt = ofp_map:Type(Code),
    << HeaderBin/binary, TypeInt:16/integer, CodeInt:16/integer, Data/binary >>;
encode2(#error_experimenter_msg{header = Header, exp_type = ExpTypeInt,
                                experimenter = Experimenter, data = Data}) ->
    Length = size(Data) + ?ERROR_EXPERIMENTER_MSG_SIZE,
    HeaderBin = encode_header(Header, error, Length),
    TypeInt = ofp_map:error_type(experimenter),
    << HeaderBin/binary, TypeInt:16/integer, ExpTypeInt:16/integer,
       Experimenter:32/integer, Data/binary >>;
encode2(#echo_request{header = Header, data = Data}) ->
    Length = size(Data) + ?ECHO_REQUEST_SIZE,
    HeaderBin = encode_header(Header, echo_request, Length),
    << HeaderBin/binary, Data/binary >>;
encode2(#echo_reply{header = Header, data = Data}) ->
    Length = size(Data) + ?ECHO_REPLY_SIZE,
    HeaderBin = encode_header(Header, echo_reply, Length),
    << HeaderBin/binary, Data/binary >>;
encode2(#features_request{header = Header}) ->
    HeaderBin = encode_header(Header, features_request, ?FEATURES_REQUEST_SIZE),
    << HeaderBin/binary >>;
encode2(#features_reply{header = Header, datapath_mac = DataPathMac,
                        datapath_id = DataPathID, n_buffers = NBuffers,
                        n_tables = NTables, capabilities = Capabilities,
                        ports = Ports}) ->
    PortsBin = encode_list(Ports),
    CapaBin = flags_to_binary(capability, Capabilities, 4),
    Length = size(PortsBin) + ?FEATURES_REPLY_SIZE,
    HeaderBin = encode_header(Header, features_reply, Length),
    << HeaderBin/binary, DataPathMac:6/binary, DataPathID:16/integer,
       NBuffers:32/integer, NTables:8/integer, 0:24/integer, CapaBin:4/binary,
       0:32/integer, PortsBin/binary >>;
encode2(#get_config_request{header = Header}) ->
    HeaderBin = encode_header(Header, get_config_request,
                              ?GET_CONFIG_REQUEST_SIZE),
    << HeaderBin/binary >>;
encode2(#get_config_reply{header = Header, flags = Flags,
                          miss_send_len = Miss}) ->
    FlagsBin = flags_to_binary(configuration, Flags, 2),
    HeaderBin = encode_header(Header, get_config_reply,
                              ?GET_CONFIG_REPLY_SIZE),
    << HeaderBin/binary, FlagsBin:2/binary, Miss:16/integer >>;
encode2(#set_config{header = Header, flags = Flags, miss_send_len = Miss}) ->
    FlagsBin = flags_to_binary(configuration, Flags, 2),
    HeaderBin = encode_header(Header, set_config, ?SET_CONFIG_SIZE),
    << HeaderBin/binary, FlagsBin:2/binary, Miss:16/integer >>;
encode2(#packet_in{header = Header, buffer_id = BufferId, reason = Reason,
                   table_id = TableId, match = Match, data = Data}) ->
    ReasonInt = ofp_map:reason(Reason),
    MatchBin = encode_struct(Match),
    TotalLen = byte_size(Data),
    Length = ?PACKET_IN_SIZE + size(MatchBin) - ?MATCH_SIZE,
    HeaderBin = encode_header(Header, packet_in, Length),
    << HeaderBin/binary, BufferId:32/integer, TotalLen:16/integer,
       ReasonInt:8/integer, TableId:8/integer, MatchBin/binary,
       0:16, Data/binary >>;
encode2(#flow_removed{header = Header, cookie = Cookie, priority = Priority,
                      reason = Reason, table_id = TableId, duration_sec = Sec,
                      duration_nsec = NSec, idle_timeout = Idle,
                      hard_timeout = Hard, packet_count = PCount,
                      byte_count = BCount, match = Match}) ->
    ReasonInt = ofp_map:removed_reason(Reason),
    MatchBin = encode_struct(Match),
    Length = ?FLOW_REMOVED_SIZE + size(MatchBin) - ?MATCH_SIZE,
    HeaderBin = encode_header(Header, flow_removed, Length),
    << HeaderBin/binary, Cookie:64/integer, Priority:16/integer,
       ReasonInt:8/integer, TableId:8/integer, Sec:32/integer, NSec:32/integer,
       Idle:16/integer, Hard:16/integer, PCount:64/integer, BCount:64/integer,
       MatchBin/binary >>;
encode2(#port_status{header = Header, reason = Reason, desc = Port}) ->
    ReasonInt = ofp_map:port_reason(Reason),
    PortBin = encode_struct(Port),
    HeaderBin = encode_header(Header, port_status, ?PORT_STATUS_SIZE),
    << HeaderBin/binary, ReasonInt:8/integer, 0:56/integer, PortBin/binary >>;
encode2(Other) ->
    throw({bad_message, Other}).

%% @doc Decode header structure
decode_header(Binary) ->
    << _:1/integer, Version:7/integer, TypeInt:8/integer,
       Length:16/integer, XID:32/integer >> = Binary,
    Type = ofp_map:msg_type(TypeInt),
    {#header{version = Version, xid = XID}, Type, Length}.

%% @doc Decode port structure
decode_port(Binary) ->
    << PortNo:32/integer, 0:32/integer, HWAddr:6/binary, 0:16/integer,
       Name:16/binary, ConfigBin:4/binary, StateBin:4/binary,
       CurrBin:4/binary, AdvertisedBin:4/binary, SupportedBin:4/binary,
       PeerBin:4/binary, CurrSpeed:32/integer,
       MaxSpeed:32/integer >> = Binary,
    Config = binary_to_flags(port_config, ConfigBin),
    State = binary_to_flags(port_state, StateBin),
    Curr = binary_to_flags(port_feature, CurrBin),
    Advertised = binary_to_flags(port_feature, AdvertisedBin),
    Supported = binary_to_flags(port_feature, SupportedBin),
    Peer = binary_to_flags(port_feature, PeerBin),
    Name2 = rstrip(Name),
    #port{port_no = PortNo, hw_addr = HWAddr, name = Name2, config = Config,
         state = State, curr = Curr, advertised = Advertised,
         supported = Supported, peer = Peer, curr_speed = CurrSpeed,
         max_speed = MaxSpeed}.

%% @doc Decode match structure
decode_match(Binary) ->
    PadFieldsLength = size(Binary) - ?MATCH_SIZE + 4,
    << TypeInt:16/integer, NoPadLength:16/integer,
       PadFieldsBin:PadFieldsLength/binary >> = Binary,
    FieldsBinLength = (NoPadLength - 4),
    Padding = (PadFieldsLength - FieldsBinLength) * 8,
    << FieldsBin:FieldsBinLength/binary, 0:Padding/integer >> = PadFieldsBin,
    Fields = decode_match_fields(FieldsBin),
    Type = ofp_map:match_type(TypeInt),
    #match{type = Type, oxm_fields = Fields}.

%% @doc Decode match fields
decode_match_fields(Binary) ->
    decode_match_fields(Binary, []).

%% @doc Decode match fields
decode_match_fields(<<>>, Fields) ->
    lists:reverse(Fields);
decode_match_fields(<< Header:4/binary, Binary/binary >>, Fields) ->
    << ClassInt:16/integer, FieldInt:7/integer, HasMaskInt:1/integer,
       Length:8/integer >> = Header,
    Class = ofp_map:oxm_class(ClassInt),
    Field = ofp_map:oxm_field(Class, FieldInt),
    HasMask = (HasMaskInt =:= 1),
    case Class of
        openflow_basic ->
            BitLength = ofp_map:tlv_length(Field);
        _ ->
            BitLength = Length * 4
    end,
    case HasMask of
        false ->
            << Value:Length/binary, Rest/binary >> = Binary,
            TLV = #oxm_field{value = cut(Value, BitLength)};
        true ->
            Length2 = (Length div 2),
            << Value:Length2/binary, Mask:Length2/binary,
               Rest/binary >> = Binary,
            TLV = #oxm_field{value = cut(Value, BitLength),
                             mask = cut(Mask, BitLength)}
    end,
    decode_match_fields(Rest, [TLV#oxm_field{class = Class,
                                             field = Field,
                                             has_mask = HasMask}
                               | Fields]).

%% @doc Actual decoding of the messages
decode(hello, _, Header, Rest) ->
    {#hello{header = Header}, Rest};
decode(error, Length, Header, Binary) ->
    << TypeInt:16/integer, More/binary >> = Binary,
    Type = ofp_map:error_type(TypeInt),
    case Type of
        experimenter ->
            DataLength = Length - ?ERROR_EXPERIMENTER_MSG_SIZE,
            << ExpTypeInt:16/integer, Experimenter:32/integer,
               Data:DataLength/binary, Rest/binary >> = More,
            {#error_experimenter_msg{header = Header, exp_type = ExpTypeInt,
                                     experimenter = Experimenter,
                                     data = Data}, Rest};
        _ ->
            DataLength = Length - ?ERROR_MSG_SIZE,
            << CodeInt:16/integer, Data:DataLength/binary, Rest/binary >> = More,
            Code = ofp_map:Type(CodeInt),
            {#error_msg{header = Header, type = Type,
                        code = Code, data = Data}, Rest}
    end;
decode(echo_request, Length, Header, Binary) ->
    DataLength = Length - ?ECHO_REQUEST_SIZE,
    << Data:DataLength/binary, Rest/binary >> = Binary,
    {#echo_request{header = Header, data = Data}, Rest};
decode(echo_reply, Length, Header, Binary) ->
    DataLength = Length - ?ECHO_REPLY_SIZE,
    << Data:DataLength/binary, Rest/binary >> = Binary,
    {#echo_reply{header = Header, data = Data}, Rest};
decode(features_request, _, Header, Rest) ->
    {#features_request{header = Header}, Rest};
decode(features_reply, Length, Header, Binary) ->
    PortsLength = Length - ?FEATURES_REPLY_SIZE,
    << DataPathMac:6/binary, DataPathID:16/integer, NBuffers:32/integer,
       NTables:8/integer, 0:24/integer, CapaBin:4/binary, 0:32/integer,
       PortsBin:PortsLength/binary, Rest/binary >> = Binary,
    Capabilities = binary_to_flags(capability, CapaBin),
    Ports = [decode_port(PortBin)
             || PortBin <- split_binaries(PortsBin, ?PORT_SIZE)],
    {#features_reply{header = Header, datapath_mac = DataPathMac,
                     datapath_id = DataPathID, n_buffers = NBuffers,
                     n_tables = NTables, capabilities = Capabilities,
                     ports = Ports}, Rest};
decode(get_config_request, _, Header, Rest) ->
    {#get_config_request{header = Header}, Rest};
decode(get_config_reply, _, Header, Binary) ->
    << FlagsBin:2/binary, Miss:16/integer, Rest/binary >> = Binary,
    Flags = binary_to_flags(configuration, FlagsBin),
    {#get_config_reply{header = Header, flags = Flags,
                       miss_send_len = Miss}, Rest};
decode(set_config, _, Header, Binary) ->
    << FlagsBin:2/binary, Miss:16/integer, Rest/binary >> = Binary,
    Flags = binary_to_flags(configuration, FlagsBin),
    {#set_config{header = Header, flags = Flags, miss_send_len = Miss}, Rest};
decode(packet_in, Length, Header, Binary) ->
    MatchLength = Length - ?PACKET_IN_SIZE + ?MATCH_SIZE,
    << BufferId:32/integer, TotalLen:16/integer, ReasonInt:8/integer,
       TableId:8/integer, MatchBin:MatchLength/binary, 0:16,
       Payload/binary >> = Binary,
    Reason = ofp_map:reason(ReasonInt),
    Match = decode_match(MatchBin),
    << Data:TotalLen/binary, Rest/binary >> = Payload,
    {#packet_in{header = Header, buffer_id = BufferId, reason = Reason,
                table_id = TableId, match = Match, data = Data}, Rest};
decode(flow_removed, Length, Header, Binary) ->
    MatchLength = Length - ?FLOW_REMOVED_SIZE + ?MATCH_SIZE,
    << Cookie:64/integer, Priority:16/integer, ReasonInt:8/integer,
       TableId:8/integer, Sec:32/integer, NSec:32/integer, Idle:16/integer,
       Hard:16/integer, PCount:64/integer, BCount:64/integer,
       MatchBin:MatchLength/binary, Rest/binary >> = Binary,
    Reason = ofp_map:removed_reason(ReasonInt),
    Match = decode_match(MatchBin),
    {#flow_removed{header = Header, cookie = Cookie, priority = Priority,
                   reason = Reason, table_id = TableId, duration_sec = Sec,
                   duration_nsec = NSec, idle_timeout = Idle,
                   hard_timeout = Hard, packet_count = PCount,
                   byte_count = BCount, match = Match}, Rest};
decode(port_status, _, Header, Binary) ->
    << ReasonInt:8/integer, 0:56/integer, PortBin:?PORT_SIZE/binary,
       Rest/binary >> = Binary,
    Reason = ofp_map:port_reason(ReasonInt),
    Port = decode_port(PortBin),
    {#port_status{header = Header, reason = Reason, desc = Port}, Rest}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

encode_list(List) ->
    encode_list(List, << >>).

encode_list([], Binaries) ->
    Binaries;
encode_list([Struct | Rest], Binaries) ->
    StructBin = encode_struct(Struct),
    encode_list(Rest, << Binaries/binary, StructBin/binary >>).

split_binaries(Binaries, Size) ->
    split_binaries(Binaries, [], Size).

split_binaries(<< >>, List, _) ->
    lists:reverse(List);
split_binaries(Binaries, List, Size) ->
    {Binary, Rest} = split_binary(Binaries, Size),
    split_binaries(Rest, [Binary | List], Size).

flags_to_binary(Type, Flags, Size) ->
    flags_to_binary(Type, Flags, << 0:(Size*8)/integer >>, Size).

flags_to_binary(_, [], Binary, _) ->
    Binary;
flags_to_binary(Type, [Flag | Rest], Binary, Size) ->
    BitSize = Size*8,
    << Binary2:BitSize/integer >> = Binary,
    Bit = ofp_map:Type(Flag),
    NewBinary = (Binary2 bor (1 bsl Bit)),
    flags_to_binary(Type, Rest, << NewBinary:BitSize/integer >>, Size).

binary_to_flags(Type, Binary) ->
    BitSize = size(Binary) * 8,
    << Integer:BitSize/integer >> = Binary,
    binary_to_flags(Type, Integer, BitSize-1, []).

binary_to_flags(Type, Integer, Bit, Flags) when Bit >= 0 ->
    case 0 /= (Integer band (1 bsl Bit)) of
        true ->
            binary_to_flags(Type, Integer, Bit - 1, [ofp_map:Type(Bit) | Flags]);
        false ->
            binary_to_flags(Type, Integer, Bit - 1, Flags)
    end;
binary_to_flags(_, _, _, Flags) ->
    lists:reverse(Flags).

rstrip(Binary) ->
    rstrip(Binary, size(Binary) - 1).

rstrip(Binary, Byte) when Byte >= 0 ->
    case binary:at(Binary, Byte) of
        0 ->
            rstrip(Binary, Byte - 1);
        _ ->
            binary:part(Binary, 0, Byte + 2)
    end;
rstrip(_, _) ->
    <<"\0">>.

cut(Binary, Bits) ->
    BitSize = size(Binary) * 8,
    case BitSize /= Bits of
        true ->
            << Int:BitSize/integer >> = Binary,
            NewInt = Int band round(math:pow(2,Bits) - 1),
            << NewInt:BitSize/integer >>;
        false ->
            Binary
    end.
