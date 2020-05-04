{application, eunzip, [
    {description, "Erlang unzip module"},
    {vsn, "1.0"},
    {modules,[eunzip_range,eunzip_central_dir,eunzip_buffer,eunzip]},
    {registered, []},
    {applications, [kernel, stdlib]},
    {mod, {eunzip_app, []}}
]}.
