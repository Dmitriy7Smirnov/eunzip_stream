-define(chunk_size, 65000).
-define(eocd_search_limit, 5 * 1024 * 1024).
-define(eocd_header_size, 22).
-define(zip64_eocd_locator_size, 20).
-define(zip64_eocd_size, 56).
-define(zip64_extra_field_id, 16#0001).
-define(method_stored, 0).
-define(method_deflated, 8).

-record(unzip_state, {
    zip_handle :: file:fd(),
    central_dir :: maps:map(),
    file_size :: non_neg_integer()
}).

-record(unzip_cd_info, {
    total_entries :: non_neg_integer(),
    cd_size :: non_neg_integer(),
    cd_offset :: non_neg_integer()
}).

-record(unzip_cd_entry, {
    bit_flag :: non_neg_integer(),
    compression_method :: non_neg_integer(),
    last_modified_datetime :: calendar:datetime(),
    crc :: non_neg_integer(),
    compressed_size :: non_neg_integer(),
    uncompressed_size :: non_neg_integer(),
    local_header_offset :: non_neg_integer(),
    file_name :: file:filename_all()  % TODO: we should treat binary as "IBM Code Page 437" encoded string if GP flag 11 is not set
}).

-record(file_buffer, {
    file :: file:fd(),
    size :: non_neg_integer(),
    limit :: non_neg_integer(),
    buffer :: binary(),
    buffer_size :: non_neg_integer(),
    buffer_position :: non_neg_integer(),
    direction :: eunzip:direction()
}).