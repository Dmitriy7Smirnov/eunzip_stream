%% @author: Maxim Pushkar
%% @date: 06.04.2020

-module(eunzip).

%% Include files
-include_lib("stdlib/include/assert.hrl").
-include("eunzip.hrl").

%% API
-export([
    open/1,
    close/1,

    % Tests
    test1/0,
    test2/0,
    test3/0,
    test4/0,
    test5/0,
    test6/1,
    verify/1
]).

%% Types
-type unzip_state() :: #unzip_state{}.
-export_type([unzip_state/0]).

-type unzip_cd_info() :: #unzip_cd_info{}.
-export_type([unzip_cd_info/0]).

-type unzip_cd_entry() :: #unzip_cd_entry{}.
-export_type([unzip_cd_entry/0]).

-type file_buffer() :: #file_buffer{}.
-export_type([file_buffer/0]).

-type direction() :: 'backward' | 'forward'.
-export_type([direction/0]).

%% *****************************************************************************************************************************************
%% Zip implementation
%% *****************************************************************************************************************************************

%% Module to get files out of a zip. Works with local and remote files
%% ## Overview
%% Unzip tries to solve problem of accessing files from a zip which is not local (Aws S3, sftp etc). It does this by simply separating file system and zip implementation. Anything which implements `Unzip.FileAccess` can be used to get zip contents. Unzip relies on the ability to seek and read of the file, This is due to the nature of zip file.  Files from the zip are read on demand.
%% ## Usage
%% # Unzip.LocalFile implements Unzip.FileAccess
%% zip_file = Unzip.LocalFile.open("foo/bar.zip")
%% # `new` reads list of files by reading central directory found at the end of the zip
%% {:ok, unzip} = Unzip.new(zip_file)
%% # presents already read files metadata
%% file_entries = Unzip.list_entries(unzip)
%% # returns decompressed file stream
%% stream = Unzip.file_stream!(unzip, "baz.png")
%% Supports STORED and DEFLATE compression methods. Supports Zip64 specification

%% API

%% Open Zip file
-spec open(FileName :: file:filename_all()) ->
    {'ok', unzip_state()} | {'error', Reason :: atom()}.

test6(X) ->
    X * X.

