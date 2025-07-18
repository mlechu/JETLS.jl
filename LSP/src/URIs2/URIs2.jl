# Adapted from https://github.com/julia-vscode/JuliaWorkspaces.jl/tree/54069ac444045a9f7bb40cb1e35c5fc237b85d52/src/URIs2,
# Later, some fixes were added, including corrections for errors discovered by JETLS.
# TODO publish this as a standalone package and share it between JETLS and JuliaWorkspace.jl

# TODO Move this under LSP.jl?
module URIs2

export URI, uri2filename, uri2filepath, filename2uri, filepath2uri, @uri_str

using StructTypes: StructTypes

include("vendored_from_uris.jl")

"""
    struct URI

Details of a Unified Resource Identifier.

 - scheme::Union{Nothing, String}
 - authority::Union{Nothing, String}
 - path::String
 - query::Union{Nothing, String}
 - fragment::Union{Nothing, String}
"""
struct URI
    scheme::Union{String,Nothing}
    authority::Union{String,Nothing}
    path::String
    query::Union{String,Nothing}
    fragment::Union{String,Nothing}
end

@static if Sys.iswindows()
    function Base.:(==)(a::URI, b::URI)
        if a.scheme=="file" && b.scheme=="file"
            a_path_norm = lowercase(a.path)
            b_path_norm = lowercase(b.path)

            return a.scheme == b.scheme &&
                a.authority == b.authority &&
                a_path_norm == b_path_norm &&
                a.query == b.query &&
                a.fragment == b.fragment
        else
            return a.scheme == b.scheme &&
                a.authority == b.authority &&
                a.path == b.path &&
                a.query == b.query &&
                a.fragment == b.fragment
        end
    end

    function Base.hash(a::URI, h::UInt)
        if a.scheme=="file"
            path_norm = lowercase(a.path)
            return hash((a.scheme, a.authority, path_norm, a.query, a.fragment), h)
        else
            return hash((a.scheme, a.authority, a.path, a.query, a.fragment), h)
        end
    end
else
    function Base.:(==)(a::URI, b::URI)
        return a.scheme == b.scheme &&
            a.authority == b.authority &&
            a.path == b.path &&
            a.query == b.query &&
            a.fragment == b.fragment
    end

    function Base.hash(a::URI, h::UInt)
        return hash((a.scheme, a.authority, a.path, a.query, a.fragment), h)
    end
end

Base.convert(::Type{URI}, s::AbstractString) = URI(s)

# This overload requires `URI(::AbstractString)` as well, which is defined later
StructTypes.StructType(::Type{URI}) = StructTypes.StringType()

function percent_decode(str::AbstractString)
    return unescapeuri(str)
end

function URI(value::AbstractString)
    m = match(r"^(([^:/?#]+?):)?(\/\/([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?", value)

    m === nothing && error("Invalid input")

    cap2, cap4, cap5, cap7, cap9 = m.captures[2], m.captures[4], m.captures[5], m.captures[7], m.captures[9]
    return URI(
        cap2,
        cap4 === nothing ? nothing : percent_decode(cap4),
        percent_decode(cap5::AbstractString),
        cap7 === nothing ? nothing : percent_decode(cap7),
        cap9 === nothing ? nothing : percent_decode(cap9))
end

URI(uri::URI) = uri

function URI(;
    scheme::Union{AbstractString,Nothing}=nothing,
    authority::Union{AbstractString,Nothing}=nothing,
    path::AbstractString="",
    query::Union{AbstractString,Nothing}=nothing,
    fragment::Union{AbstractString,Nothing}=nothing
    )
    return URI(scheme, authority, path, query, fragment)
end

@inline function is_rfc3986_unreserved(c::Char)
    return 'A' <= c <= 'Z' ||
        'a' <= c <= 'z' ||
        '0' <= c <= '9' ||
        c == '-' ||
        c == '.' ||
        c == '_' ||
        c == '~'
end

@inline function is_rfc3986_sub_delim(c::Char)
    return c == '!' ||
        c == '$' ||
        c == '&' ||
        c == '\'' ||
        c == '(' ||
        c == ')' ||
        c == '*' ||
        c == '+' ||
        c == ',' ||
        c == ';' ||
        c == '='
end

@inline function is_rfc3986_pchar(c::Char)
    return is_rfc3986_unreserved(c) ||
        is_rfc3986_sub_delim(c) ||
        c == ':' ||
        c == '@'
end

@inline function is_rfc3986_query(c::Char)
    return is_rfc3986_pchar(c) || c=='/' || c=='?'
end

@inline function is_rfc3986_fragment(c::Char)
    return is_rfc3986_pchar(c) || c=='/' || c=='?'
end

@inline function is_rfc3986_userinfo(c::Char)
    return is_rfc3986_unreserved(c) ||
        is_rfc3986_sub_delim(c) ||
        c == ':'
end

@inline function is_rfc3986_reg_name(c::Char)
    return is_rfc3986_unreserved(c) ||
        is_rfc3986_sub_delim(c)
end

function encode(io::IO, s::AbstractString, issafe::Function)
    for c in s
        if issafe(c)
            print(io, c)
        else
            print(io, '%')
            print(io, uppercase(string(Int(c), base=16, pad=2)))
        end
    end
end

@inline function is_ipv4address(s::AbstractString)
    if length(s)==1
        return '0' <= s[1] <= '9'
    elseif length(s)==2
        return '1' <= s[1] <= '9' && '0' <= s[2] <= '9'
    elseif length(s)==3
        return (s[1]=='1' && '0' <= s[2] <= '9' && '0' <= s[3] <= '9') ||
            (s[1]=='2' && '0' <= s[2] <= '4' && '0' <= s[3] <= '9') ||
            (s[1]=='2' && s[2] == '5' && '0' <= s[3] <= '5')
    else
        return false
    end
end

@inline function is_ipliteral(s::AbstractString)
    # TODO Implement this
    return false
end

function encode_host(io::IO, s::AbstractString)
    if is_ipv4address(s) || is_ipliteral(s)
        print(io, s)
    else
        # The host must be a reg-name
        encode(io, s, is_rfc3986_reg_name)
    end
end

function encode_path(io::IO, s::AbstractString)
    # TODO Write our own version
    print(io, escapepath(s))
end

function Base.show(io::IO, uri::URI)
    scheme = uri.scheme
    authority = uri.authority
    path = uri.path
    query = uri.query
    fragment = uri.fragment

     if scheme!==nothing
        print(io, scheme)
        print(io, ':')
     end

     if authority!==nothing
        print(io, "//")

        idx = findfirst("@", authority)
        if idx !== nothing
            # <user>@<auth>
            userinfo = SubString(authority, 1:idx.start-1)
            host_and_port = SubString(authority, idx.start + 1)
            encode(io, userinfo, is_rfc3986_userinfo)
            print(io, '@')
        else
            host_and_port = SubString(authority, 1)
        end

        idx3 = findfirst(":", host_and_port)
        if idx3 === nothing
            encode_host(io, host_and_port)
        else
            # <auth>:<port>
            encode_host(io, SubString(host_and_port, 1:idx3.start-1))
            print(io, SubString(host_and_port, idx3.start))
        end
     end

     # Append path
     encode_path(io, path)

    if query!==nothing
        print(io, '?')
        encode(io, query, is_rfc3986_query)
    end

     if fragment!==nothing
        print(io, '#')
        encode(io, fragment, is_rfc3986_fragment)
    end

    return nothing
end

macro uri_str(s::AbstractString) URI(s) end

include("uri_helpers.jl")

end
