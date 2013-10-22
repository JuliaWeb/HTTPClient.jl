HTTPClient.jl
=============

[![Build Status](https://travis-ci.org/WestleyArgentum/HTTPClient.jl.png?branch=travis)](https://travis-ci.org/WestleyArgentum/HTTPClient.jl)

Currently provides an HTTP Client based on libcurl


USAGE
=====

### Types

All HTTP request APIs take in a object of type ```RequestOptions```

```
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

- By default all APIs block till request completion and return Response objects. 

- If ```blocking``` is set to ```false```, then the API returns immediately with a RemoteRef.

- The user can pass in a complete url in the ```url``` parameter of the API, or can set query_params as a ```Vector``` of ```(Name, Value)``` tuples

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

  
  

Each API returns an object of type 

```
    type Response
        body::IOBuffer
        headers::Dict{ASCIIString, ASCIIString}
        http_code::Int
        total_time::Float64
    end
```

If you expecting ascii text as a response, for example, html content, or json,
`bytestring(r.body)` will return the stringified response. For binary data use the 
functions described in http://docs.julialang.org/en/latest/stdlib/base/#i-o to access
the raw data.


The exported APIs from module HTTPClient are :

```
 get(url::String, options::RequestOptions)

 post (url::String, data, options::RequestOptions)

 put (url::String, data, options::RequestOptions)
``` 

- For both ```post``` and ```put``` above, the data can be either a
  - String - sent as is.
  - IOStream - Content type is set to "application/octet-stream" unless specified otherwise
  - Dict{Name, Value} or Vector{Tuple{Name, Value}} - Content type is set to "application/x-www-form-urlencoded" unless specified otherwise
  - (:file, filename::String) - The file is read, and the content-type is set automatically unless specified otherwise.

```
 head(url::String, options::RequestOptions)
 
 delete(url::String, options::RequestOptions)
 
 trace(url::String, options::RequestOptions)
 
 options(url::String, options::RequestOptions)
```

The ```options``` can also be specified as named arguments in each of the above APIS. 
For example, ```get(url; blocking=false, request_timeout=30.0)```

The names are field names of RequestOptions

  
  
SAMPLES
=======
- See test/tests.jl for sample code

  
TODO
====
- Change the sleep in a loop to using fdwatcher when support for fdwatcher becomes available in mainline





