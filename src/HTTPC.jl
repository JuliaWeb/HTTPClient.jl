module HTTPC

using Compat
using LibCURL
using LibCURL.Mime_ext

import Base.convert, Base.show, Base.get, Base.put, Base.trace

export init, cleanup, get, put, post, trace, delete, head, options
export RequestOptions, Response

def_rto = 0.0

##############################
# Struct definitions
##############################

type RequestOptions
    blocking::Bool
    query_params::Vector{Tuple}
    request_timeout::Float64
    callback::Union(Function,Bool)
    content_type::String
    headers::Vector{Tuple}
    ostream::Union(IO, String, Nothing)
    auto_content_type::Bool

    RequestOptions(; blocking=true, query_params=Array(Tuple,0), request_timeout=def_rto, callback=null_cb, content_type="", headers=Array(Tuple,0), ostream=nothing, auto_content_type=true) =
    new(blocking, query_params, request_timeout, callback, content_type, headers, ostream, auto_content_type)
end

type Response
    body
    headers :: Dict{String, Vector{String}}
    http_code
    total_time
    bytes_recd::Integer

    Response() = new(nothing, Dict{String, Vector{String}}(), 0, 0.0, 0)
end

function show(io::IO, o::Response)
    println(io, "HTTP Code   :", o.http_code)
    println(io, "RequestTime :", o.total_time)
    println(io, "Headers     :")
    for (k,vs) in o.headers
        for v in vs
            println(io, "    $k : $v")
        end
    end

    println(io, "Length of body : ", o.bytes_recd)
end


type ReadData
    typ::Symbol
    src::Any
    str::String
    offset::Csize_t
    sz::Csize_t

    ReadData() = new(:undefined, false, "", 0, 0)
end

type ConnContext
    curl::Ptr{CURL}
    url::String
    slist::Ptr{Void}
    rd::ReadData
    resp::Response
    options::RequestOptions
    close_ostream::Bool

    ConnContext(options::RequestOptions) = new(C_NULL, "", C_NULL, ReadData(), Response(), options, false)
end

immutable CURLMsg2
  msg::CURLMSG
  easy_handle::Ptr{CURL}
  data::Ptr{Any}
end

type MultiCtxt
    s::curl_socket_t    # Socket
    chk_read::Bool
    chk_write::Bool
    timeout::Float64

    MultiCtxt() = new(0,false,false,0.0)
end



##############################
# Callbacks
##############################

