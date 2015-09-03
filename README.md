HTTPClient.jl
=============

[![Build Status](https://travis-ci.org/JuliaWeb/HTTPClient.jl.svg?branch=master)](https://travis-ci.org/JuliaWeb/HTTPClient.jl)
[![Coverage Status](https://coveralls.io/repos/JuliaWeb/HTTPClient.jl/badge.svg)](https://coveralls.io/r/JuliaWeb/HTTPClient.jl)

[![HTTPClient](http://pkg.julialang.org/badges/HTTPClient_0.3.svg)](http://pkg.julialang.org/?pkg=HTTPClient&ver=0.3)
[![HTTPClient](http://pkg.julialang.org/badges/HTTPClient_0.4.svg)](http://pkg.julialang.org/?pkg=HTTPClient&ver=0.4)

Provides HTTP client functionality based on [libcurl](https://github.com/JuliaWeb/LibCURL.jl).

## Usage

The exported APIs from module HTTPClient are :

```julia
get(url::String, options::RequestOptions)
get(url::String; kw_opts...)

post(url::String, data, options::RequestOptions)
post(url::String, data; kw_opts...)

put(url::String, data, options::RequestOptions)
put(url::String, data; kw_opts...)
```

`data` can be either a
  - `String` - sent as is.
  - `IOStream` - Content type is set to "application/octet-stream" unless specified otherwise
  - `Dict{Name, Value}` or `Vector{Tuple{Name, Value}}` - Content type is set to "application/x-www-form-urlencoded" unless specified otherwise
  - (:file, filename::String) - The file is read, and the content-type is set automatically unless specified otherwise.


```julia
head(url::String, options::RequestOptions)
head(url::String; kw_opts...)

delete(url::String, options::RequestOptions)
delete(url::String; kw_opts...)

trace(url::String, options::RequestOptions)
trace(url::String; kw_opts...)

options(url::String, options::RequestOptions)
options(url::String; kw_opts...)
```

Each API returns an object of type

```julia
type Response
    body::IOBuffer
    headers::Dict{String, Vector{String}}
    http_code::Int
    total_time::Float64
    bytes_recd::Integer
end
```

If you expecting ascii text as a response, for example, html content, or json,
`bytestring(r.body)` will return the stringified response. For binary data use the
functions described in http://docs.julialang.org/en/latest/stdlib/base/#i-o to access
the raw data.


### Specifying Options

Options can specified either as keyword arguments or a single object of type `RequestOptions`

```julia
type RequestOptions
    blocking::Bool
    query_params::Vector{Tuple}
    request_timeout::Float64
    callback::Union(Function,Bool)
    content_type::String
    headers::Vector{Tuple}
    ostream::Union{IO, Nothing}
    auto_content_type::Bool
end
```

`options` can also be specified as named arguments in each of the APIS. The names are field names of RequestOptions.
For example, ```get(url; blocking=false, request_timeout=30.0)```


- By default all APIs block till request completion and return Response objects.

- If ```blocking``` is set to ```false```, then the API returns immediately with a RemoteRef. The request is executed asynchronously in a separate task.

- The user can specify a complete url in the ```url``` parameter of the API, or can set query_params as a ```Vector``` of ```(Name, Value)``` tuples

  In the former case, the passed url is executed as is.

  In the latter case the complete URL if formed by concatenating the ```url``` field, a "?" and
  the escaped (name,value) pairs. Both the name and values must be convertible to appropriate ASCIIStrings.

- In file upload cases, an attempt is made to set the ```content_type``` type automatically as
  derived from the file extension unless ```auto_content_type``` is set to false.

- ```auto_content_type``` - default is true. If the content_type has not been explicitly specified,
  the library will try to guess the content type for a PUT/POST from the file extension.
  For POST it will default to "application/x-www-form-urlencoded". Set this parameter to false to override this behaviour

- Default value for the ```request_timeout``` is 0.0 seconds, i.e., never timeout.

- If a callback is specified, its signature should be  ```customize_cb(curl)``` where ```curl``` is the libCURL handle.
  The callback can further customize the request by using libCURL easy* APIs directly

- headers - additional headers to be set. Vector of {Name, Value} Tuples

- ostream - if set as an IO, any returned data to written to ostream.
  If it is a String, it is treated as a filename and written to the file.
  In both these cases the data is not returned as part of the Response object



# Samples

See `test/runtests.jl` for sample code


### TODO

Change the sleep in a loop to using fdwatcher when support for fdwatcher becomes available in mainline