open(FileName) ->
    FileSize = filelib:file_size(FileName),
    case file:open(FileName, [read, binary, raw]) of
        {ok, ZipHandle} ->
            case eunzip_central_dir:eocd(ZipHandle, FileSize) of
                {ok, Eocd} ->
                    case eunzip_central_dir:entries(ZipHandle, FileSize, Eocd) of
                        {ok, CentralDir} ->
                            {ok, #unzip_state{zip_handle = ZipHandle, central_dir = CentralDir, file_size = FileSize}};
                        {error, Reason} ->
                            file:close(ZipHandle),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    file:close(ZipHandle),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

% Close Zip file
-spec close(State :: unzip_state()) ->
    'ok' | {'error', Reason :: atom()}.

close(#unzip_state{zip_handle = ZipHandle}) ->
    file:close(ZipHandle).

decompress(#unzip_state{zip_handle = ZipHandle, central_dir = CentralDir} = State, FileName, TargetFileName) ->
    case maps:is_key(FileName, CentralDir) of
        true -> file_stream(State, FileName);
        false -> {error, file_not_found}
    end.


% Returns decompressed file entry from the zip as a stream. `file_name` *must* be complete file path. File is read in the chunks of 65k
file_stream(#unzip_state{zip_handle = ZipHandle, central_dir = CentralDir}, FileName) ->
    ?assert(maps:is_key(FileName, CentralDir), "File is not present in zip central directory"),
    #unzip_cd_entry{local_header_offset = LocalHeaderOffset, compressed_size = CompressedSize, crc = Crc} = maps:get(FileName, CentralDir),
    {ok, LocalHeader} = file:pread(ZipHandle, LocalHeaderOffset, 30),
    <<
        16#04034b50:32/little,
        _:32/little,
        CompressionMethod:16/little,
        _:128/little,
        FileNameLength:16/little,
        ExtraFieldLength:16/little
    >> = LocalHeader,
    Offset = LocalHeaderOffset + 30 + FileNameLength + ExtraFieldLength,
    CompressedData = stream(ZipHandle, Offset, CompressedSize),
    DecompressedData = case CompressionMethod of
        ?method_stored -> CompressedData;
        ?method_deflated ->
            Z =  zlib:open(),
            ok = zlib:inflateInit(Z, -15),
            D = zlib:inflate(Z, CompressedData),
            ok = zlib:inflateEnd(Z),
            zlib:close(Z),
            D
        % _ -> {error, invalid_compression_method}
    end.

stream(ZipHandle, Offset, Size) ->
    EndOffset = Offset + Size,
    stream_inner(ZipHandle, Offset, Size, EndOffset, <<>>).

stream_inner(_ZipHandle, Offset, _Size, EndOffset, Acc) when Offset >= EndOffset ->
    Acc;

stream_inner(ZipHandle, Offset, Size, EndOffset, Acc) ->
    NextOffset = min(Offset + ?chunk_size, EndOffset),
    {ok, Data} = file:pread(ZipHandle, Offset, NextOffset - Offset),
    stream_inner(ZipHandle, NextOffset, Size, EndOffset, <<Acc/binary, Data/binary>>).

stream_by_parts(ZipHandle, Offset, Size, CompressionMethod, Handler, TargetFileName) ->
    EndOffset = Offset + Size,
    Z =  zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    stream_inner_by_parts(ZipHandle, Offset, Size, EndOffset, CompressionMethod, Z, Handler, TargetFileName),
    ok = zlib:inflateEnd(Z),
    zlib:close(Z),
    ok.

stream_inner_by_parts(_ZipHandle, Offset, _Size, EndOffset, CompressionMethod, Z, Handler, TargetFileName) when Offset >= EndOffset ->
    case CompressionMethod of
        ?method_stored -> Handler(<<>>, TargetFileName, finished);
        ?method_deflated -> loop(Z, Handler, TargetFileName, zlib:safeInflate(Z, <<>>))
    end,
    ok;

stream_inner_by_parts(ZipHandle, Offset, Size, EndOffset, CompressionMethod, Z, Handler, TargetFileName) ->
    NextOffset = min(Offset + ?chunk_size, EndOffset),
    {ok, Data} = file:pread(ZipHandle, Offset, NextOffset - Offset),
    case CompressionMethod of
        ?method_stored -> Handler(Data, TargetFileName, continue);
        ?method_deflated -> loop(Z, Handler, TargetFileName, zlib:safeInflate(Z, Data))
    end,
    stream_inner_by_parts(ZipHandle, NextOffset, Size, EndOffset, CompressionMethod, Z, Handler, TargetFileName).

%% Internal functions
test1() ->
    {ok, State} = open(<<"Beta0.8.zip">>),
    #unzip_state{central_dir = CentralDir} = State,
    F = <<"Westmark Manor_Data/sharedassets99.assets.resS">>,
    #unzip_cd_entry{compressed_size = CS, uncompressed_size = UCS} = maps:get(F, CentralDir),
    DF = decompress(State, F, F),
    file:write_file(<<"test.bin">>, DF),
    io:format("File: ~s~nC.Size: ~B~nU.Size: ~B~nR.Size: ~B~n", [F, CS, UCS, byte_size(DF)]).

test2() ->
    open("D:\test1.zip").

test3() ->
    {ok, State} = open("elawesome.zip"),
    #unzip_state{central_dir = CentralDir} = State,
    F = <<"lib/elawesome_web/gettext.ex">>,
    #unzip_cd_entry{compressed_size = CS, uncompressed_size = UCS} = maps:get(F, CentralDir),
    DF = decompress(State, F, F),
    file:write_file(<<"test.bin">>, DF),
    io:format("File: ~s~nC.Size: ~B~nU.Size: ~B~nR.Size: ~B~n", [F, CS, UCS, iolist_size(DF)]).

test4() ->
    {ok, State} = open("D:\test1.zip"),
    #unzip_state{central_dir = CentralDir} = State,
    F = <<"test1.jpg">>,
    #unzip_cd_entry{compressed_size = CS, uncompressed_size = UCS, crc = CRC} =  maps:get(F, CentralDir),
    DF = decompress(State, F, F),
    file:write_file(<<"mytest.bin">>, DF),
    io:format("File: ~s~nC.Size: ~B~nU.Size: ~B~nR.Size: ~B~nCRC: ~B~n", [F, CS, UCS, iolist_size(DF), CRC]).

test5() ->
    {ok, State} = open("test.zip"),
    #unzip_state{central_dir = CentralDir} = State,
    FileName = <<"test.jpeg">>,
    #unzip_cd_entry{compressed_size = CS, uncompressed_size = UCS, crc = _CRC} = maps:get(FileName, CentralDir),
    DF = decompressByParts(State, FileName, FileName, fun stream_outer_writer/3),
    io:format("File: ~s~nC.Size: ~B~nU.Size: ~B~n", [FileName, CS, UCS]),
    DF.

verify(FileName) -> 
    {ok, FileHandle} = file:open(FileName, [read, binary, raw]),
    case verifyHelper(erlang:crc32(<<>>), FileHandle) of
        {ok, Crc} -> 
            file:close(FileHandle),
            Crc;
        {error, Reason} ->
            file:close(FileHandle),
            io:format("Error has occured, reason: ~p~n", [Reason])
    end.

verifyHelper(OldCrc, FileHandler) ->
    io:format("verify2 2~n"),
    case file:read(FileHandler, ?chunk_size) of
        {ok, Data} -> verifyHelper(erlang:crc32(OldCrc, Data), FileHandler);
        eof -> {ok, OldCrc};
        {error, Reason} -> {error, Reason}
    end.

decompressByParts(#unzip_state{zip_handle = ZipHandle, central_dir = CentralDir} = State, FileName, TargetFileName, Handler) ->
    case maps:is_key(FileName, CentralDir) of
        true -> new_file_stream(State, FileName, TargetFileName, Handler);
        false -> {error, file_not_found} 
    end.

% Returns decompressed file entry from the zip as a stream. `file_name` *must* be complete file path. File is read in the chunks of 65k
new_file_stream(#unzip_state{zip_handle = ZipHandle, central_dir = CentralDir}, FileName, TargetFileName, Handler) ->
    ?assert(maps:is_key(FileName, CentralDir), "File is not present in zip central directory"),
    #unzip_cd_entry{local_header_offset = LocalHeaderOffset, compressed_size = CompressedSize, crc = Crc} = maps:get(FileName, CentralDir),
    {ok, LocalHeader} = file:pread(ZipHandle, LocalHeaderOffset, 30),
    <<
        16#04034b50:32/little,
        _:32/little,
        CompressionMethod:16/little,
        _:128/little,
        FileNameLength:16/little,
        ExtraFieldLength:16/little
    >> = LocalHeader,
    Offset = LocalHeaderOffset + 30 + FileNameLength + ExtraFieldLength,
    stream_by_parts(ZipHandle, Offset, CompressedSize, CompressionMethod, Handler, TargetFileName).

loop(Z, Handler, PathToFile, {continue, Output}) ->
    Handler(Output, PathToFile, continue),
    loop(Z, Handler, PathToFile, zlib:safeInflate(Z, []));
loop(Z, Handler, PathToFile, {finished, Output}) ->
    Handler(Output, PathToFile, finished).

stream_outer_writer(Data, PathToFile, Status) ->
    case Status of
        continue ->
            file:write_file(PathToFile, Data, [append, binary, raw]);
        finished -> 
            file:write_file(PathToFile, Data, [append, binary, raw]),
            ok
    end.