function write_cb(buff::Ptr{Uint8}, sz::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
#    println("@write_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    nbytes = sz * n
    write(ctxt.resp.body, buff, nbytes)
    ctxt.resp.bytes_recd = ctxt.resp.bytes_recd + nbytes

    nbytes::Csize_t
end

c_write_cb = cfunction(write_cb, Csize_t, (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))

function header_cb(buff::Ptr{Uint8}, sz::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
#    println("@header_cb")
    ctxt = unsafe_pointer_to_objref(p_ctxt)
    hdrlines = split(bytestring(buff, convert(Int, sz * n)), "\r\n")

#    println(hdrlines)
    for e in hdrlines
        m = match(r"^\s*([\w\-\_]+)\s*\:(.+)", e)
        if (m != nothing)
            k = strip(m.captures[1])
            v = strip(m.captures[2])
            if haskey(ctxt.resp.headers, k)
                push!(ctxt.resp.headers[k], v)
            else
                ctxt.resp.headers[k] = (String)[v]
            end
        end
    end
    (sz*n)::Csize_t
end

c_header_cb = cfunction(header_cb, Csize_t, (Ptr{Uint8}, Csize_t, Csize_t, Ptr{Void}))


function curl_read_cb(out::Ptr{Void}, s::Csize_t, n::Csize_t, p_ctxt::Ptr{Void})
#    println("@curl_read_cb")

    ctxt = unsafe_pointer_to_objref(p_ctxt)
    bavail::Csize_t = s * n
    breq::Csize_t = ctxt.rd.sz - ctxt.rd.offset
    b2copy = bavail > breq ? breq : bavail

    if (ctxt.rd.typ == :buffer)
        ccall(:memcpy, Ptr{Void}, (Ptr{Void}, Ptr{Void}, Uint),
                out, convert(Ptr{Uint8}, pointer(ctxt.rd.str)) + ctxt.rd.offset, b2copy)
    elseif (ctxt.rd.typ == :io)
        b_read = read(ctxt.rd.src, Uint8, b2copy)
        ccall(:memcpy, Ptr{Void}, (Ptr{Void}, Ptr{Void}, Uint), out, b_read, b2copy)
    end
    ctxt.rd.offset = ctxt.rd.offset + b2copy

    r = convert(Csize_t, b2copy)
    r::Csize_t
end

c_curl_read_cb = cfunction(curl_read_cb, Csize_t, (Ptr{Void}, Csize_t, Csize_t, Ptr{Void}))



function curl_socket_cb(curl::Ptr{Void}, s::Cint, action::Cint, p_muctxt::Ptr{Void}, sctxt::Ptr{Void})
    if action != CURL_POLL_REMOVE
        muctxt = unsafe_pointer_to_objref(p_muctxt)

        muctxt.s = s
        muctxt.chk_read = false
        muctxt.chk_write = false

        if action == CURL_POLL_IN
            muctxt.chk_read = true

        elseif action == CURL_POLL_OUT
            muctxt.chk_write = true

        elseif action == CURL_POLL_INOUT
            muctxt.chk_read = true
            muctxt.chk_write = true
        end
    end

    # NOTE: Out-of-order socket fds cause problems in the case of HTTP redirects, hence ignoring CURL_POLL_REMOVE
    ret = convert(Cint, 0)
    ret::Cint
end

c_curl_socket_cb = cfunction(curl_socket_cb, Cint, (Ptr{Void}, Cint, Cint, Ptr{Void}, Ptr{Void}))



function curl_multi_timer_cb(curlm::Ptr{Void}, timeout_ms::Clong, p_muctxt::Ptr{Void})
    muctxt = unsafe_pointer_to_objref(p_muctxt)
    muctxt.timeout = timeout_ms / 1000.0

#    println("Requested timeout value : " * string(muctxt.timeout))

    ret = convert(Cint, 0)
    ret::Cint
end

c_curl_multi_timer_cb = cfunction(curl_multi_timer_cb, Cint, (Ptr{Void}, Clong, Ptr{Void}))




##############################
# Utility functions
##############################

macro ce_curl (f, args...)
    quote
        cc = CURLE_OK
        cc = $(esc(f))(ctxt.curl, $(args...))

        if(cc != CURLE_OK)
            error (string($f) * "() failed: " * bytestring(curl_easy_strerror(cc)))
        end
    end
end

macro ce_curlm (f, args...)
    quote
        cc = CURLM_OK
        cc = $(esc(f))(curlm, $(args...))

        if(cc != CURLM_OK)
            error (string($f) * "() failed: " * bytestring(curl_multi_strerror(cc)))
        end
    end
end


null_cb(curl) = return nothing

function set_opt_blocking(options::RequestOptions)
        o2 = RequestOptions()
        for n in filter(x -> !(x in [:ostream, :blocking]),names(o2))
            setfield!(o2, n, deepcopy(getfield(options, n)))
        end
        o2.blocking = true
        o2.ostream = options.ostream
        return o2
end

function get_ct_from_ext(filename)
    fparts = split(basename(filename), ".")
    if (length(fparts) > 1)
        if haskey(MimeExt, fparts[end]) return MimeExt[fparts[end]] end
    end
    return false
end


function setup_easy_handle(url, options::RequestOptions)
    ctxt = ConnContext(options)

    curl = curl_easy_init()
    if (curl == C_NULL) throw("curl_easy_init() failed") end

    ctxt.curl = curl

    @ce_curl curl_easy_setopt CURLOPT_FOLLOWLOCATION 1

    @ce_curl curl_easy_setopt CURLOPT_MAXREDIRS 5

    if length(options.query_params) > 0
        qp = urlencode_query_params(curl, options.query_params)
        url = url * "?" * qp
    end


    ctxt.url = url

    @ce_curl curl_easy_setopt CURLOPT_URL url
    @ce_curl curl_easy_setopt CURLOPT_WRITEFUNCTION c_write_cb

    p_ctxt = pointer_from_objref(ctxt)

    @ce_curl curl_easy_setopt CURLOPT_WRITEDATA p_ctxt

    @ce_curl curl_easy_setopt CURLOPT_HEADERFUNCTION c_header_cb
    @ce_curl curl_easy_setopt CURLOPT_HEADERDATA p_ctxt

    if options.content_type != ""
        ct = "Content-Type: " * options.content_type
        ctxt.slist = curl_slist_append (ctxt.slist, ct)
    else
        # Disable libCURL automatically setting the content type
        ctxt.slist = curl_slist_append (ctxt.slist, "Content-Type:")
    end


    for hdr in options.headers
        hdr_str = hdr[1] * ":" * hdr[2]
        ctxt.slist = curl_slist_append (ctxt.slist, hdr_str)
    end

    # Disabling the Expect header since some webservers don't handle this properly
    ctxt.slist = curl_slist_append (ctxt.slist, "Expect:")
    @ce_curl curl_easy_setopt CURLOPT_HTTPHEADER ctxt.slist

    if isa(options.ostream, String)
        ctxt.resp.body = open(options.ostream, "w+")
        ctxt.close_ostream = true
    elseif isa(options.ostream, IO)
        ctxt.resp.body = options.ostream
    else
        ctxt.resp.body = IOBuffer()
    end

    ctxt
end

function cleanup_easy_context(ctxt::Union(ConnContext,Bool))
    if isa(ctxt, ConnContext)
        if (ctxt.slist != C_NULL)
            curl_slist_free_all(ctxt.slist)
        end

        if (ctxt.curl != C_NULL)
            curl_easy_cleanup(ctxt.curl)
        end

        if ctxt.close_ostream
            close(ctxt.resp.body)
            ctxt.resp.body = nothing
            ctxt.close_ostream = false
        end
    end
end


function process_response(ctxt)
    http_code = Array(Clong,1)
    @ce_curl curl_easy_getinfo CURLINFO_RESPONSE_CODE http_code

    total_time = Array(Cdouble,1)
    @ce_curl curl_easy_getinfo CURLINFO_TOTAL_TIME total_time

    ctxt.resp.http_code = http_code[1]
    ctxt.resp.total_time = total_time[1]
end

# function blocking_get (url)
#     try
#         ctxt=nothing
#         ctxt = setup_easy_handle(url)
#         curl = ctxt.curl
#
#         @ce_curl curl_easy_perform
#
#         process_response(ctxt)
#
#         return ctxt.resp
#     finally
#         if isa(ctxt, ConnContext) && (ctxt.curl != 0)
#             curl_easy_cleanup(ctxt.curl)
#         end
#     end
# end





##############################
# Library initializations
##############################

init() = curl_global_init(CURL_GLOBAL_ALL)
cleanup() = curl_global_cleanup()


##############################
# GET
##############################

function get(url::String, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)

            @ce_curl curl_easy_setopt CURLOPT_HTTPGET 1

            return exec_as_multi(ctxt)
        finally
            cleanup_easy_context(ctxt)
        end
    else
        return remotecall(myid(), get, url, set_opt_blocking(options))
    end
end



##############################
# POST & PUT
##############################

function post (url::String, data, options::RequestOptions=RequestOptions())
    if (options.blocking)
        return put_post(url, data, :post, options)
    else
        return remotecall(myid(), post, url, data, set_opt_blocking(options))
    end
end

function put (url::String, data, options::RequestOptions=RequestOptions())
    if (options.blocking)
        return put_post(url, data, :put, options)
    else
        return remotecall(myid(), put, url, data, set_opt_blocking(options))
    end
end



function put_post(url::String, data, putorpost::Symbol, options::RequestOptions)
    rd::ReadData = ReadData()

    if isa(data, String)
        rd.typ = :buffer
        rd.src = false
        rd.str = data
        rd.sz = length(data)

    elseif isa(data, Dict) || (isa(data, Vector) && issubtype(eltype(data), Tuple))
        arr_data = isa(data, Dict) ? collect(data) : data
        rd.str = urlencode_query_params(arr_data)  # Not very optimal since it creates another curl handle, but it is clean...
        rd.sz = length(rd.str)
        rd.typ = :buffer
        rd.src = arr_data
        if ((options.content_type == "") && (options.auto_content_type))
            options.content_type = "application/x-www-form-urlencoded"
        end

    elseif isa(data, IO)
        rd.typ = :io
        rd.src = data
        seekend(data)
        rd.sz = position(data)
        seekstart(data)
        if ((options.content_type == "") && (options.auto_content_type))
            options.content_type = "application/octet-stream"
        end

    elseif isa(data, Tuple)
        (typsym, filename) = data
        if (typsym != :file) error ("Unsupported data datatype") end

        rd.typ = :io
        rd.src = open(filename)
        rd.sz = filesize(filename)

        try
            if ((options.content_type == "") && (options.auto_content_type))
                options.content_type = get_ct_from_ext(filename)
            end
            return _put_post(url, putorpost, options, rd)
        finally
            close(rd.src)
        end

    else
        error ("Unsupported data datatype")
    end

    return _put_post(url, putorpost, options, rd)
end




function _put_post(url::String, putorpost::Symbol, options::RequestOptions, rd::ReadData)
    ctxt = false
    try
        ctxt = setup_easy_handle(url, options)
        ctxt.rd = rd

        if (putorpost == :post)
            @ce_curl curl_easy_setopt CURLOPT_POST 1
            @ce_curl curl_easy_setopt CURLOPT_POSTFIELDSIZE rd.sz
        elseif (putorpost == :put)
            @ce_curl curl_easy_setopt CURLOPT_UPLOAD 1
            @ce_curl curl_easy_setopt CURLOPT_INFILESIZE rd.sz
        end

        if (rd.typ == :io) || (putorpost == :put)
            p_ctxt = pointer_from_objref(ctxt)
            @ce_curl curl_easy_setopt CURLOPT_READDATA p_ctxt

            @ce_curl curl_easy_setopt CURLOPT_READFUNCTION c_curl_read_cb
        else
            ppostdata = pointer(rd.str)
            @ce_curl curl_easy_setopt CURLOPT_COPYPOSTFIELDS ppostdata
        end

        return exec_as_multi(ctxt)
    finally
        cleanup_easy_context(ctxt)
    end
end



##############################
# HEAD, DELETE and TRACE
##############################
function head(url::String, options::RequestOptions=RequestOptions())
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)

            @ce_curl curl_easy_setopt CURLOPT_NOBODY 1

            return exec_as_multi(ctxt)
        finally
            cleanup_easy_context(ctxt)
        end
    else
        return remotecall(myid(), head, url, set_opt_blocking(options))
    end

end

delete(url::String, options::RequestOptions=RequestOptions()) = custom(url, "DELETE", options)
trace(url::String, options::RequestOptions=RequestOptions()) = custom(url, "TRACE", options)
options(url::String, options::RequestOptions=RequestOptions()) = custom(url, "OPTIONS", options)


for f in (:get, :head, :delete, :trace, :options)
    @eval $(f)(url::String; kwargs...) = $(f)(url, RequestOptions(; kwargs...))
end

# put(url::String, data::String; kwargs...) = put(url, data, options=RequestOptions(; kwargs...))
# post(url::String, data::String; kwargs...) = post(url, data, options=RequestOptions(; kwargs...))


for f in (:put, :post)
    @eval $(f)(url::String, data::String; kwargs...) = $(f)(url, data, RequestOptions(; kwargs...))
end


function custom(url::String, verb::String, options::RequestOptions)
    if (options.blocking)
        ctxt = false
        try
            ctxt = setup_easy_handle(url, options)

            @ce_curl curl_easy_setopt CURLOPT_CUSTOMREQUEST verb

            return exec_as_multi(ctxt)
        finally
            cleanup_easy_context(ctxt)
        end
    else
        return remotecall(myid(), custom, url, verb, set_opt_blocking(options))
    end
end


##############################
# EXPORTED UTILS
##############################

function urlencode_query_params{T<:Tuple}(params::Vector{T})
    curl = curl_easy_init()
    if (curl == C_NULL) throw("curl_easy_init() failed") end

    querystr = urlencode_query_params(curl, params)

    curl_easy_cleanup(curl)

    return querystr
end
export urlencode_query_params

function urlencode_query_params{T<:Tuple}(curl, params::Vector{T})
    querystr = ""
    for x in params
        k,v = x
        if (v != "")
            ep = urlencode(curl, string(k)) * "=" * urlencode(curl, string(v))
        else
            ep = urlencode(curl, string(k))
        end

        if querystr == ""
            querystr = ep
        else
            querystr = querystr * "&" * ep
        end

    end
    return querystr
end


function urlencode(curl, s::String)
    b_arr = curl_easy_escape(curl, s, length(s))
    esc_s = bytestring(b_arr)
    curl_free(b_arr)
    return esc_s
end

function urlencode(s::String)
    curl = curl_easy_init()
    if (curl == C_NULL) throw("curl_easy_init() failed") end

    esc_s = urlencode(curl, s)
    curl_easy_cleanup(curl)
    return esc_s

end

urlencode(s::SubString) = urlencode(bytestring(s))

export urlencode


function exec_as_multi(ctxt)
    curl = ctxt.curl
    curlm = curl_multi_init()

    if (curlm == C_NULL) error("Unable to initialize curl_multi_init()") end

    try
        if isa(ctxt.options.callback, Function) ctxt.options.callback(curl) end

        @ce_curlm curl_multi_add_handle curl

        n_active = Array(Cint,1)
        n_active[1] = 1

        no_to = 30 * 24 * 3600.0
        request_timeout = 0.001 + (ctxt.options.request_timeout == 0.0 ? no_to : ctxt.options.request_timeout)

        started_at = time()
        time_left = request_timeout

    # poll_fd is unreliable when multiple parallel fds are active, hence using curl_multi_perform

# START curl_multi_socket_action  mode

#         @ce_curlm curl_multi_setopt CURLMOPT_SOCKETFUNCTION c_curl_socket_cb
#         @ce_curlm curl_multi_setopt CURLMOPT_TIMERFUNCTION c_curl_multi_timer_cb
#
#         muctxt = MultiCtxt()
#         p_muctxt = pointer_from_objref(muctxt)
#
#         @ce_curlm curl_multi_setopt CURLMOPT_SOCKETDATA p_muctxt
#         @ce_curlm curl_multi_setopt CURLMOPT_TIMERDATA p_muctxt
#
#
#         @ce_curlm curl_multi_socket_action CURL_SOCKET_TIMEOUT 0 n_active
#
#         while (n_active[1] > 0) && (time_left > 0)
#             evt_got = 0
#             if (muctxt.chk_read || muctxt.chk_write)
#                 t1 = int64(time() * 1000)
#
#                 poll_to = min(muctxt.timeout < 0.0 ? no_to : muctxt.timeout, time_left)
#                 pfd_ret = poll_fd(RawFD(muctxt.s), poll_to, readable=muctxt.chk_read, writable=muctxt.chk_write)
#
#                 evt_got = (isreadable(pfd_ret) ? CURL_CSELECT_IN : 0) | (iswritable(pfd_ret) ? CURL_CSELECT_OUT : 0)
#             else
#                 break
#             end
#
#             if (evt_got == 0)
#                 @ce_curlm curl_multi_socket_action CURL_SOCKET_TIMEOUT 0 n_active
#             else
#                 @ce_curlm curl_multi_socket_action muctxt.s evt_got n_active
#             end
#
#             time_left = request_timeout - (time() - started_at)
#         end

# END curl_multi_socket_action  mode

# START curl_multi_perform  mode

        cmc = curl_multi_perform(curlm, n_active);
        while (n_active[1] > 0) &&  (time_left > 0)
            nb1 = ctxt.resp.bytes_recd
            cmc = curl_multi_perform(curlm, n_active);
            if(cmc != CURLM_OK) error ("curl_multi_perform() failed: " * bytestring(curl_multi_strerror(cmc))) end

            nb2 = ctxt.resp.bytes_recd

            if (nb2 > nb1)
                yield() # Just yield to other tasks
            else
                sleep(0.005) # Just to prevent unnecessary CPU spinning
            end

            time_left = request_timeout - (time() - started_at)
        end

# END OF curl_multi_perform


        if (n_active[1] == 0)
            msgs_in_queue = Array(Cint,1)
            p_msg::Ptr{CURLMsg2} = curl_multi_info_read(curlm, msgs_in_queue)

            while (p_msg != C_NULL)
#                println("Messages left in Q : " * string(msgs_in_queue[1]))
                msg = unsafe_load(p_msg)

                if (msg.msg == CURLMSG_DONE)
                    ec = convert(Int, msg.data)
                    if (ec != CURLE_OK)
#                        println("Result of transfer: " * string(msg.data))
                        throw("Error executing request : " * bytestring(curl_easy_strerror(ec)))
                    else
                        process_response(ctxt)
                    end
                end

                p_msg = curl_multi_info_read(curlm, msgs_in_queue)
            end
        else
            error ("request timed out")
        end

    finally
        curl_multi_remove_handle(curlm, curl)
        curl_multi_cleanup(curlm)
    end

    ctxt.resp
end



end
